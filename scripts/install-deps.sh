#!/usr/bin/env bash
# Fichier  : scripts/install-deps.sh
# Rôle     : installe les dépendances du front (npm) ou vérifie celles du
#            back (Gradle), aux versions exactes des fichiers de
#            verrouillage ; la même commande en local et dans la CI
# Utilise  : scripts/lib/common.sh ; node, npm (front) ; java, gradlew (back)
# Utilisé par : jobs test-front et test-back de ci.yml ; ticket #56
# Usage    : scripts/install-deps.sh front|back

# Arrêt à la première erreur (-e), variable inconnue (-u), erreur dans un
# tube (pipefail) ; -E : les fonctions héritent de ce comportement
set -Eeuo pipefail

# Dossiers calculés depuis l'emplacement du script : lançable de partout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_NAME="install-deps.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Mauvais usage : rappel de la syntaxe, code 2 (convention des commandes)
usage() {
  echo "Usage: $SCRIPT_NAME front|back" >&2
  exit 2
}

# Front : npm ci installe exactement package-lock.json ; --ignore-scripts
# bloque les scripts d'installation des paquets (attaque de la chaîne
# d'approvisionnement) ; audit fait par Trivy dans la CI
install_front() {
  require_cmd node npm
  [[ -f "$ROOT_DIR/front/package-lock.json" ]] ||
    die "front/package-lock.json not found;" \
      "fix: run 'npm install' in front/ and commit package-lock.json"
  log INFO "installing front dependencies from package-lock.json"
  (cd "$ROOT_DIR/front" && npm ci --ignore-scripts --no-audit --no-fund)
}

# Back : Gradle résout les dépendances des tests ; une version différente
# de gradle.lockfile apparaît « FAILED » sans faire échouer la commande,
# d'où la vérification par le script
install_back() {
  require_cmd java
  [[ -f "$ROOT_DIR/back/gradle.lockfile" ]] ||
    die "back/gradle.lockfile not found;" \
      "fix: run './gradlew dependencies --write-locks' in back/ and commit it"
  log INFO "resolving back dependencies against gradle.lockfile"
  local report
  report="$(cd "$ROOT_DIR/back" && ./gradlew --no-daemon -q dependencies \
    --configuration testRuntimeClasspath)"
  if grep -q ' FAILED' <<<"$report"; then
    grep ' FAILED' <<<"$report" >&2
    die "back dependencies do not match gradle.lockfile (FAILED above);" \
      "fix: if intended, run './gradlew dependencies --write-locks' in back/"
  fi
}

# Point d'entrée : un seul paramètre, front ou back
main() {
  [[ $# -eq 1 ]] || usage
  case "$1" in
    front) install_front ;;
    back) install_back ;;
    *) usage ;;
  esac
  log INFO "$1 dependencies ready"
}

main "$@"
