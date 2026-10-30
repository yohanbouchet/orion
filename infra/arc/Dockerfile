# Fichier  : infra/arc/Dockerfile
# Rôle     : image durcie du runner local (ARC) : l'officielle, SANS sudo,
#            sans Docker, sans Node 20 (fin de support) ni npm. Ce runner ne
#            construit rien : il sert à l'analyse SonarQube et au déploiement.
#            dirmngr ajouté : l'action SonarQube vérifie la signature GPG de
#            l'analyseur qu'elle télécharge.
#            trivy : 181 failles (1 critique, 38 hautes) → 71 (0 critique,
#            0 haute) le 30/10/2026.
# Utilise  : image officielle ghcr.io/actions/actions-runner:2.338.2
# Utilisé par : infra/arc/values-orion-runners.yaml (pods des runners)

# Image officielle du runner, version précise, figée par son empreinte
FROM ghcr.io/actions/actions-runner:2.338.2@sha256:759a1d94a15b05941aba5196974ff43fe15b4cbba29b694b35cbc32a1166b232

# Les modifications du système exigent root (uniquement pendant la
# construction de l'image, jamais pendant les jobs)
USER 0

# Une seule couche : correctifs d'Ubuntu, puis retrait de tout ce qui donne
# des droits ou ne sert pas à ce runner
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
       dirmngr=2.4.4-2ubuntu17.6 \
    && SUDO_FORCE_REMOVE=yes apt-get purge -y sudo \
    && gpasswd -d runner sudo \
    && gpasswd -d runner docker \
    && gpasswd -d runner users \
    && rm -rf /var/lib/apt/lists/* /etc/sudoers.d/* \
    && rm /usr/bin/docker /usr/bin/dockerd /usr/bin/containerd \
       /usr/bin/containerd-shim-runc-v2 /usr/bin/ctr /usr/bin/runc \
       /usr/bin/docker-proxy \
    && rm -rf /usr/local/lib/docker \
       /home/runner/externals/node20 /home/runner/externals/node20_alpine \
       /home/runner/externals/node24/lib/node_modules \
       /home/runner/externals/node24/bin/npm \
       /home/runner/externals/node24/bin/npx \
       /home/runner/externals/node24/bin/corepack

# Les jobs tournent sous le compte « runner » (1001), sans aucun droit
# d'administration
USER 1001:1001
