#!/usr/bin/env bash
# Fichier  : scripts/tests/e2e_test.sh
# Rôle     : tests unitaires de scripts/e2e.sh (bashunit), avec un faux
#            docker (doublure) : aucun conteneur ni navigateur lancé
# Utilise  : bashunit 0.52.0, scripts/e2e.sh, scripts/lib/common.sh
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Avant chaque test : un faux dépôt (script, bibliothèque, dossier e2e)
# et un faux docker ; par défaut, tout réussit
function set_up() {
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO"/{scripts/lib,bin,e2e}
  cp "$SCRIPTS_DIR/e2e.sh" "$FAKE_REPO/scripts/"
  cp "$SCRIPTS_DIR/lib/common.sh" "$FAKE_REPO/scripts/lib/"
  touch "$FAKE_REPO/e2e/compose.yaml"
  make_docker
  export UP_EXIT=0 RUN_EXIT=0
}

# Après chaque test : suppression du faux dépôt
function tear_down() {
  rm -rf "$FAKE_REPO"
}

# Faux docker : note chaque commande et les variables reçues par compose
make_docker() {
  cat >"$FAKE_REPO/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CALLS_LOG"
echo "FRONT=$FRONT_IMAGE BACK=$BACK_IMAGE PWLEN=${#E2E_DB_PASSWORD}" \
  >>"$ENV_LOG"
case "$*" in
  *" up "*) exit "$UP_EXIT" ;;
  *" run --rm playwright"*) exit "$RUN_EXIT" ;;
esac
STUB
  chmod +x "$FAKE_REPO/bin/docker"
}

# Lance le script copié, faux docker en tête du PATH ; stderr joint
run_e2e() {
  CALLS_LOG="$FAKE_REPO/calls.log" ENV_LOG="$FAKE_REPO/env.log" \
    PATH="$FAKE_REPO/bin:$PATH" "$FAKE_REPO/scripts/e2e.sh" "$@" 2>&1
}

calls() {
  cat "$FAKE_REPO/calls.log"
}

function test_wrong_arguments_print_usage_with_code_2() {
  local output
  output="$(run_e2e only-one)"
  assert_exit_code "2"
  assert_contains "Usage: e2e.sh FRONT_IMAGE BACK_IMAGE" "$output"
}

function test_stack_waits_for_health_then_runs_the_browser_tests() {
  run_e2e front:1 back:1 >/dev/null
  assert_successful_code
  assert_contains "up --detach --wait --wait-timeout 180 db back front" \
    "$(calls)"
  assert_contains "--profile tests run --rm playwright" "$(calls)"
  # Images transmises à compose ; mot de passe aléatoire de 32 caractères
  assert_contains "FRONT=front:1 BACK=back:1 PWLEN=32" \
    "$(cat "$FAKE_REPO/env.log")"
}

function test_everything_is_removed_after_success() {
  run_e2e front:1 back:1 >/dev/null
  assert_contains "down --volumes --remove-orphans" "$(calls)"
}

function test_stack_that_does_not_start_stops_without_tests() {
  local output
  output="$(UP_EXIT=1 run_e2e front:1 back:1)"
  assert_exit_code "1"
  assert_contains "the stack did not start" "$output"
  assert_not_contains "run --rm playwright" "$(calls)"
  # Journaux gardés et tout supprimé, même après l'échec
  assert_contains "logs --no-color back front" "$(calls)"
  assert_contains "down --volumes" "$(calls)"
}

function test_failed_browser_tests_give_code_1_and_clean_up() {
  local output
  output="$(RUN_EXIT=1 run_e2e front:1 back:1)"
  assert_exit_code "1"
  assert_contains "open e2e/playwright-report/index.html" "$output"
  assert_contains "down --volumes" "$(calls)"
}

function test_password_never_appears_in_a_command() {
  run_e2e front:1 back:1 >/dev/null
  assert_not_contains "E2E_DB_PASSWORD=" "$(calls)"
}
