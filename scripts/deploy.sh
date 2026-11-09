#!/usr/bin/env bash
# Fichier  : scripts/deploy.sh
# Rôle     : déploie MicroCRM (chart Helm) dans un environnement, vérifie
#            l'application par un test de fumée et revient à la version
#            précédente s'il échoue ; « rollback » revient en arrière à la
#            demande ; la même commande en local et dans la CI
# Utilise  : scripts/lib/common.sh ; helm, kubectl, openssl ;
#            infra/helm/microcrm ; namespace créé par infra/terraform
#            (OpenTofu)
# Utilisé par : l'opérateur ; job de déploiement de la CI ; ticket #56
# Usage    : scripts/deploy.sh dev|staging|prod [TAG]
#            scripts/deploy.sh rollback dev|staging|prod [REVISION]
# Paramètres : TAG = image publiée par la CI (vX.Y.Z ou sha-xxxxxxx) ;
#              sans TAG, version du chart (appVersion) ; SMOKE_DELAY =
#              secondes entre deux essais du test de fumée (défaut 5)

# Arrêt à la première erreur, variable inconnue, erreur dans un tube
set -Eeuo pipefail

# Dossiers calculés depuis l'emplacement du script : lançable de partout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_NAME="deploy.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CHART_DIR="$ROOT_DIR/infra/helm/microcrm"
RELEASE="microcrm"
# Secrets des mots de passe de la base, lus par le chart : superutilisateur
# (postgres.existingSecret) et compte limité de l'appli (appExistingSecret)
DB_SECRET="microcrm-db"
DB_APP_SECRET="microcrm-db-app"
# Attente maximale des pods : Spring Boot met environ une minute à démarrer
TIMEOUT="6m"
# Chart emballé (voir package_chart) et son dossier temporaire, effacé
# à la sortie du script, même en cas d'erreur
PACKAGE_DIR=""
CHART_ARCHIVE=""
trap '[[ -z "$PACKAGE_DIR" ]] || rm -rf "${PACKAGE_DIR:?}"' EXIT

# Mauvais usage : rappel de la syntaxe, code 2
usage() {
  echo "Usage: $SCRIPT_NAME dev|staging|prod [TAG]" >&2
  echo "       $SCRIPT_NAME rollback dev|staging|prod [REVISION]" >&2
  exit 2
}

# Seuls les trois environnements prévus ; leur nom est aussi le namespace
check_env() {
  case "$1" in
    dev | staging | prod) ;;
    *) usage ;;
  esac
}

# Le namespace est créé par OpenTofu (droits sur tout le cluster) ; ici
# on vérifie qu'il existe, qu'on a le droit de le lire, et qu'il impose
# le niveau de sécurité « restricted »
check_namespace() {
  local ns="$1" level
  level="$(kubectl get namespace "$ns" -o \
    jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' \
    2>/dev/null)" ||
    die "namespace $ns not found or not allowed;" \
      "fix: create it with OpenTofu (infra/terraform/README.md)" \
      "or check the credentials (kubectl config current-context)"
  [[ "$level" == "restricted" ]] ||
    die "namespace $ns does not enforce Pod Security \"restricted\";" \
      "fix: run tofu apply in infra/terraform (it sets" \
      "pod-security.kubernetes.io/enforce=restricted)"
}

# Mot de passe d'un compte de la base : créé une seule fois, jamais
# remplacé (la base existante le garde) ; la valeur aléatoire passe par un
# tube, jamais par la ligne de commande (visible des autres programmes avec ps)
ensure_db_secret() {
  local ns="$1" secret="$2"
  if kubectl -n "$ns" get secret "$secret" >/dev/null 2>&1; then
    log INFO "database secret $secret already exists: kept"
    return
  fi
  openssl rand -hex 32 | tr -d '\n' |
    kubectl -n "$ns" create secret generic "$secret" \
      --from-file=password=/dev/stdin >/dev/null
  log INFO "database secret $secret created (random value, never shown)"
}

# Numéro de la version installée (1re colonne de la dernière ligne de
# l'historique Helm), 0 si rien n'est installé
current_revision() {
  helm history "$RELEASE" -n "$1" --max 1 2>/dev/null |
    awk 'NR == 2 { print $1 }' | grep . || echo 0
}

# Test de fumée : depuis le pod du front, appel de /api/persons, qui
# traverse tout le chemin front → back → base ; 3 essais ; 127.0.0.1 et
# non localhost, qui désigne d'abord l'IPv6 (::1) où nginx n'écoute pas
smoke_test() {
  local ns="$1" attempt
  for attempt in 1 2 3; do
    if kubectl -n "$ns" exec "deploy/$RELEASE-front" -- \
      wget -q -T 10 -O /dev/null http://127.0.0.1:8080/api/persons; then
      log INFO "smoke test passed: /api/persons answers"
      return 0
    fi
    log WARN "smoke test attempt $attempt failed"
    sleep "${SMOKE_DELAY:-5}"
  done
  return 1
}

# Chart emballé avec la version déployée (v1.8.2 → 1.8.2, sha-abc1234
# tel quel) : « helm history » l'affiche dans APP VERSION, et les objets
# portent l'étiquette app.kubernetes.io/version correspondante ; seul
# helm package sait fixer ce numéro (pas helm upgrade). Résultat dans
# CHART_ARCHIVE (appel direct, pas « $(…) » : un sous-shell perdrait
# PACKAGE_DIR, donc le ménage, et un arrêt sur erreur)
package_chart() {
  local tag="$1"
  PACKAGE_DIR="$(mktemp -d)"
  helm package "$CHART_DIR" --app-version "${tag#v}" \
    --destination "$PACKAGE_DIR" >/dev/null ||
    die "packaging of the chart failed;" \
      "fix: run helm package $CHART_DIR to see the error"
  local archives=("$PACKAGE_DIR"/*.tgz)
  CHART_ARCHIVE="${archives[0]}"
}

# Déploiement : contrôles, installation ou mise à jour, test de fumée ;
# s'il échoue, retour à la version précédente
deploy() {
  local env="$1" tag="$2"
  check_env "$env"
  local args=(-f "$CHART_DIR/values-$env.yaml")
  # Étiquette contrôlée : seulement une image publiée par la CI (aucune
  # valeur inattendue transmise à Helm)
  if [[ -n "$tag" ]]; then
    [[ "$tag" =~ ^(v[0-9]+\.[0-9]+\.[0-9]+|sha-[0-9a-f]{7})$ ]] ||
      die_with 2 "invalid image tag: $tag;" \
        "fix: use vX.Y.Z or sha-xxxxxxx (images published by the CI)"
    args+=(--set "front.image.tag=$tag" --set "back.image.tag=$tag")
  fi
  require_cmd helm kubectl openssl
  log INFO "cluster: $(kubectl config current-context 2>/dev/null ||
    echo in-cluster)"
  check_namespace "$env"
  ensure_db_secret "$env" "$DB_SECRET"
  ensure_db_secret "$env" "$DB_APP_SECRET"
  log INFO "checking the chart (helm lint)"
  helm lint --quiet "$CHART_DIR" "${args[@]}"
  # Sans étiquette : le chart tel quel (appVersion de Chart.yaml)
  local chart="$CHART_DIR"
  if [[ -n "$tag" ]]; then
    package_chart "$tag"
    chart="$CHART_ARCHIVE"
  fi
  # --rollback-on-failure : si les pods ne sont pas prêts à temps, Helm
  # remet lui-même la version précédente (Helm 4, ancien --atomic) ;
  # --description : l'image déployée, aussi dans « helm history »
  log INFO "deploying $RELEASE to $env (image: ${tag:-chart default})"
  helm upgrade --install "$RELEASE" "$chart" -n "$env" "${args[@]}" \
    --description "image ${tag:-chart default}" \
    --rollback-on-failure --wait --timeout "$TIMEOUT" ||
    die "deployment to $env failed: previous version kept by Helm;" \
      "fix: look for the cause (kubectl -n $env get pods; image tag?)"
  if ! smoke_test "$env"; then
    if [[ "$(current_revision "$env")" -gt 1 ]]; then
      log ERROR "smoke test failed: rolling back to the previous version"
      helm rollback "$RELEASE" -n "$env" --wait --timeout "$TIMEOUT"
    fi
    die "deployment to $env failed the smoke test;" \
      "fix: read the logs (kubectl -n $env logs deploy/$RELEASE-back)"
  fi
  log INFO "$env deployed: revision $(current_revision "$env")"
}

# Retour arrière à la demande : version précédente, ou numéro choisi dans
# « helm history microcrm -n ENV » ; puis test de fumée
rollback() {
  local env="$1" revision="$2"
  check_env "$env"
  if [[ -n "$revision" && ! "$revision" =~ ^[0-9]+$ ]]; then
    die_with 2 "invalid revision: $revision;" \
      "fix: pick a number from: helm history $RELEASE -n $env"
  fi
  require_cmd helm kubectl
  log INFO "rolling back $RELEASE in $env to revision ${revision:-previous}"
  helm rollback "$RELEASE" ${revision:+"$revision"} -n "$env" \
    --wait --timeout "$TIMEOUT"
  smoke_test "$env" ||
    die "smoke test failed after the rollback;" \
      "fix: read the logs (kubectl -n $env logs deploy/$RELEASE-back)"
  log INFO "$env restored: revision $(current_revision "$env")"
}

# Point d'entrée : « rollback ENV [REVISION] » ou « ENV [TAG] »
main() {
  [[ $# -ge 1 ]] || usage
  if [[ "$1" == "rollback" ]]; then
    [[ $# -eq 2 || $# -eq 3 ]] || usage
    rollback "$2" "${3:-}"
  else
    [[ $# -le 2 ]] || usage
    deploy "$1" "${2:-}"
  fi
}

main "$@"
