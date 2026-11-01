# shellcheck shell=bash
# Fichier  : scripts/lib/common.sh
# Rôle     : fonctions partagées par les scripts (journal, arrêt sur erreur,
#            vérification des outils) ; chargé avec « source », jamais lancé
# Utilise  : date (coreutils)
# Utilisé par : scripts/*.sh ; tests : scripts/tests/common_test.sh ; #56

# Garde : ce fichier se charge (source), il ne s'exécute pas seul
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "common.sh must be sourced, not executed" >&2
  exit 1
fi

# Journal : date UTC (ISO 8601), niveau, script, message ; sur stderr pour
# ne pas mélanger le journal et les résultats (stdout)
log() {
  local level="$1"
  shift
  printf '%s %-5s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" \
    "${SCRIPT_NAME:-$(basename "$0")}" "$*" >&2
}

# Arrêt : journal ERROR puis sortie avec un code d'erreur (1 par défaut)
die() {
  local message="$1"
  local code="${2:-1}"
  log ERROR "$message"
  exit "$code"
}

# Vérifie que chaque outil demandé est installé, sinon arrêt (code 127 :
# « commande introuvable », comme le shell)
require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      die "missing required command: $cmd" 127
    fi
  done
}
