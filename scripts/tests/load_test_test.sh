#!/usr/bin/env bash
# Fichier  : scripts/tests/load_test_test.sh
# Rôle     : tests unitaires de scripts/load-test.sh (bashunit), avec un faux
#            kubectl (doublure) : aucun vrai cluster, aucune vraie charge
# Utilise  : bashunit 0.52.0, scripts/load-test.sh, scripts/lib/common.sh
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Avant chaque test : un faux dépôt avec une copie du script, un script k6
# et un faux kubectl ; par défaut, le Job k6 réussit
function set_up() {
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO"/{scripts/lib,bin,infra/k6}
  cp "$SCRIPTS_DIR/load-test.sh" "$FAKE_REPO/scripts/"
  cp "$SCRIPTS_DIR/lib/common.sh" "$FAKE_REPO/scripts/lib/"
  echo 'export default function () {}' >"$FAKE_REPO/infra/k6/microcrm.js"
  make_kubectl
  export JOB_STATE="1/"
}

# Après chaque test : suppression du faux dépôt
function tear_down() {
  rm -rf "$FAKE_REPO"
}

# Faux kubectl : note ses paramètres (et le manifeste reçu par le tube)
# dans CALLS_LOG ; « arc-runners » répond RUNNER_PODS (job de CI en
# cours) ; « status.active » répond JOB_ACTIVE (Job en cours) ;
# « get job » répond JOB_STATE (réussi/échoué) ; « logs » renvoie un
# résumé de k6
make_kubectl() {
  cat >"$FAKE_REPO/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS_LOG"
case "$*" in
  *"create configmap"*) echo "kind: ConfigMap" ;;
  *apply*) cat >>"$CALLS_LOG" ;;
  *arc-runners*) echo "${RUNNER_PODS:-}" ;;
  *"status.active"*) echo "${JOB_ACTIVE:-}" ;;
  *"get job"*) echo "$JOB_STATE" ;;
  *logs*) printf 'http_req_failed: 0.00%%\n' ;;
esac
STUB
  chmod +x "$FAKE_REPO/bin/kubectl"
}

# Lance le script copié, faux kubectl en tête du PATH ; stderr joint à
# stdout ; résumé dans le faux dépôt ; lancé « depuis le poste » sauf si
# FAKE_GHA est donné (la CI définit GITHUB_ACTIONS)
run_load() {
  GITHUB_ACTIONS="${FAKE_GHA:-}" CALLS_LOG="$FAKE_REPO/calls.log" \
    PATH="$FAKE_REPO/bin:$PATH" REPORT_DIR="$FAKE_REPO/report" "$FAKE_REPO/scripts/load-test.sh" "$@" 2>&1
}

# Journal des appels reçus par le faux kubectl, pour les vérifier
calls() {
  cat "$FAKE_REPO/calls.log"
}

function test_without_parameter_prints_usage_with_code_2() {
  local output
  output="$(run_load)"
  assert_exit_code "2"
  assert_contains "Usage: load-test.sh smoke|average" "$output"
}

function test_unknown_profile_is_refused_with_code_2() {
  run_load flood >/dev/null
  assert_exit_code "2"
}

function test_prod_is_refused() {
  local output
  output="$(NAMESPACE=prod run_load smoke)"
  assert_exit_code "1"
  assert_contains "not allowed in prod" "$output"
  assert_file_not_exists "$FAKE_REPO/calls.log"
}

function test_running_k6_job_is_not_replaced() {
  local output
  output="$(JOB_ACTIVE=1 run_load stress)"
  assert_exit_code "1"
  assert_contains "already running" "$output"
  assert_not_contains "delete job" "$(calls)"
}

function test_k6_pod_has_cpu_and_memory_limits() {
  run_load smoke >/dev/null
  assert_contains 'cpu: "1"' "$(calls)"
  assert_contains "memory: 512Mi" "$(calls)"
}

function test_running_ci_job_blocks_a_run_from_the_workstation() {
  local output
  output="$(RUNNER_PODS="orion-local-runner-1 1/1 Running" run_load stress)"
  assert_exit_code "1"
  assert_contains "a CI job is running" "$output"
  assert_not_contains "delete job" "$(calls)"
}

function test_run_from_actions_does_not_check_ci_jobs() {
  RUNNER_PODS="orion-local-runner-1 1/1 Running" FAKE_GHA=true \
    run_load smoke >/dev/null
  assert_successful_code
  assert_not_contains "arc-runners" "$(calls)"
}

function test_invalid_push_metrics_is_refused() {
  local output
  output="$(PUSH_METRICS=yes run_load smoke)"
  assert_exit_code "1"
  assert_contains "PUSH_METRICS must be 0 or 1" "$output"
}

function test_missing_k6_script_stops() {
  local output
  rm "$FAKE_REPO/infra/k6/microcrm.js"
  output="$(run_load smoke)"
  assert_exit_code "1"
  assert_contains "k6 script not found" "$output"
}

function test_smoke_runs_in_staging_against_the_front() {
  run_load smoke >/dev/null
  assert_successful_code
  assert_contains "kubectl -n staging delete job k6 --ignore-not-found" \
    "$(calls)"
  assert_contains 'value: "smoke"' "$(calls)"
  assert_contains 'value: "http://microcrm-front:8080"' "$(calls)"
  assert_contains "activeDeadlineSeconds: 300" "$(calls)"
}

function test_metrics_are_pushed_by_default_and_can_be_disabled() {
  run_load smoke >/dev/null
  assert_contains '"-o", "experimental-prometheus-rw"' "$(calls)"
  rm "$FAKE_REPO/calls.log"
  PUSH_METRICS=0 run_load smoke >/dev/null
  assert_not_contains "experimental-prometheus-rw\"" "$(calls)"
}

function test_job_runs_without_privileges_on_a_pinned_image() {
  run_load smoke >/dev/null
  assert_contains "runAsNonRoot: true" "$(calls)"
  assert_contains "allowPrivilegeEscalation: false" "$(calls)"
  assert_contains "readOnlyRootFilesystem: true" "$(calls)"
  assert_contains "automountServiceAccountToken: false" "$(calls)"
  assert_contains "grafana/k6:2.3.0@sha256:" "$(calls)"
}

function test_summary_is_saved() {
  run_load smoke >/dev/null
  assert_contains "http_req_failed" "$(cat "$FAKE_REPO/report/summary.txt")"
}

function test_crossed_threshold_stops_with_code_1_and_keeps_the_summary() {
  local output
  output="$(JOB_STATE="/1" run_load stress)"
  assert_exit_code "1"
  assert_contains "thresholds crossed" "$output"
  assert_file_exists "$FAKE_REPO/report/summary.txt"
}

function test_breakpoint_reached_is_a_success() {
  local output
  output="$(JOB_STATE="/1" run_load breakpoint)"
  assert_successful_code
  assert_contains "breaking point reached" "$output"
}
