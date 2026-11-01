#!/usr/bin/env bash
# Fichier  : scripts/tests/common_test.sh
# Rôle     : tests unitaires de scripts/lib/common.sh (bashunit)
# Utilise  : bashunit 0.52.0, scripts/lib/common.sh
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

# Chemin absolu de la bibliothèque testée, quel que soit le dossier courant
COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

# Lance du code dans un bash séparé qui charge common.sh : le « exit » de
# die ne doit pas arrêter les tests eux-mêmes ; stderr est joint à stdout
run_with_common() {
  bash -c "source '$COMMON'; $1" 2>&1
}

function test_log_prints_date_level_script_and_message() {
  local date_re='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
  local output
  output="$(run_with_common 'SCRIPT_NAME=demo log INFO hello')"
  assert_matches "^${date_re} INFO  demo: hello$" "$output"
}

function test_log_writes_nothing_on_stdout() {
  assert_empty "$(bash -c "source '$COMMON'; log INFO hello" 2>/dev/null)"
}

function test_die_stops_with_given_code_and_error_message() {
  local output
  output="$(run_with_common 'die boom 3; echo not-reached')"
  assert_exit_code "3"
  assert_contains "ERROR" "$output"
  assert_contains "boom" "$output"
  assert_not_contains "not-reached" "$output"
}

function test_die_uses_code_1_by_default() {
  run_with_common 'die boom' >/dev/null
  assert_exit_code "1"
}

function test_require_cmd_accepts_installed_commands() {
  run_with_common 'require_cmd bash date' >/dev/null
  assert_successful_code
}

function test_require_cmd_stops_with_127_on_missing_command() {
  local output
  output="$(run_with_common 'require_cmd bash no-such-cmd-orion')"
  assert_exit_code "127"
  assert_contains "missing required command: no-such-cmd-orion" "$output"
}

function test_common_refuses_to_be_executed_directly() {
  local output
  output="$(bash "$COMMON" 2>&1)"
  assert_exit_code "1"
  assert_contains "must be sourced" "$output"
}
