# Fichier  : infra/postgres/Dockerfile
# Rôle     : image PostgreSQL durcie, partagée par les bases du projet :
#            l'officielle, corrigée, SANS l'outil « gosu », lancée sans root.
#            gosu ne sert qu'au démarrage (passer de root à postgres) ;
#            trivy y trouve 61 failles (1 critique, 25 hautes) le 28/10/2026.
# Utilise  : image officielle postgres:18.6-alpine3.24 (Docker Hub)
# Utilisé par : infra/sonarqube/postgres.yaml (base de SonarQube dans le
#               cluster) ; plus tard la base de MicroCRM (phase 5)

# Image officielle, version précise : PostgreSQL 18.6 sur Alpine 3.24
# (PostgreSQL 18 supporté jusqu'au 14/11/2030, Alpine 3.24 jusqu'au
# 01/06/2028). L'empreinte (sha256) garantit d'obtenir exactement
# l'image vérifiée, même si l'étiquette est déplacée plus tard.
FROM postgres:18.6-alpine3.24@sha256:10a5c69a83035ab5239f5620d708520e8b28f5aa1f2b20143e6024532edadfb5

# Sécurité : applique les correctifs Alpine publiés depuis la sortie de
# l'image (même version d'Alpine, correctifs seulement : brotli-libs et
# libcurl le 28/10/2026), puis supprime gosu, inutile sans root.
RUN apk upgrade --no-cache \
    && rm /usr/local/bin/gosu

# Lance PostgreSQL sous le compte « postgres » de l'image (numéro 70) :
# le script de démarrage, lancé sans root, n'appelle jamais gosu.
USER 70:70
