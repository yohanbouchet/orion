#!/usr/bin/env bash
# Fichier  : scripts/tests/run_tests_test.sh
# Rôle     : tests unitaires de scripts/run-tests.sh (bashunit), avec de
#            faux outils (doublures) : aucun vrai test lancé
# Utilise  : bashunit 0.52.0, scripts/run-tests.sh, scripts/lib/common.sh
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Avant chaque test : un faux dépôt avec une copie du script, des
# dépendances « installées », des rapports de couverture déjà produits et
# de faux node, npx, java et gradlew
function set_up() {
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO"/{scripts/lib,bin,front/node_modules} \
    "$FAKE_REPO"/front/coverage/microcrm \
    "$FAKE_REPO"/back/build/reports/jacoco/test
  cp "$SCRIPTS_DIR/run-tests.sh" "$FAKE_REPO/scripts/"
  cp "$SCRIPTS_DIR/lib/common.sh" "$FAKE_REPO/scripts/lib/"
  echo "TN:" >"$FAKE_REPO/front/coverage/microcrm/lcov.info"
  echo "<report/>" \
    >"$FAKE_REPO/back/build/reports/jacoco/test/jacocoTestReport.xml"
  local tool
  for tool in bin/node bin/npx bin/java back/gradlew; do
    make_stub "$FAKE_REPO/$tool"
  done
}

# Après chaque test : suppression du faux dépôt
function tear_down() {
  rm -rf "$FAKE_REPO"
}

# Doublure : note son nom et ses paramètres dans CALLS_LOG, puis rend le
# code STUB_EXIT (0 par défaut ; 1 simule des tests en échec)
make_stub() {
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$CALLS_LOG"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$1"
}

# Lance le script copié, faux outils en tête du PATH ; stderr joint à stdout
run_tests() {
  CALLS_LOG="$FAKE_REPO/calls.log" PATH="$FAKE_REPO/bin:$PATH" \
    "$FAKE_REPO/scripts/run-tests.sh" "$@" 2>&1
}

function test_without_parameter_prints_usage_with_code_2() {
  local output
  output="$(run_tests)"
  assert_exit_code "2"
  assert_contains "Usage: run-tests.sh front|back" "$output"
}

function test_front_stops_when_dependencies_are_missing() {
  rm -rf "$FAKE_REPO/front/node_modules"
  local output
  output="$(run_tests front)"
  assert_exit_code "1"
  assert_contains "fix: run scripts/install-deps.sh front" "$output"
}

function test_front_runs_vitest_once_without_browser() {
  run_tests front >/dev/null
  assert_successful_code
  assert_contains "npx ng test --no-watch --no-progress" \
    "$(cat "$FAKE_REPO/calls.log")"
  assert_not_contains "--browsers" "$(cat "$FAKE_REPO/calls.log")"
}

function test_front_failure_stops_the_script() {
  local output
  output="$(STUB_EXIT=1 run_tests front)"
  assert_exit_code "1"
  assert_not_contains "tests passed" "$output"
}

function test_back_runs_gradle_test() {
  run_tests back >/dev/null
  assert_successful_code
  assert_contains "gradlew test --no-daemon" "$(cat "$FAKE_REPO/calls.log")"
}

function test_back_stops_without_coverage_report() {
  rm "$FAKE_REPO/back/build/reports/jacoco/test/jacocoTestReport.xml"
  local output
  output="$(run_tests back)"
  assert_exit_code "1"
  assert_contains "coverage report" "$output"
  assert_contains "missing or empty" "$output"
}
