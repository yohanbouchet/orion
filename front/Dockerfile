# Fichier  : front/Dockerfile
# Rôle     : image du front MicroCRM (Angular) : construite avec Node dans
#            une première étape, servie par nginx sans root. trivy : 0 faille
#            le 31/10/2026.
# Utilise  : le dossier front/ (code, package-lock.json, nginx.conf) ;
#            images officielles node 24 et nginx-unprivileged 1.30 (Alpine 3.24)
# Utilisé par : .github/workflows/ci.yml (job des images) ; plus tard le
#               chart Helm (phase 5)

# --- Étape 1 : construction (image jetée à la fin) ---
# Node 24 LTS, version et empreinte figées
FROM node:26.12.1-alpine3.24@sha256:40cd011b55415bc894e45b02fdd5a5dfde056921b7d23a64c74f80497af48797 AS build
WORKDIR /src
# Liste des dépendances d'abord : couche réutilisée tant qu'elle ne change pas
COPY package.json package-lock.json ./
# Versions exactes de package-lock.json, sans rapport ni message de don
RUN npm ci --no-audit --no-fund
# Puis le code, et construction des fichiers optimisés (dist/microcrm/browser)
COPY . .
RUN npx ng build --configuration production

# --- Étape 2 : service (l'image livrée) ---
# nginx officiel, variante sans root (compte nginx, numéro 101)
FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03
# Correctifs Alpine : root le temps de cette seule commande
USER 0
RUN apk upgrade --no-cache
USER 101
# Notre configuration remplace celle par défaut
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Seuls les fichiers construits viennent de l'étape 1
COPY --from=build /src/dist/microcrm/browser /usr/share/nginx/html
EXPOSE 8080
# Sonde de santé : nginx répond-il ?
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/"]
