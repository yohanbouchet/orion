#!/usr/bin/env bash
# Fichier  : scripts/tests/backup_openbao_test.sh
# Rôle     : tests unitaires de scripts/backup-openbao.sh (bashunit), avec
#            un faux kubectl (doublure) qui imite le pod d'OpenBao et une
#            fausse archive d'instantané : aucun vrai cluster ni coffre
# Utilise  : bashunit 0.52.0, scripts/backup-openbao.sh,
#            scripts/lib/common.sh ; tar, sha256sum, openssl
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_TOKEN="s.fake-backup-token"

# Avant chaque test : un faux dépôt avec une copie du script, un faux
# kubectl, un jeton en 600 et une archive d'instantané valide
function set_up() {
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO"/{scripts/lib,bin,pod}
  cp "$SCRIPTS_DIR/backup-openbao.sh" "$FAKE_REPO/scripts/"
  cp "$SCRIPTS_DIR/lib/common.sh" "$FAKE_REPO/scripts/lib/"
  make_kubectl
  make_snapshot valid
  printf '%s\n' "$FAKE_TOKEN" >"$FAKE_REPO/token"
  chmod 600 "$FAKE_REPO/token"
  export BACKUP_DIR="$FAKE_REPO/backups" \
    OPENBAO_BACKUP_TOKEN_FILE="$FAKE_REPO/token" \
    SEAL_CODE=0 SNAP_EXIT=0 CORRUPT=0
}

# Après chaque test : suppression du faux dépôt
function tear_down() {
  rm -rf "$FAKE_REPO"
}

# Archive au format d'un instantané Raft : state.bin, meta.json et leurs
# empreintes ; « broken » : empreinte fausse dans SHA256SUMS
make_snapshot() {
  local work="$FAKE_REPO/snap"
  mkdir -p "$work"
  echo "raft data" >"$work/state.bin"
  echo '{"Index":42}' >"$work/meta.json"
  (cd "$work" && sha256sum state.bin meta.json >SHA256SUMS)
  if [[ "$1" == "broken" ]]; then
    echo "changed" >>"$work/state.bin"
  fi
  tar -czf "$FAKE_REPO/pod/openbao.snap" -C "$work" \
    state.bin meta.json SHA256SUMS
}

# Faux kubectl : note la commande lancée « dans le pod » et imite sa
# réponse ; le jeton reçu par l'entrée standard est gardé à part
make_kubectl() {
  cat >"$FAKE_REPO/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Retire « -n NS exec [-i] POD -- » : reste la commande du pod
args="$*"
cmd="${args#*-- }"
echo "$cmd" >>"$CALLS_LOG"
snap="$FAKE_DIR/pod/openbao.snap"
case "$cmd" in
  "bao status") exit "$SEAL_CODE" ;;
  "sh -c"*)
    cat >"$FAKE_DIR/token_seen"
    [[ "$SNAP_EXIT" == "0" ]] || exit "$SNAP_EXIT"
    sha256sum "$snap" | sed "s|$snap|/tmp/openbao.snap|"
    ;;
  "cat /openbao/tls/tls.crt") cat "$FAKE_DIR/pod/tls.crt" ;;
  "cat /tmp/openbao.snap")
    cat "$snap"
    [[ "$CORRUPT" == "0" ]] || echo "noise"
    ;;
esac
STUB
  chmod +x "$FAKE_REPO/bin/kubectl"
}

# Certificat jetable valable 10 jours (partie publique seulement)
make_cert() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$FAKE_REPO/tls.key" -out "$FAKE_REPO/pod/tls.crt" \
    -days 10 -subj "/CN=openbao.openbao.svc" 2>/dev/null
}

# Lance le script copié, faux kubectl en tête du PATH ; stderr joint à
# stdout
run_backup() {
  CALLS_LOG="$FAKE_REPO/calls.log" FAKE_DIR="$FAKE_REPO" \
    PATH="$FAKE_REPO/bin:$PATH" \
    "$FAKE_REPO/scripts/backup-openbao.sh" "$@" 2>&1
}

# Journal des commandes reçues par le faux kubectl
calls() {
  cat "$FAKE_REPO/calls.log"
}

# Instantanés gardés sur le poste
snapshots() {
  find "$BACKUP_DIR" -name 'openbao-*.snap' 2>/dev/null
}

function test_an_argument_prints_usage_with_code_2() {
  local output
  output="$(run_backup now)"
  assert_exit_code "2"
  assert_contains "Usage: backup-openbao.sh" "$output"
}

function test_missing_token_file_stops_with_a_fix() {
  local output
  output="$(OPENBAO_BACKUP_TOKEN_FILE="$FAKE_REPO/none" run_backup)"
  assert_exit_code "1"
  assert_contains "fix: create it" "$output"
}

function test_token_readable_by_others_is_refused() {
  chmod 644 "$FAKE_REPO/token"
  local output
  output="$(run_backup)"
  assert_exit_code "1"
  assert_contains "must have mode 600" "$output"
  assert_file_not_exists "$FAKE_REPO/calls.log"
}

function test_sealed_vault_is_not_backed_up() {
  local output
  output="$(SEAL_CODE=2 run_backup)"
  assert_exit_code "1"
  assert_contains "OpenBao is sealed" "$output"
  assert_not_contains "snapshot save" "$(calls)"
}

function test_backup_keeps_a_private_snapshot_with_its_checksum() {
  run_backup >/dev/null
  assert_successful_code
  local snap
  snap="$(snapshots)"
  assert_file_exists "$snap"
  assert_file_exists "$snap.sha256"
  assert_equals "600" "$(stat -c %a "$snap")"
  assert_equals "700" "$(stat -c %a "$BACKUP_DIR")"
  # Fichier du pod toujours effacé
  assert_contains "rm -f /tmp/openbao.snap" "$(calls)"
}

function test_token_goes_through_stdin_never_in_arguments() {
  run_backup >/dev/null
  assert_successful_code
  assert_equals "$FAKE_TOKEN" "$(cat "$FAKE_REPO/token_seen")"
  assert_not_contains "$FAKE_TOKEN" "$(calls)"
  # Le jeton est prolongé à chaque sauvegarde
  assert_contains "bao token renew" "$(calls)"
}

function test_backup_writes_the_metric_for_the_alert() {
  export BACKUP_METRICS_DIR="$FAKE_REPO/metrics"
  mkdir -p "$BACKUP_METRICS_DIR"
  run_backup >/dev/null
  assert_successful_code
  local file="$BACKUP_METRICS_DIR/openbao_backup.prom"
  assert_contains "openbao_backup_last_success_timestamp_seconds " \
    "$(cat "$file")"
  assert_equals "640" "$(stat -c %a "$file")"
  unset BACKUP_METRICS_DIR
}

function test_failed_snapshot_keeps_nothing_and_writes_no_metric() {
  export BACKUP_METRICS_DIR="$FAKE_REPO/metrics"
  mkdir -p "$BACKUP_METRICS_DIR"
  local output
  output="$(SNAP_EXIT=2 run_backup)"
  assert_exit_code "1"
  assert_contains "snapshot failed" "$output"
  assert_empty "$(snapshots)"
  assert_file_not_exists "$BACKUP_METRICS_DIR/openbao_backup.prom"
  assert_contains "rm -f /tmp/openbao.snap" "$(calls)"
  unset BACKUP_METRICS_DIR
}

function test_copy_damaged_on_the_way_is_not_kept() {
  local output
  output="$(CORRUPT=1 run_backup)"
  assert_exit_code "1"
  assert_contains "damaged during the copy" "$output"
  assert_empty "$(find "$BACKUP_DIR" -type f)"
}

function test_archive_with_a_wrong_checksum_is_not_kept() {
  make_snapshot broken
  local output
  output="$(run_backup)"
  assert_exit_code "1"
  assert_contains "nothing kept" "$output"
  assert_empty "$(find "$BACKUP_DIR" -type f)"
}

function test_backup_keeps_only_the_most_recent_ones() {
  mkdir -p "$BACKUP_DIR"
  touch "$BACKUP_DIR/openbao-20260101T000000Z.snap" \
    "$BACKUP_DIR/openbao-20260102T000000Z.snap"
  KEEP=2 run_backup >/dev/null
  assert_successful_code
  assert_file_not_exists "$BACKUP_DIR/openbao-20260101T000000Z.snap"
  assert_file_exists "$BACKUP_DIR/openbao-20260102T000000Z.snap"
}

function test_certificate_expiry_is_written_for_the_alert() {
  make_cert
  export BACKUP_METRICS_DIR="$FAKE_REPO/metrics"
  mkdir -p "$BACKUP_METRICS_DIR"
  run_backup >/dev/null
  assert_successful_code
  local expected
  expected="$(date -d "$(openssl x509 -noout -enddate \
    -in "$FAKE_REPO/pod/tls.crt" | cut -d= -f2)" +%s)"
  assert_contains "openbao_tls_cert_not_after_timestamp_seconds $expected" \
    "$(cat "$BACKUP_METRICS_DIR/openbao_tls.prom")"
  assert_equals "640" "$(stat -c %a "$BACKUP_METRICS_DIR/openbao_tls.prom")"
  unset BACKUP_METRICS_DIR
}

function test_unreadable_certificate_does_not_stop_the_backup() {
  export BACKUP_METRICS_DIR="$FAKE_REPO/metrics"
  mkdir -p "$BACKUP_METRICS_DIR"
  local output
  output="$(run_backup)"
  assert_successful_code
  assert_contains "certificate expiry not read" "$output"
  assert_file_not_exists "$BACKUP_METRICS_DIR/openbao_tls.prom"
  assert_file_exists "$BACKUP_METRICS_DIR/openbao_backup.prom"
  unset BACKUP_METRICS_DIR
}
