#!/usr/bin/env bash
# Fichier  : scripts/backup-openbao.sh
# Rôle     : sauvegarde le coffre OpenBao (instantané du stockage Raft),
#            vérifie le fichier (empreinte identique dans le pod et sur
#            le poste, archive complète et intacte), garde les plus
#            récents et écrit la métrique de la dernière réussite ; écrit
#            aussi la date d'expiration du certificat TLS du coffre
# Utilise  : scripts/lib/common.sh ; kubectl, sha256sum, tar, openssl,
#            date ; bao (dans le pod) ; jeton de sauvegarde (règle
#            openbao-backup,
#            infra/openbao/config/backup.tf)
# Utilisé par : tâche planifiée installée par Ansible (rôle backup) ;
#               l'Ops, avant une opération risquée ; recommandation 26
# Usage    : scripts/backup-openbao.sh
# Paramètres : OPENBAO_BACKUP_TOKEN_FILE = fichier du jeton (défaut
#              ~/.config/orion-openbao/backup-token, droits 600 exigés) ;
#              BACKUP_DIR = dossier des instantanés (défaut
#              ~/backups/openbao) ; KEEP = nombre gardé (défaut 7) ;
#              BACKUP_METRICS_DIR = dossier lu par node_exporter (vide par
#              défaut : aucune métrique écrite)
# Restauration : README d'OpenBao, « Sauvegarde planifiée »

# Arrêt à la première erreur, variable inconnue, erreur dans un tube
set -Eeuo pipefail
# Fichiers créés lisibles par leur seul propriétaire
umask 077

# Dossiers calculés depuis l'emplacement du script : lançable de partout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="backup-openbao.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Pod et chemin temporaire définis par le chart (infra/openbao)
NAMESPACE="openbao"
POD="openbao-0"
REMOTE_FILE="/tmp/openbao.snap"
DEFAULT_TOKEN_FILE="$HOME/.config/orion-openbao/backup-token"
TOKEN_FILE="${OPENBAO_BACKUP_TOKEN_FILE:-$DEFAULT_TOKEN_FILE}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/openbao}"
KEEP="${KEEP:-7}"
BACKUP_METRICS_DIR="${BACKUP_METRICS_DIR:-}"

# Commande lancée dans le pod d'OpenBao ; -i transmet l'entrée standard
in_pod() {
  kubectl -n "$NAMESPACE" exec "$POD" -- "$@"
}
in_pod_stdin() {
  kubectl -n "$NAMESPACE" exec -i "$POD" -- "$@"
}

# Le jeton doit exister et n'être lisible que par son propriétaire
check_token_file() {
  [[ -f "$TOKEN_FILE" ]] ||
    die "token file $TOKEN_FILE not found;" \
      "fix: create it (infra/openbao/README.md, scheduled backup)"
  [[ "$(stat -c %a "$TOKEN_FILE")" == "600" ]] ||
    die "token file $TOKEN_FILE must have mode 600;" \
      "fix: chmod 600 $TOKEN_FILE"
}

# Un coffre scellé ne peut pas être sauvegardé (bao status : code 2)
check_unsealed() {
  local code=0
  in_pod bao status >/dev/null 2>&1 || code=$?
  case "$code" in
    0) ;;
    2) die "OpenBao is sealed;" "fix: unseal it (infra/openbao/README.md)" ;;
    *) die "OpenBao is not reachable (code $code);" \
      "fix: kubectl -n $NAMESPACE get pods" ;;
  esac
}

# Instantané pris dans le pod : le jeton arrive par l'entrée standard
# (jamais en argument, donc jamais visible dans la liste des processus),
# prolongé de sa période, puis l'empreinte du fichier est affichée ;
# un fichier de jeton sans retour à la ligne final est accepté
snapshot_in_pod() {
  # shellcheck disable=SC2016 # variables développées dans le pod
  in_pod_stdin sh -c '{ IFS= read -r BAO_TOKEN || [ -n "$BAO_TOKEN" ]; } &&
    export BAO_TOKEN &&
    bao token renew >/dev/null &&
    bao operator raft snapshot save "$1" && sha256sum "$1"' \
    sh "$REMOTE_FILE" <"$TOKEN_FILE" | cut -d' ' -f1
}

# Archive complète et intacte : l'instantané Raft est une archive tar
# compressée qui contient les données (state.bin), leur description
# (meta.json) et leurs empreintes (SHA256SUMS), vérifiées ici
check_archive() {
  local file="$1" work
  work="$(mktemp -d)"
  if ! tar -xzf "$file" -C "$work" 2>/dev/null ||
    [[ ! -s "$work/state.bin" || ! -f "$work/meta.json" ]] ||
    ! (cd "$work" && sha256sum --check --quiet SHA256SUMS >/dev/null 2>&1); then
    rm -rf "${work:?}"
    return 1
  fi
  rm -rf "${work:?}"
}

# Métrique pour la supervision (alerte OpenBaoBackupTooOld) : écrite
# puis renommée, pour que node_exporter ne lise jamais un fichier à
# moitié écrit ; lisible par son groupe
write_metric() {
  [[ -n "$BACKUP_METRICS_DIR" ]] || return 0
  local file="$BACKUP_METRICS_DIR/openbao_backup.prom"
  {
    echo "# HELP openbao_backup_last_success_timestamp_seconds" \
      "Time of the last successful OpenBao snapshot."
    echo "# TYPE openbao_backup_last_success_timestamp_seconds gauge"
    echo "openbao_backup_last_success_timestamp_seconds $(date +%s)"
  } >"$file.tmp"
  chmod 640 "$file.tmp"
  mv "$file.tmp" "$file"
}

# Métrique de l'expiration du certificat TLS du coffre (alerte
# OpenBaoCertExpiringSoon, 30 jours avant) : lue dans la partie publique
# du certificat, jamais dans la clé ; un échec n'arrête pas la sauvegarde
write_cert_metric() {
  [[ -n "$BACKUP_METRICS_DIR" ]] || return 0
  local end not_after file="$BACKUP_METRICS_DIR/openbao_tls.prom"
  if ! end="$(in_pod cat /openbao/tls/tls.crt |
    openssl x509 -noout -enddate 2>/dev/null)" ||
    ! not_after="$(date -d "${end#notAfter=}" +%s 2>/dev/null)"; then
    log WARN "certificate expiry not read; metric not updated"
    return 0
  fi
  {
    echo "# HELP openbao_tls_cert_not_after_timestamp_seconds" \
      "Expiry time of the OpenBao TLS certificate."
    echo "# TYPE openbao_tls_cert_not_after_timestamp_seconds gauge"
    echo "openbao_tls_cert_not_after_timestamp_seconds $not_after"
  } >"$file.tmp"
  chmod 640 "$file.tmp"
  mv "$file.tmp" "$file"
}

main() {
  [[ $# -eq 0 ]] || {
    echo "Usage: $SCRIPT_NAME" >&2
    exit 2
  }
  require_cmd kubectl sha256sum tar openssl
  write_cert_metric
  check_token_file
  check_unsealed

  local name remote_sum local_sum
  name="openbao-$(date -u +%Y%m%dT%H%M%SZ).snap"
  mkdir -p "$BACKUP_DIR"
  # Le fichier du pod est toujours effacé, même après une erreur
  trap 'in_pod rm -f "$REMOTE_FILE" >/dev/null 2>&1 || true' EXIT

  remote_sum="$(snapshot_in_pod)" ||
    die "snapshot failed;" \
      "fix: check the token (expired after 7 days without backup?)"
  [[ -n "$remote_sum" ]] || die "snapshot failed: no checksum returned"

  # Copie vers le poste dans un fichier temporaire, renommé seulement si
  # l'empreinte est identique et l'archive intacte
  in_pod cat "$REMOTE_FILE" >"$BACKUP_DIR/$name.tmp"
  local_sum="$(sha256sum "$BACKUP_DIR/$name.tmp" | cut -d' ' -f1)"
  if [[ "$local_sum" != "$remote_sum" ]] ||
    ! check_archive "$BACKUP_DIR/$name.tmp"; then
    rm -f "$BACKUP_DIR/$name.tmp"
    die "snapshot $name damaged during the copy; nothing kept"
  fi
  mv "$BACKUP_DIR/$name.tmp" "$BACKUP_DIR/$name"
  (cd "$BACKUP_DIR" && sha256sum "$name" >"$name.sha256")

  # Rotation : les noms contiennent la date, le tri donne l'ordre
  find "$BACKUP_DIR" -name 'openbao-*.snap' | sort -r |
    tail -n +"$((KEEP + 1))" | while read -r old; do
      rm -f "$old" "$old.sha256"
      log INFO "old snapshot removed: $(basename "$old")"
    done

  write_metric
  log INFO "snapshot ready: $BACKUP_DIR/$name" \
    "($(du -h "$BACKUP_DIR/$name" | cut -f1))"
}

main "$@"
