#!/usr/bin/env bash
# Fichier  : scripts/deploy-sonarqube.sh
# Rôle     : déploie SonarQube et sa base dans le cluster Minikube et
#            vérifie automatiquement que l'image lancée est bien l'image
#            attendue (empreinte), sinon s'arrête en erreur.
# Utilise  : docker, minikube, kubectl, helm ; infra/sonarqube/*.yaml
# Utilisé par : l'opérateur (lancement manuel), plus tard la CI
# Paramètres : MINIKUBE_PROFILE (défaut : orion) ; aucun secret en argument

# Arrêt à la première erreur (-e), sur une variable inconnue (-u) et si
# une commande échoue au milieu d'un enchaînement « | » (pipefail)
set -euo pipefail

# Profil Minikube, modifiable : MINIKUBE_PROFILE=autre ./deploy-sonarqube.sh
readonly MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-orion}"
readonly NAMESPACE="sonarqube"
readonly CHART_VERSION="2026.5.1003"
readonly IMAGE_TAG="sonarqube:26.10.0.133078-community"
# Empreinte de l'index (toutes plateformes) : sert au téléchargement
readonly IMAGE_INDEX_DIGEST="sha256:aa0d41212704d1ed35f7ae3b49886b39f639590baf8020cdb191c2a2eb8f9eae"
# Empreinte du contenu amd64, celle que Kubernetes affiche ; lue avec
# docker buildx imagetools inspect --raw sonarqube@sha256:65b38a9c…
readonly IMAGE_CONFIG_DIGEST="sha256:34fa1c406df2a8fbf7aa76e5ccb5a678c9c8413c1e637bdaf08a279e2754ae0e"
# Dossier des manifestes, trouvé depuis l'emplacement du script
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra/sonarqube" && pwd)"
readonly INFRA_DIR

# Message horodaté ; en cas d'erreur, message sur la sortie d'erreur et arrêt
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# Crée le secret avec une valeur aléatoire s'il n'existe pas encore ;
# s'il existe, le garde (sinon la base ne reconnaîtrait plus le mot de passe)
ensure_secret() {
  local name="$1" key="$2"
  if kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    log "Secret ${name} already exists, kept"
  else
    kubectl -n "$NAMESPACE" create secret generic "$name" \
      --from-literal="${key}=$(openssl rand -hex 32)" >/dev/null
    log "Secret ${name} created"
  fi
}

# Vérifie que chaque outil nécessaire est installé
for tool in docker minikube kubectl helm openssl; do
  command -v "$tool" >/dev/null || fail "missing tool: ${tool}"
done

log "1/5 Namespace, secrets and database"
kubectl apply -f "${INFRA_DIR}/namespace.yaml"
# Pare-feu entre pods, appliqué avant de créer les pods
kubectl apply -f "${INFRA_DIR}/network-policy.yaml"
ensure_secret sonarqube-db password
ensure_secret sonarqube-monitoring passcode
kubectl apply -f "${INFRA_DIR}/postgres.yaml"
# Attend que la base soit prête avant de lancer SonarQube
kubectl -n "$NAMESPACE" rollout status statefulset/sonarqube-db --timeout=180s

log "2/5 Image pulled by digest, then loaded into Minikube"
# Téléchargement PAR EMPREINTE : Docker refuse un contenu différent
docker pull --quiet "sonarqube@${IMAGE_INDEX_DIGEST}"
# Étiquette locale attendue par le chart, posée sur l'image vérifiée
docker tag "sonarqube@${IMAGE_INDEX_DIGEST}" "$IMAGE_TAG"
minikube -p "$MINIKUBE_PROFILE" image load "$IMAGE_TAG"

log "3/5 Helm chart ${CHART_VERSION}"
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube \
  --force-update >/dev/null
# Installe ou met à jour, puis attend que SonarQube soit prêt (10 min max)
helm upgrade --install sonarqube sonarqube/sonarqube \
  --version "$CHART_VERSION" --namespace "$NAMESPACE" \
  --values "${INFRA_DIR}/values.yaml" --wait --timeout 10m

log "4/5 Image check"
# Empreinte de l'image réellement lancée par Kubernetes
running="$(kubectl -n "$NAMESPACE" get pod sonarqube-sonarqube-0 \
  -o jsonpath='{.status.containerStatuses[0].imageID}')"
[[ "$running" == *"$IMAGE_CONFIG_DIGEST" ]] \
  || fail "unexpected image: ${running} (expected ${IMAGE_CONFIG_DIGEST})"

log "5/5 Done: SonarQube ready, image verified (${IMAGE_CONFIG_DIGEST})"
