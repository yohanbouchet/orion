#!/usr/bin/env bash
# Fichier  : scripts/tests/backup_test.sh
# Rôle     : tests unitaires de scripts/backup.sh (bashunit), avec un faux
#            kubectl (doublure) qui imite les outils PostgreSQL du pod :
#            aucun vrai cluster ni aucune vraie base
# Utilise  : bashunit 0.52.0, scripts/backup.sh, scripts/lib/common.sh
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Avant chaque test : un faux dépôt avec une copie du script, un faux
# kubectl et un dossier de sauvegardes vide ; par défaut, tout réussit
function set_up() {
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO"/{scripts/lib,bin}
  cp "$SCRIPTS_DIR/backup.sh" "$FAKE_REPO/scripts/"
  cp "$SCRIPTS_DIR/lib/common.sh" "$FAKE_REPO/scripts/lib/"
  make_kubectl
  export BACKUP_DIR="$FAKE_REPO/backups" HAS_KEY=1 PG_DUMP_EXIT=0
}

# Après chaque test : suppression du faux dépôt
function tear_down() {
  rm -rf "$FAKE_REPO"
}

# Faux kubectl : note la commande lancée « dans le pod » et imite sa
# réponse ; ce qui arrive par le tube est lu (comme le ferait le pod)
make_kubectl() {
  cat >"$FAKE_REPO/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Retire « -n ENV exec [-i] POD -- » : reste la commande du pod
args="$*"
cmd="${args#*-- }"
echo "$cmd" >>"$CALLS_LOG"
case "$cmd" in
  *"pg_index"*) echo "$HAS_KEY" ;;
  *"count(*) from person"*) echo "2 persons, 1 organizations" ;;
  "pg_dump"*"--data-only"*) echo "INSERT INTO person VALUES (1);" ;;
  "pg_dump"*) echo "DUMP"; exit "$PG_DUMP_EXIT" ;;
  "pg_restore"* | "psql"*"ON_ERROR_STOP"*) cat >/dev/null ;;
esac
STUB
  chmod +x "$FAKE_REPO/bin/kubectl"
}

# Lance le script copié, faux kubectl en tête du PATH ; stderr joint à
# stdout
run_backup() {
  CALLS_LOG="$FAKE_REPO/calls.log" PATH="$FAKE_REPO/bin:$PATH" \
    "$FAKE_REPO/scripts/backup.sh" "$@" 2>&1
}

# Journal des commandes reçues par le faux kubectl, pour les vérifier
calls() {
  cat "$FAKE_REPO/calls.log"
}

# Une sauvegarde déjà présente, avec son empreinte
make_backup_file() {
  mkdir -p "$BACKUP_DIR/dev"
  echo "DUMP" >"$BACKUP_DIR/dev/$1"
  (cd "$BACKUP_DIR/dev" && sha256sum "$1" >"$1.sha256")
}

function test_without_parameter_prints_usage_with_code_2() {
  local output
  output="$(run_backup)"
  assert_exit_code "2"
  assert_contains "Usage: backup.sh dev|staging|prod" "$output"
}

function test_unknown_environment_is_refused_with_code_2() {
  run_backup verify demo >/dev/null
  assert_exit_code "2"
}

function test_backup_writes_a_private_dump_with_its_checksum() {
  run_backup dev >/dev/null
  assert_successful_code
  local dump
  dump="$(find "$BACKUP_DIR/dev" -name 'microcrm-dev-*.dump')"
  assert_file_exists "$dump"
  assert_file_exists "$dump.sha256"
  # Données personnelles : lisibles par le seul propriétaire
  assert_equals "600" "$(stat -c %a "$dump")"
  assert_equals "700" "$(stat -c %a "$BACKUP_DIR/dev")"
  assert_contains "pg_dump -U microcrm -d microcrm -Fc" "$(calls)"
  assert_contains "pg_restore --list /tmp/check.dump" "$(calls)"
}

function test_backup_writes_the_metric_for_the_alert() {
  export BACKUP_METRICS_DIR="$FAKE_REPO/metrics"
  mkdir -p "$BACKUP_METRICS_DIR"
  run_backup dev >/dev/null
  assert_successful_code
  local file="$BACKUP_METRICS_DIR/microcrm_backup_dev.prom"
  assert_file_exists "$file"
  assert_contains 'microcrm_backup_last_success_timestamp_seconds{env="dev"}' \
    "$(cat "$file")"
  # Lisible par le groupe node_exporter, pas par les autres
  assert_equals "640" "$(stat -c %a "$file")"
  unset BACKUP_METRICS_DIR
}

function test_failed_backup_writes_no_metric() {
  export BACKUP_METRICS_DIR="$FAKE_REPO/metrics" PG_DUMP_EXIT=1
  mkdir -p "$BACKUP_METRICS_DIR"
  run_backup dev >/dev/null
  assert_general_error
  assert_file_not_exists "$BACKUP_METRICS_DIR/microcrm_backup_dev.prom"
  unset BACKUP_METRICS_DIR
}

function test_backup_keeps_only_the_most_recent_ones() {
  make_backup_file microcrm-dev-20260101T000000Z.dump
  make_backup_file microcrm-dev-20260102T000000Z.dump
  KEEP=2 run_backup dev >/dev/null
  assert_file_not_exists "$BACKUP_DIR/dev/microcrm-dev-20260101T000000Z.dump"
  assert_file_exists "$BACKUP_DIR/dev/microcrm-dev-20260102T000000Z.dump"
}

function test_failed_pg_dump_leaves_no_file() {
  local output
  output="$(PG_DUMP_EXIT=1 run_backup dev)"
  assert_exit_code "1"
  assert_contains "pg_dump failed" "$output"
  assert_empty "$(find "$BACKUP_DIR/dev" -type f)"
}

function test_verify_without_backup_stops_with_a_fix() {
  local output
  output="$(run_backup verify dev)"
  assert_exit_code "1"
  assert_contains "fix: run scripts/backup.sh dev" "$output"
}

function test_verify_restores_into_a_temporary_database_then_drops_it() {
  make_backup_file microcrm-dev-20260101T000000Z.dump
  run_backup verify dev >/dev/null
  assert_successful_code
  assert_contains "createdb -U microcrm microcrm_verify" "$(calls)"
  assert_contains "pg_restore -U microcrm -d microcrm_verify" "$(calls)"
  assert_contains "dropdb -U microcrm microcrm_verify" "$(calls)"
}

function test_damaged_backup_is_never_restored() {
  make_backup_file microcrm-dev-20260101T000000Z.dump
  echo "changed" >>"$BACKUP_DIR/dev/microcrm-dev-20260101T000000Z.dump"
  local output
  output="$(run_backup restore dev \
    "$BACKUP_DIR/dev/microcrm-dev-20260101T000000Z.dump")"
  assert_exit_code "1"
  assert_contains "checksum mismatch" "$output"
  assert_not_contains "pg_restore" "$(calls)"
}

function test_full_restore_starts_with_a_safety_backup() {
  make_backup_file microcrm-dev-20260101T000000Z.dump
  run_backup restore dev \
    "$BACKUP_DIR/dev/microcrm-dev-20260101T000000Z.dump" >/dev/null
  assert_successful_code
  # 1re commande de restauration après le pg_dump de sécurité
  assert_equals "pg_dump -U microcrm -d microcrm -Fc" \
    "$(grep -m1 -E '^pg_(dump|restore -U)' "$FAKE_REPO/calls.log")"
  assert_contains "--clean --if-exists --no-owner --single-transaction" \
    "$(calls)"
}

function test_table_restore_only_adds_missing_rows() {
  make_backup_file microcrm-dev-20260101T000000Z.dump
  run_backup restore dev \
    "$BACKUP_DIR/dev/microcrm-dev-20260101T000000Z.dump" \
    --table person >/dev/null
  assert_successful_code
  assert_contains "--table person --inserts --on-conflict-do-nothing" \
    "$(calls)"
  assert_contains "-v ON_ERROR_STOP=1 --single-transaction" "$(calls)"
  assert_not_contains "--clean" "$(calls)"
}

function test_table_without_primary_key_is_refused() {
  make_backup_file microcrm-dev-20260101T000000Z.dump
  local output
  output="$(HAS_KEY=0 run_backup restore dev \
    "$BACKUP_DIR/dev/microcrm-dev-20260101T000000Z.dump" \
    --table organization_persons)"
  assert_exit_code "1"
  assert_contains "without primary key" "$output"
  assert_not_contains "pg_dump" "$(calls)"
}

function test_invalid_table_name_is_refused_with_code_2() {
  make_backup_file microcrm-dev-20260101T000000Z.dump
  run_backup restore dev \
    "$BACKUP_DIR/dev/microcrm-dev-20260101T000000Z.dump" \
    --table "person; drop table person" >/dev/null
  assert_exit_code "2"
}
