#!/usr/bin/env bash
# Fichier  : scripts/backup-sonarqube.sh
# Rôle     : sauvegarde la base PostgreSQL de SonarQube (pg_dump) :
#            historique de la qualité, réglages, comptes et jetons ;
#            vérifie qu'une sauvegarde se restaure (base temporaire) ;
#            restaure la base, SonarQube arrêté, après une sauvegarde de
#            sécurité. Seule la base est sauvegardée, comme le demande la
#            documentation de SonarQube : son index de recherche se
#            reconstruit au démarrage
# Utilise  : scripts/lib/common.sh ; kubectl, sha256sum ; outils
#            PostgreSQL du pod de la base (infra/sonarqube/postgres.yaml)
# Utilisé par : tâches planifiées installées par Ansible (rôle backup) ;
#               l'opérateur, avant une montée de version ou une
#               reconstruction du cluster ; recommandation 20 du rapport
# Usage    : scripts/backup-sonarqube.sh
#            scripts/backup-sonarqube.sh verify [FILE]
#            scripts/backup-sonarqube.sh restore FILE
# Paramètres : BACKUP_DIR (défaut ~/backups/sonarqube) ; KEEP = nombre de
#              sauvegardes gardées (défaut 7) ; BACKUP_METRICS_DIR =
#              dossier lu par node_exporter (alerte SonarQubeBackupTooOld ;
#              vide par défaut : aucune métrique écrite)

# Arrêt à la première erreur, variable inconnue, erreur dans un tube
set -Eeuo pipefail
# Fichiers créés lisibles par leur seul propriétaire : la base contient
# les comptes et les jetons (chiffrés) de SonarQube
umask 077

# Dossiers calculés depuis l'emplacement du script : lançable de partout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="backup-sonarqube.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Namespace, pods, base et compte définis par infra/sonarqube/ et le chart
NAMESPACE="sonarqube"
POD="sonarqube-db-0"
DB="sonarqube"
DB_USER="sonarqube"
APP="statefulset/sonarqube-sonarqube"
# Disque de l'index de recherche, créé par le chart (persistence)
INDEX_PVC="sonarqube-sonarqube"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/sonarqube}"
KEEP="${KEEP:-7}"
BACKUP_METRICS_DIR="${BACKUP_METRICS_DIR:-}"
# Chemin de la dernière sauvegarde faite (cité si une restauration échoue)
LAST_BACKUP=""

# Mauvais usage : rappel de la syntaxe, code 2
usage() {
  echo "Usage: $SCRIPT_NAME" >&2
  echo "       $SCRIPT_NAME verify [FILE]" >&2
  echo "       $SCRIPT_NAME restore FILE" >&2
  exit 2
}

# Commande lancée dans le pod de la base ; -i transmet aussi l'entrée
# standard (un fichier de sauvegarde envoyé au pod)
in_pod() {
  kubectl -n "$NAMESPACE" exec "$POD" -- "$@"
}
in_pod_stdin() {
  kubectl -n "$NAMESPACE" exec -i "$POD" -- "$@"
}

# Projets analysés et comptes d'une base, pour le journal
count_rows() {
  in_pod psql -U "$DB_USER" -d "$1" -tAc "select
    (select count(*) from projects) || ' projects, ' ||
    (select count(*) from users) || ' users'"
}

# Empreinte du fichier comparée à celle notée à la sauvegarde : un
# fichier abîmé ou modifié n'est jamais restauré
check_file() {
  [[ -f "$1" && -f "$1.sha256" ]] ||
    die "backup $1 or its .sha256 file not found;" \
      "fix: pick a file from $BACKUP_DIR"
  (cd "$(dirname "$1")" &&
    sha256sum --check --quiet "$(basename "$1").sha256") ||
    die "checksum mismatch for $1: file damaged or modified"
}

# Sauvegarde : pg_dump au format « custom » (compressé), à chaud (permis
# par la documentation de SonarQube), écrit d'abord dans un fichier
# temporaire renommé seulement si tout a réussi ; puis empreinte,
# contrôle du contenu et rotation
backup() {
  local name
  name="sonarqube-$(date -u +%Y%m%dT%H%M%SZ).dump"
  mkdir -p "$BACKUP_DIR"
  log INFO "backing up $DB: $(count_rows "$DB")"
  if ! in_pod pg_dump -U "$DB_USER" -d "$DB" -Fc >"$BACKUP_DIR/$name.tmp"
  then
    rm -f "${BACKUP_DIR:?}/$name.tmp"
    die "pg_dump failed;" \
      "fix: check the pod (kubectl -n $NAMESPACE get pods)"
  fi
  mv "$BACKUP_DIR/$name.tmp" "$BACKUP_DIR/$name"
  (cd "$BACKUP_DIR" && sha256sum "$name" >"$name.sha256")
  # Le fichier doit être lisible par pg_restore (sauvegarde utilisable) ;
  # il est d'abord copié EN ENTIER dans le pod (/tmp), puis lu : par le
  # tube, pg_restore --list s'arrête au sommaire et kubectl attend sans fin
  # le reste du fichier (constaté le 12/11 avec 6,8 Mo)
  # shellcheck disable=SC2016 # $? est lu par le shell du pod
  in_pod_stdin sh -c 'cat >/tmp/check.dump &&
    pg_restore --list /tmp/check.dump >/dev/null; rc=$?
    rm -f /tmp/check.dump; exit "$rc"' <"$BACKUP_DIR/$name" ||
    die "backup $name is not readable by pg_restore"
  # Rotation : les noms contiennent la date, le tri donne l'ordre ; on
  # garde les KEEP plus récentes
  find "$BACKUP_DIR" -name "sonarqube-*.dump" | sort -r |
    tail -n +"$((KEEP + 1))" | while read -r old; do
      rm -f "$old" "$old.sha256"
      log INFO "old backup removed: $(basename "$old")"
    done
  log INFO "backup ready: $BACKUP_DIR/$name" \
    "($(du -h "$BACKUP_DIR/$name" | cut -f1))"
  LAST_BACKUP="$BACKUP_DIR/$name"
}

# Métrique pour la supervision : heure de la dernière sauvegarde réussie
# (format texte de Prometheus, lu par node_exporter) ; écrite puis
# renommée, jamais lue à moitié ; lisible par son groupe (node_exporter)
write_metric() {
  [[ -n "$BACKUP_METRICS_DIR" ]] || return 0
  local file="$BACKUP_METRICS_DIR/sonarqube_backup.prom"
  {
    echo "# HELP sonarqube_backup_last_success_timestamp_seconds" \
      "Time of the last successful SonarQube database backup."
    echo "# TYPE sonarqube_backup_last_success_timestamp_seconds gauge"
    echo "sonarqube_backup_last_success_timestamp_seconds $(date +%s)"
  } >"$file.tmp"
  chmod 640 "$file.tmp"
  mv "$file.tmp" "$file"
}

# Vérification : la dernière sauvegarde (ou celle donnée) est restaurée
# dans une base temporaire, comptée, puis supprimée ; la vraie base n'est
# pas touchée
verify() {
  local file="$1"
  if [[ -z "$file" ]]; then
    # Dossier absent : find échoue, ce n'est pas une erreur ici (|| true),
    # le message ci-dessous l'explique
    file="$(find "$BACKUP_DIR" -name "sonarqube-*.dump" 2>/dev/null |
      sort | tail -n 1 || true)"
    [[ -n "$file" ]] ||
      die "no backup found in $BACKUP_DIR;" \
        "fix: run scripts/backup-sonarqube.sh"
  fi
  check_file "$file"
  log INFO "restoring $(basename "$file") into a temporary database"
  # Message « n'existe pas » attendu la 1re fois : masqué
  in_pod dropdb -U "$DB_USER" --if-exists sonarqube_verify 2>/dev/null
  in_pod createdb -U "$DB_USER" sonarqube_verify
  in_pod_stdin pg_restore -U "$DB_USER" -d sonarqube_verify --no-owner \
    --exit-on-error <"$file"
  log INFO "backup restorable: $(count_rows sonarqube_verify)"
  in_pod dropdb -U "$DB_USER" sonarqube_verify
}

# Restauration : SonarQube doit être arrêté (il écrirait pendant la
# restauration) ; sauvegarde de sécurité, base restaurée en une seule
# transaction (tout ou rien), puis disque de l'index supprimé : la
# documentation de SonarQube demande de vider l'index, reconstruit au
# démarrage suivant
restore() {
  local file="$1" replicas
  check_file "$file"
  replicas="$(kubectl -n "$NAMESPACE" get "$APP" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  [[ "${replicas:-0}" == "0" ]] ||
    die "SonarQube is running;" \
      "fix: kubectl -n $NAMESPACE scale $APP --replicas=0"
  # La sauvegarde de sécurité ne doit pas faire supprimer par la rotation
  # le fichier qu'on restaure (s'il est le plus ancien des KEEP gardés) :
  # une de plus est gardée, le temps de cette restauration
  KEEP=$((KEEP + 1))
  log INFO "safety backup of the current state first"
  backup
  log INFO "restoring the whole database from $(basename "$file")"
  in_pod_stdin pg_restore -U "$DB_USER" -d "$DB" --clean --if-exists \
    --no-owner --single-transaction --exit-on-error <"$file" ||
    die "restore failed, database unchanged;" \
      "fix: the safety backup is $LAST_BACKUP"
  log INFO "database restored: $(count_rows "$DB")"
  kubectl -n "$NAMESPACE" delete pvc "$INDEX_PVC" --ignore-not-found \
    --timeout=120s >/dev/null
  log INFO "search index removed; next: scripts/deploy-sonarqube.sh" \
    "(restarts SonarQube, which rebuilds its index)"
}

# Point d'entrée : sans argument, « verify [FILE] » ou « restore FILE »
main() {
  require_cmd kubectl sha256sum
  case "${1:-}" in
    "")
      backup
      write_metric
      ;;
    verify)
      [[ $# -le 2 ]] || usage
      verify "${2:-}"
      ;;
    restore)
      [[ $# -eq 2 ]] || usage
      restore "$2"
      ;;
    *) usage ;;
  esac
}

main "$@"
