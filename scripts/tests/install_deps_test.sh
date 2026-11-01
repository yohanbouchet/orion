#!/usr/bin/env bash
# Fichier  : scripts/tests/install_deps_test.sh
# Rôle     : tests unitaires de scripts/install-deps.sh (bashunit), avec de
#            faux outils (doublures) : rapides, sans réseau ni installation
# Utilise  : bashunit 0.52.0, scripts/install-deps.sh, scripts/lib/common.sh
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Avant chaque test : un faux dépôt temporaire avec une copie du script,
# les fichiers de verrouillage et de faux node, npm, java et gradlew
function set_up() {
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO"/{scripts/lib,front,back,bin}
  cp "$SCRIPTS_DIR/install-deps.sh" "$FAKE_REPO/scripts/"
  cp "$SCRIPTS_DIR/lib/common.sh" "$FAKE_REPO/scripts/lib/"
  touch "$FAKE_REPO/front/package-lock.json" "$FAKE_REPO/back/gradle.lockfile"
  local tool
  for tool in bin/node bin/npm bin/java back/gradlew; do
    make_stub "$FAKE_REPO/$tool"
  done
}

# Après chaque test : suppression du faux dépôt
function tear_down() {
  rm -rf "$FAKE_REPO"
}

# Doublure : note son nom et ses paramètres dans CALLS_LOG, puis affiche
# GRADLE_REPORT (le rapport simulé de Gradle, vide par défaut)
make_stub() {
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$CALLS_LOG"
echo "${GRADLE_REPORT:-}"
STUB
  chmod +x "$1"
}

# Lance le script copié, faux outils en tête du PATH ; stderr joint à stdout
run_install() {
  CALLS_LOG="$FAKE_REPO/calls.log" PATH="$FAKE_REPO/bin:$PATH" \
    "$FAKE_REPO/scripts/install-deps.sh" "$@" 2>&1
}

function test_without_parameter_prints_usage_with_code_2() {
  local output
  output="$(run_install)"
  assert_exit_code "2"
  assert_contains "Usage: install-deps.sh front|back" "$output"
}

function test_unknown_target_prints_usage_with_code_2() {
  run_install database >/dev/null
  assert_exit_code "2"
}

function test_front_runs_npm_ci_without_install_scripts() {
  run_install front >/dev/null
  assert_successful_code
  assert_contains "npm ci --ignore-scripts --no-audit --no-fund" \
    "$(cat "$FAKE_REPO/calls.log")"
}

function test_front_stops_without_lockfile() {
  rm "$FAKE_REPO/front/package-lock.json"
  local output
  output="$(run_install front)"
  assert_exit_code "1"
  assert_contains "front/package-lock.json not found" "$output"
}

function test_back_resolves_test_dependencies_with_gradle() {
  run_install back >/dev/null
  assert_successful_code
  assert_contains "gradlew --no-daemon -q dependencies" \
    "$(cat "$FAKE_REPO/calls.log")"
}

function test_back_stops_when_lockfile_does_not_match() {
  local output
  output="$(GRADLE_REPORT='\--- org.example:lib:1.0 FAILED' run_install back)"
  assert_exit_code "1"
  assert_contains "do not match gradle.lockfile" "$output"
}
