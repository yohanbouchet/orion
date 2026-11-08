#!/usr/bin/env bash
# Fichier  : scripts/run-tests.sh
# Rôle     : lance les tests du front (Vitest) ou du back (JUnit) une seule
#            fois, puis vérifie que le rapport de couverture attendu par
#            SonarQube existe ; la même commande en local et dans la CI
# Utilise  : scripts/lib/common.sh ; node, npx (front) ; java,
#            gradlew (back) ; dépendances installées par install-deps.sh
# Utilisé par : jobs test-front et test-back de ci.yml ; ticket #56
# Usage    : scripts/run-tests.sh front|back

# Arrêt à la première erreur, variable inconnue, erreur dans un tube
set -Eeuo pipefail

# Dossiers calculés depuis l'emplacement du script : lançable de partout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_NAME="run-tests.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Rapports de couverture lus ensuite par le job sonarqube
FRONT_COVERAGE="front/coverage/microcrm/lcov.info"
BACK_COVERAGE="back/build/reports/jacoco/test/jacocoTestReport.xml"

# Mauvais usage : rappel de la syntaxe, code 2
usage() {
  echo "Usage: $SCRIPT_NAME front|back" >&2
  exit 2
}

# Un test peut réussir sans produire de rapport (configuration cassée) :
# SonarQube verrait alors 0 % de couverture ; on s'arrête ici, avec la
# cause probable
check_report() {
  [[ -s "$ROOT_DIR/$1" ]] ||
    die "coverage report $1 missing or empty;" \
      "fix: check the coverage settings (angular.json, build.gradle)"
  log INFO "coverage report ready: $1"
}

# Front : une seule exécution (pas de surveillance) ; Vitest lance les
# tests dans Node avec jsdom, un navigateur simulé : plus besoin de Chrome
run_front() {
  require_cmd node npx
  [[ -d "$ROOT_DIR/front/node_modules" ]] ||
    die "front dependencies not installed;" \
      "fix: run scripts/install-deps.sh front"
  log INFO "running front tests (Vitest)"
  (cd "$ROOT_DIR/front" && npx ng test --no-watch --no-progress)
  check_report "$FRONT_COVERAGE"
}

# Back : tests JUnit ; Gradle produit ensuite le rapport JaCoCo
run_back() {
  require_cmd java
  log INFO "running back tests (JUnit, JaCoCo)"
  (cd "$ROOT_DIR/back" && ./gradlew test --no-daemon)
  check_report "$BACK_COVERAGE"
}

# Point d'entrée : un seul paramètre, front ou back
main() {
  [[ $# -eq 1 ]] || usage
  case "$1" in
    front) run_front ;;
    back) run_back ;;
    *) usage ;;
  esac
  log INFO "$1 tests passed"
}

main "$@"
