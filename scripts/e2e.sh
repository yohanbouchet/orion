#!/usr/bin/env bash
# Fichier  : scripts/e2e.sh
# Rôle     : tests de bout en bout : démarre MicroCRM complet et jetable
#            (base, back, front : e2e/compose.yaml), attend qu'il soit
#            prêt, fait jouer les parcours par un vrai navigateur
#            (Playwright), puis supprime tout, même après un échec
# Utilise  : scripts/lib/common.sh ; docker (avec compose), openssl ;
#            e2e/ (compose.yaml, playwright.config.ts, tests/)
# Utilisé par : job e2e de la CI (.github/workflows/ci.yml) ; l'opérateur
# Usage    : scripts/e2e.sh FRONT_IMAGE BACK_IMAGE
#            ex. scripts/e2e.sh orion-front:local orion-back:local
# Résultats : e2e/playwright-report/ (rapport HTML), e2e/test-results/
#             (traces, captures, vidéos des échecs, journaux du back et
#             du front)

# Arrêt à la première erreur, variable inconnue, erreur dans un tube
set -Eeuo pipefail

# Dossiers calculés depuis l'emplacement du script : lançable de partout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="e2e.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
E2E_DIR="$(cd "$SCRIPT_DIR/../e2e" && pwd)"

usage() {
  echo "Usage: $SCRIPT_NAME FRONT_IMAGE BACK_IMAGE" >&2
  exit 2
}

# docker compose sur le fichier des tests, nom de projet fixe
compose() {
  docker compose -f "$E2E_DIR/compose.yaml" "$@"
}

# Toujours : journaux du back et du front gardés pour comprendre un
# échec, puis tout supprimé (conteneurs, réseau, volumes)
cleanup() {
  mkdir -p "$E2E_DIR/test-results"
  compose logs --no-color back front \
    >"$E2E_DIR/test-results/stack.log" 2>&1 || true
  compose --profile tests down --volumes --remove-orphans >/dev/null 2>&1 ||
    true
}

main() {
  [[ $# -eq 2 ]] || usage
  require_cmd docker openssl

  # Images à tester ; mot de passe de la base tiré au hasard à chaque
  # lancement (jamais écrit dans le dépôt ni affiché) ; Playwright sous
  # le compte de l'utilisateur (rapports lisibles, aucun root)
  export FRONT_IMAGE="$1" BACK_IMAGE="$2"
  E2E_DB_PASSWORD="$(openssl rand -hex 16)"
  E2E_UID="$(id -u)"
  E2E_GID="$(id -g)"
  export E2E_DB_PASSWORD E2E_UID E2E_GID

  trap cleanup EXIT
  log INFO "starting the stack: $FRONT_IMAGE, $BACK_IMAGE"
  # --wait : rend la main quand base, back et front sont « healthy »
  compose up --detach --wait --wait-timeout 180 db back front ||
    die "the stack did not start;" \
      "fix: read e2e/test-results/stack.log"

  log INFO "running the browser tests"
  if ! compose --profile tests run --rm playwright; then
    die "end-to-end tests failed;" \
      "fix: open e2e/playwright-report/index.html"
  fi
  log INFO "end-to-end tests passed"
}

main "$@"
