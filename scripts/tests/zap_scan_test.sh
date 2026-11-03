#!/usr/bin/env bash
# Fichier  : scripts/tests/zap_scan_test.sh
# Rôle     : tests unitaires de scripts/zap-scan.sh (bashunit), avec un faux
#            kubectl (doublure) : aucun vrai cluster, aucun vrai scan
# Utilise  : bashunit 0.52.0, scripts/zap-scan.sh, scripts/lib/common.sh
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Avant chaque test : un faux dépôt avec une copie du script, un fichier de
# règles et un faux kubectl ; par défaut, le Job ZAP réussit
function set_up() {
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO"/{scripts/lib,bin,infra/zap}
  cp "$SCRIPTS_DIR/zap-scan.sh" "$FAKE_REPO/scripts/"
  cp "$SCRIPTS_DIR/lib/common.sh" "$FAKE_REPO/scripts/lib/"
  printf '10038\tWARN\t(CSP)\n' >"$FAKE_REPO/infra/zap/rules.tsv"
  make_kubectl
  export JOB_STATE="1/"
}

# Après chaque test : suppression du faux dépôt
function tear_down() {
  rm -rf "$FAKE_REPO"
}

# Faux kubectl : note ses paramètres (et le manifeste reçu par le tube)
# dans CALLS_LOG ; « get job » répond JOB_STATE (réussi/échoué) ; « logs »
# renvoie une sortie de ZAP suivie du rapport
make_kubectl() {
  cat >"$FAKE_REPO/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS_LOG"
case "$*" in
  *"create configmap"*) echo "kind: ConfigMap" ;;
  *apply*) cat >>"$CALLS_LOG" ;;
  *"get job"*) echo "$JOB_STATE" ;;
  *logs*) printf 'WARN-NEW: CSP\n=== ZAP REPORT ===\n# ZAP Scanning Report\n' ;;
esac
STUB
  chmod +x "$FAKE_REPO/bin/kubectl"
}

# Lance le script copié, faux kubectl en tête du PATH ; stderr joint à
# stdout ; rapport dans le faux dépôt
run_zap() {
  CALLS_LOG="$FAKE_REPO/calls.log" PATH="$FAKE_REPO/bin:$PATH" \
    REPORT_DIR="$FAKE_REPO/report" "$FAKE_REPO/scripts/zap-scan.sh" "$@" 2>&1
}

# Journal des appels reçus par le faux kubectl, pour les vérifier
calls() {
  cat "$FAKE_REPO/calls.log"
}

function test_without_parameter_prints_usage_with_code_2() {
  local output
  output="$(run_zap)"
  assert_exit_code "2"
  assert_contains "Usage: zap-scan.sh baseline|full" "$output"
}

function test_unknown_mode_is_refused_with_code_2() {
  run_zap attack >/dev/null
  assert_exit_code "2"
}

function test_missing_rules_file_stops() {
  local output
  rm "$FAKE_REPO/infra/zap/rules.tsv"
  output="$(run_zap baseline)"
  assert_exit_code "1"
  assert_contains "rules file not found" "$output"
}

function test_baseline_runs_the_passive_scan_in_staging() {
  run_zap baseline >/dev/null
  assert_successful_code
  assert_contains "kubectl -n staging delete job zap --ignore-not-found" \
    "$(calls)"
  assert_contains "zap-baseline.py -t http://microcrm-front:8080" "$(calls)"
  assert_contains "-c rules.tsv -I" "$(calls)"
}

function test_full_runs_the_active_scan_with_a_time_limit() {
  run_zap full >/dev/null
  assert_successful_code
  assert_contains "zap-full-scan.py" "$(calls)"
  assert_contains "ascan.maxScanDurationInMins=10" "$(calls)"
  assert_contains "activeDeadlineSeconds: 2400" "$(calls)"
}

function test_job_runs_without_privileges() {
  run_zap baseline >/dev/null
  assert_contains "runAsNonRoot: true" "$(calls)"
  assert_contains "allowPrivilegeEscalation: false" "$(calls)"
  assert_contains "automountServiceAccountToken: false" "$(calls)"
}

function test_report_is_extracted_from_the_log() {
  run_zap baseline >/dev/null
  assert_equals "# ZAP Scanning Report" "$(cat "$FAKE_REPO/report/report.md")"
}

function test_failed_job_stops_with_code_1_and_keeps_the_report() {
  local output
  output="$(JOB_STATE="/1" run_zap baseline)"
  assert_exit_code "1"
  assert_contains "alerts set to FAIL" "$output"
  assert_file_exists "$FAKE_REPO/report/report.md"
}
