#!/usr/bin/env bash
# Fichier  : scripts/backup.sh
# Rôle     : sauvegarde la base PostgreSQL de MicroCRM d'un environnement
#            (pg_dump), vérifie qu'une sauvegarde se restaure vraiment
#            (base temporaire), restaure toute la base ou seulement les
#            lignes disparues d'une table ; une sauvegarde « de sécurité »
#            précède toujours une restauration
# Utilise  : scripts/lib/common.sh ; kubectl, sha256sum ; outils
#            PostgreSQL du pod de la base (pg_dump, pg_restore, psql)
# Utilisé par : l'opérateur ; tâche planifiée quotidienne (Ansible, à
#               venir) ; ticket #56
# Usage    : scripts/backup.sh dev|staging|prod
#            scripts/backup.sh verify dev|staging|prod [FILE]
#            scripts/backup.sh restore dev|staging|prod FILE [--table NAME]
# Paramètres : BACKUP_DIR = dossier des sauvegardes, hors du dépôt et du
#              cluster (défaut ~/backups/microcrm) ; KEEP = nombre de
#              sauvegardes gardées par environnement (défaut 7)

# Arrêt à la première erreur, variable inconnue, erreur dans un tube
set -Eeuo pipefail
# Fichiers créés lisibles par leur seul propriétaire : une sauvegarde
# contient des données personnelles
umask 077

# Dossiers calculés depuis l'emplacement du script : lançable de partout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="backup.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Pod, base et compte définis par le chart (values.yaml, postgres.*)
POD="microcrm-postgres-0"
DB="microcrm"
DB_USER="microcrm"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/microcrm}"
KEEP="${KEEP:-7}"
# Chemin de la dernière sauvegarde faite (cité si une restauration échoue)
LAST_BACKUP=""

# Mauvais usage : rappel de la syntaxe, code 2
usage() {
  echo "Usage: $SCRIPT_NAME dev|staging|prod" >&2
  echo "       $SCRIPT_NAME verify dev|staging|prod [FILE]" >&2
  echo "       $SCRIPT_NAME restore dev|staging|prod FILE [--table NAME]" >&2
  exit 2
}

# Seuls les trois environnements prévus ; leur nom est aussi le namespace
check_env() {
  case "$1" in
    dev | staging | prod) ;;
    *) usage ;;
  esac
}

# Commande lancée dans le pod de la base ; -i transmet aussi l'entrée
# standard (un fichier de sauvegarde envoyé au pod)
in_pod() {
  kubectl -n "$ENV" exec "$POD" -- "$@"
}
in_pod_stdin() {
  kubectl -n "$ENV" exec -i "$POD" -- "$@"
}

# Nombre de lignes des tables principales d'une base, pour le journal
count_rows() {
  in_pod psql -U "$DB_USER" -d "$1" -tAc "select
    (select count(*) from person) || ' persons, ' ||
    (select count(*) from organization) || ' organizations'"
}

# Empreinte du fichier comparée à celle notée à la sauvegarde : un
# fichier abîmé ou modifié n'est jamais restauré
check_file() {
  [[ -f "$1" && -f "$1.sha256" ]] ||
    die "backup $1 or its .sha256 file not found;" \
      "fix: pick a file from $BACKUP_DIR/$ENV"
  (cd "$(dirname "$1")" &&
    sha256sum --check --quiet "$(basename "$1").sha256") ||
    die "checksum mismatch for $1: file damaged or modified"
}

# Sauvegarde : pg_dump au format « custom » (compressé, restauration
# d'une seule table possible) écrit d'abord dans un fichier temporaire,
# renommé seulement si tout a réussi ; puis empreinte, contrôle du
# contenu et rotation
backup() {
  local dir="$BACKUP_DIR/$ENV" name
  name="microcrm-$ENV-$(date -u +%Y%m%dT%H%M%SZ).dump"
  mkdir -p "$dir"
  log INFO "backing up $DB ($ENV): $(count_rows "$DB")"
  if ! in_pod pg_dump -U "$DB_USER" -d "$DB" -Fc >"$dir/$name.tmp"; then
    rm -f "$dir/$name.tmp"
    die "pg_dump failed;" "fix: check the pod (kubectl -n $ENV get pods)"
  fi
  mv "$dir/$name.tmp" "$dir/$name"
  (cd "$dir" && sha256sum "$name" >"$name.sha256")
  # Le fichier doit être lisible par pg_restore (sauvegarde utilisable)
  in_pod_stdin pg_restore --list <"$dir/$name" >/dev/null ||
    die "backup $name is not readable by pg_restore"
  # Rotation : les noms contiennent la date, le tri donne l'ordre ; on
  # garde les KEEP plus récentes
  find "$dir" -name "microcrm-$ENV-*.dump" | sort -r |
    tail -n +"$((KEEP + 1))" | while read -r old; do
      rm -f "$old" "$old.sha256"
      log INFO "old backup removed: $(basename "$old")"
    done
  log INFO "backup ready: $dir/$name ($(du -h "$dir/$name" | cut -f1))"
  LAST_BACKUP="$dir/$name"
}

# Restaure le fichier dans une base annexe vide (la vraie base n'est pas
# touchée)
restore_into() {
  local file="$1" target="$2"
  # Message « n'existe pas » attendu la 1re fois : masqué
  in_pod dropdb -U "$DB_USER" --if-exists "$target" 2>/dev/null
  in_pod createdb -U "$DB_USER" "$target"
  in_pod_stdin pg_restore -U "$DB_USER" -d "$target" --no-owner \
    --exit-on-error <"$file"
}

# Vérification : la dernière sauvegarde (ou celle donnée) est restaurée
# dans une base temporaire, comptée, puis supprimée ; « une sauvegarde
# jamais restaurée n'existe pas »
verify() {
  local file="$1"
  if [[ -z "$file" ]]; then
    # Dossier absent : find échoue, ce n'est pas une erreur ici (|| true),
    # le message ci-dessous l'explique
    file="$(find "$BACKUP_DIR/$ENV" -name "microcrm-$ENV-*.dump" \
      2>/dev/null | sort | tail -n 1 || true)"
    [[ -n "$file" ]] ||
      die "no backup found in $BACKUP_DIR/$ENV;" \
        "fix: run scripts/backup.sh $ENV"
  fi
  check_file "$file"
  log INFO "restoring $(basename "$file") into a temporary database"
  restore_into "$file" microcrm_verify
  log INFO "backup restorable: $(count_rows microcrm_verify)"
  in_pod dropdb -U "$DB_USER" microcrm_verify
}

# Restauration complète : en une seule transaction (tout ou rien), après
# une sauvegarde de sécurité de l'état actuel
restore_all() {
  local file="$1"
  log INFO "restoring the whole database from $(basename "$file")"
  in_pod_stdin pg_restore -U "$DB_USER" -d "$DB" --clean --if-exists \
    --no-owner --single-transaction --exit-on-error <"$file" ||
    die "restore failed, database unchanged;" \
      "fix: the safety backup is $LAST_BACKUP"
}

# Restauration d'une table : sur place, impossible sans casser les liens
# (clés étrangères) ; on restaure dans une base annexe, puis on recopie
# seulement les lignes absentes (ON CONFLICT DO NOTHING) : les lignes
# existantes ne sont pas touchées
restore_table() {
  local file="$1" table="$2"
  log INFO "restoring missing rows of table $table from $(basename "$file")"
  restore_into "$file" microcrm_restore
  in_pod pg_dump -U "$DB_USER" -d microcrm_restore --data-only \
    --table "$table" --inserts --on-conflict-do-nothing |
    in_pod_stdin psql -U "$DB_USER" -d "$DB" -v ON_ERROR_STOP=1 \
      --single-transaction --quiet >/dev/null ||
    die "restore of table $table failed, database unchanged;" \
      "fix: the safety backup is $LAST_BACKUP"
  in_pod dropdb -U "$DB_USER" microcrm_restore
}

# Vrai si la table existe et a une clé primaire ou unique : sans clé,
# « ON CONFLICT DO NOTHING » ne voit aucun doublon et en ajouterait
has_key() {
  [[ "$(in_pod psql -U "$DB_USER" -d "$DB" -tAc "select count(*)
    from pg_index where indrelid = to_regclass('public.$1')
    and (indisprimary or indisunique)")" -gt 0 ]]
}

# Restauration : fichier contrôlé, sauvegarde de sécurité, puis base
# entière ou une seule table
restore() {
  local file="$1" table="$2"
  # Nom de table contrôlé (lettres minuscules et _) avant toute action
  if [[ -n "$table" && ! "$table" =~ ^[a-z_]+$ ]]; then
    die_with 2 "invalid table name: $table"
  fi
  if [[ -n "$table" ]] && ! has_key "$table"; then
    die "table $table not found or without primary key;" \
      "fix: restore the whole database (without --table)"
  fi
  check_file "$file"
  log INFO "safety backup of the current state first"
  backup
  if [[ -n "$table" ]]; then
    restore_table "$file" "$table"
  else
    restore_all "$file"
  fi
  log INFO "$ENV restored: $(count_rows "$DB")"
}

# Point d'entrée : « ENV », « verify ENV [FILE] » ou
# « restore ENV FILE [--table NAME] »
main() {
  [[ $# -ge 1 ]] || usage
  local action="backup"
  if [[ "$1" == "verify" || "$1" == "restore" ]]; then
    action="$1"
    shift
  fi
  [[ $# -ge 1 ]] || usage
  ENV="$1"
  check_env "$ENV"
  require_cmd kubectl sha256sum
  case "$action" in
    backup)
      [[ $# -eq 1 ]] || usage
      backup
      ;;
    verify)
      [[ $# -le 2 ]] || usage
      verify "${2:-}"
      ;;
    restore)
      if [[ $# -eq 2 ]]; then
        restore "$2" ""
      elif [[ $# -eq 4 && "$3" == "--table" ]]; then
        restore "$2" "$4"
      else
        usage
      fi
      ;;
  esac
}

main "$@"
