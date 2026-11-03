# syntax=docker/dockerfile:1
# Fichier  : infra/zap/Dockerfile
# Rôle     : image du test d'intrusion : ZAP officiel, corrigé, avec les
#            règles « bêta » (passives et actives) ajoutées À LA
#            CONSTRUCTION et vérifiées par empreinte ; au scan, ZAP ne
#            télécharge rien (-silent). Trivy (03/11/2026, failles hautes
#            et critiques) : 456 dont 47 corrigeables dans l'officielle,
#            421 dont 12 ici ; le reste vient du système de base de ZAP,
#            sans correctif : risque accepté (pod éphémère, isolé, non root)
# Utilise  : image officielle ghcr.io/zaproxy/zaproxy:2.17.0 ; modules
#            pscanrulesBeta v50 et ascanrulesBeta v67 (dépôt zap-extensions)
# Utilisé par : scripts/zap-scan.sh (Job Kubernetes) ; image construite
#               puis chargée dans Minikube (README racine)

# ZAP 2.17.0 (dernière version, 15/12/2025) ; l'empreinte (sha256) garantit
# d'obtenir exactement l'image vérifiée, même si l'étiquette est déplacée
FROM ghcr.io/zaproxy/zaproxy:2.17.0@sha256:030d3df57735dacbb83464854758e674dd9ad01d79d12a129a8e58b1fd384238

# Correctifs de sécurité du système (Debian) parus depuis la sortie de
# l'image ; il faut root (numéro 0) pour installer
USER 0
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Règles bêta, à la version et à l'empreinte publiées par ZAP
# (ZapVersions-2.17.xml) : fichier refusé si l'empreinte diffère ;
# rangées avec les modules de l'image
ADD --chown=1000:1000 \
    --checksum=sha256:a979f7cd5d8be10e0338b417e006ec1e2f6ec79101010d570ddb5199892e921b \
    https://github.com/zaproxy/zap-extensions/releases/download/pscanrulesBeta-v50/pscanrulesBeta-beta-50.zap \
    /zap/plugin/
ADD --chown=1000:1000 \
    --checksum=sha256:81e84d592b1f7ad803470bcc8d8b659d4f7e21370546a482b606207e57a7db69 \
    https://github.com/zaproxy/zap-extensions/releases/download/ascanrulesBeta-v67/ascanrulesBeta-beta-67.zap \
    /zap/plugin/

# Retour au compte « zap » de l'image (numéro 1000) : scan sans root
USER 1000:1000
