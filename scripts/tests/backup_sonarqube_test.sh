#!/usr/bin/env bash
# Fichier  : scripts/tests/backup_sonarqube_test.sh
# Rôle     : tests unitaires de scripts/backup-sonarqube.sh (bashunit),
#            avec un faux kubectl (doublure) qui imite les outils
#            PostgreSQL du pod et l'état de SonarQube (démarré ou
#            arrêté) : aucun vrai cluster ni aucune vraie base
# Utilise  : bashunit 0.52.0, scripts/backup-sonarqube.sh,
#            scripts/lib/common.sh
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Avant chaque test : un faux dépôt avec une copie du script, un faux
# kubectl et un dossier de sauvegardes vide ; par défaut, tout réussit et
# SonarQube est arrêté
function set_up() {
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO"/{scripts/lib,bin}
  cp "$SCRIPTS_DIR/backup-sonarqube.sh" "$FAKE_REPO/scripts/"
  cp "$SCRIPTS_DIR/lib/common.sh" "$FAKE_REPO/scripts/lib/"
  make_kubectl
  export BACKUP_DIR="$FAKE_REPO/backups" PG_DUMP_EXIT=0 REPLICAS=0
}

# Après chaque test : suppression du faux dépôt
function tear_down() {
  rm -rf "$FAKE_REPO"
}

# Faux kubectl : note la commande lancée (« dans le pod » ou sur le
# cluster) et imite sa réponse ; ce qui arrive par le tube est lu
make_kubectl() {
  cat >"$FAKE_REPO/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Retire « -n NS exec [-i] POD -- » : reste la commande du pod
args="$*"
cmd="${args#*-- }"
echo "$cmd" >>"$CALLS_LOG"
case "$cmd" in
  *"get statefulset/sonarqube-sonarqube"*) echo "$REPLICAS" ;;
  *"count(*) from projects"*) echo "1 projects, 2 users" ;;
  "pg_dump"*) echo "DUMP"; exit "$PG_DUMP_EXIT" ;;
  "sh -c"* | "pg_restore"*) cat >/dev/null ;;
esac
STUB
  chmod +x "$FAKE_REPO/bin/kubectl"
}

# Lance le script copié, faux kubectl en tête du PATH ; stderr joint à
# stdout
run_backup() {
  CALLS_LOG="$FAKE_REPO/calls.log" PATH="$FAKE_REPO/bin:$PATH" \
    "$FAKE_REPO/scripts/backup-sonarqube.sh" "$@" 2>&1
}

# Journal des commandes reçues par le faux kubectl, pour les vérifier
calls() {
  cat "$FAKE_REPO/calls.log"
}

# Une sauvegarde déjà présente, avec son empreinte
make_backup_file() {
  mkdir -p "$BACKUP_DIR"
  echo "DUMP" >"$BACKUP_DIR/$1"
  (cd "$BACKUP_DIR" && sha256sum "$1" >"$1.sha256")
}

function test_unknown_argument_prints_usage_with_code_2() {
  local output
  output="$(run_backup now)"
  assert_exit_code "2"
  assert_contains "Usage: backup-sonarqube.sh" "$output"
}

function test_restore_without_file_prints_usage_with_code_2() {
  run_backup restore >/dev/null
  assert_exit_code "2"
}

function test_backup_writes_a_private_dump_checked_by_pg_restore() {
  run_backup >/dev/null
  assert_successful_code
  local dump
  dump="$(find "$BACKUP_DIR" -name 'sonarqube-*.dump')"
  assert_file_exists "$dump"
  assert_file_exists "$dump.sha256"
  # Comptes et jetons de SonarQube : lisibles par le seul propriétaire
  assert_equals "600" "$(stat -c %a "$dump")"
  assert_contains "pg_dump -U sonarqube -d sonarqube -Fc" "$(calls)"
  # Fichier copié en entier dans le pod avant d'être lu (jamais bloqué)
  assert_contains "pg_restore --list /tmp/check.dump" "$(calls)"
}

function test_backup_writes_the_metric_for_the_alert() {
  export BACKUP_METRICS_DIR="$FAKE_REPO/metrics"
  mkdir -p "$BACKUP_METRICS_DIR"
  run_backup >/dev/null
  assert_successful_code
  local file="$BACKUP_METRICS_DIR/sonarqube_backup.prom"
  assert_file_exists "$file"
  assert_contains "sonarqube_backup_last_success_timestamp_seconds " \
    "$(cat "$file")"
  assert_equals "640" "$(stat -c %a "$file")"
}

function test_failed_pg_dump_leaves_no_file_and_no_metric() {
  export BACKUP_METRICS_DIR="$FAKE_REPO/metrics" PG_DUMP_EXIT=1
  mkdir -p "$BACKUP_METRICS_DIR"
  local output
  output="$(run_backup)"
  assert_exit_code "1"
  assert_contains "pg_dump failed" "$output"
  assert_empty "$(find "$BACKUP_DIR" -type f)"
  assert_file_not_exists "$BACKUP_METRICS_DIR/sonarqube_backup.prom"
}

function test_backup_keeps_only_the_most_recent_ones() {
  make_backup_file sonarqube-20260101T000000Z.dump
  make_backup_file sonarqube-20260102T000000Z.dump
  KEEP=2 run_backup >/dev/null
  assert_file_not_exists "$BACKUP_DIR/sonarqube-20260101T000000Z.dump"
  assert_file_exists "$BACKUP_DIR/sonarqube-20260102T000000Z.dump"
}

function test_verify_without_backup_stops_with_a_fix() {
  local output
  output="$(run_backup verify)"
  assert_exit_code "1"
  assert_contains "fix: run scripts/backup-sonarqube.sh" "$output"
}

function test_verify_restores_into_a_temporary_database_then_drops_it() {
  make_backup_file sonarqube-20260101T000000Z.dump
  run_backup verify >/dev/null
  assert_successful_code
  assert_contains "createdb -U sonarqube sonarqube_verify" "$(calls)"
  assert_contains "pg_restore -U sonarqube -d sonarqube_verify" "$(calls)"
  assert_contains "dropdb -U sonarqube sonarqube_verify" "$(calls)"
}

function test_damaged_backup_is_never_restored() {
  make_backup_file sonarqube-20260101T000000Z.dump
  echo "changed" >>"$BACKUP_DIR/sonarqube-20260101T000000Z.dump"
  local output
  output="$(run_backup verify)"
  assert_exit_code "1"
  assert_contains "checksum mismatch" "$output"
  assert_not_contains "pg_restore" "$(calls)"
}

function test_restore_is_refused_while_sonarqube_runs() {
  make_backup_file sonarqube-20260101T000000Z.dump
  local output
  output="$(REPLICAS=1 run_backup restore \
    "$BACKUP_DIR/sonarqube-20260101T000000Z.dump")"
  assert_exit_code "1"
  assert_contains "fix: kubectl -n sonarqube scale" "$output"
  assert_not_contains "pg_dump" "$(calls)"
  assert_not_contains "--clean" "$(calls)"
}

# Avec KEEP sauvegardes déjà présentes, la sauvegarde de sécurité ne doit
# pas faire supprimer par la rotation le fichier qu'on restaure
function test_restoring_the_oldest_backup_does_not_delete_it() {
  make_backup_file sonarqube-20260101T000000Z.dump
  make_backup_file sonarqube-20260102T000000Z.dump
  KEEP=2 run_backup restore \
    "$BACKUP_DIR/sonarqube-20260101T000000Z.dump" >/dev/null
  assert_successful_code
  assert_file_exists "$BACKUP_DIR/sonarqube-20260101T000000Z.dump"
  assert_contains "--clean --if-exists" "$(calls)"
}

function test_restore_takes_a_safety_backup_then_clears_the_index() {
  make_backup_file sonarqube-20260101T000000Z.dump
  run_backup restore "$BACKUP_DIR/sonarqube-20260101T000000Z.dump" \
    >/dev/null
  assert_successful_code
  # Ordre : sauvegarde de sécurité, restauration, puis index supprimé
  assert_equals "pg_dump -U sonarqube -d sonarqube -Fc" \
    "$(grep -m1 -E '^pg_(dump|restore -U)' "$FAKE_REPO/calls.log")"
  assert_contains "--clean --if-exists --no-owner --single-transaction" \
    "$(calls)"
  assert_equals "delete pvc sonarqube-sonarqube" \
    "$(grep -o 'delete pvc sonarqube-sonarqube' "$FAKE_REPO/calls.log")"
}
