<p align="center">
   <img src="./front/src/favicon.png" width="128px" alt="" />
</p>

# MicroCRM : chaîne CI/CD d'Orion

[![CI](https://github.com/yohanbouchet/orion/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/yohanbouchet/orion/actions/workflows/ci.yml)

MicroCRM est une petite application de gestion de la relation client
(CRM) : création, modification et consultation de **personnes** liées à
des **organisations**. Front Angular, API Spring Boot, base PostgreSQL.

Ce dépôt met en place sa **chaîne d'intégration et de déploiement
continus** (CI/CD) pour les équipes Dev et Ops d'Orion : tests, analyse
de qualité et de sécurité, images Docker durcies, versions automatiques,
déploiement sur Kubernetes avec Helm. Projet « Gérez une démarche
DevOps » (OpenClassrooms, option B), à partir de
[l'application d'origine](https://github.com/OpenClassrooms-Student-Center/G-rez-le-cycle-de-vie-de-d-veloppement-logiciel).

![Page d'accueil](./misc/screenshots/screenshot_1.png)

## Sommaire

- [État d'avancement](#état-davancement)
- [Architecture](#architecture)
- [Contenu du dépôt](#contenu-du-dépôt)
- [Pipeline CI](#pipeline-ci)
- [Versions et publication](#versions-et-publication)
- [Lancer l'application sur un poste](#lancer-lapplication-sur-un-poste)
- [Images Docker](#images-docker)
- [Déployer sur Kubernetes](#déployer-sur-kubernetes)
- [Installer la chaîne sur le poste Ops](#installer-la-chaîne-sur-le-poste-ops)
- [Sécurité](#sécurité)
- [Contribuer](#contribuer)
- [Documentation](#documentation)
- [Versions des outils](#versions-des-outils)

## État d'avancement

Au 02/11/2026 :

| Étape | État |
|---|---|
| Audit, veille et recommandations ; normalisation et plan CI | ✅ [`docs/`](docs/) |
| Pipeline CI : tests, couverture, SonarQube, scans de sécurité, images | ✅ |
| Versions automatiques (semantic-release) et publication des images | ✅ |
| Scripts : dépendances, tests, notification, avec leurs tests | ✅ [`scripts/`](scripts/README.md) |
| Chart Helm de l'application (testé dans `dev`) | ✅ [`infra/helm/microcrm/`](infra/helm/microcrm/README.md) |
| Script de déploiement avec test de fumée et retour arrière | ✅ [`scripts/deploy.sh`](scripts/README.md#deploysh) |
| Job de déploiement, environnements `staging` et `prod` | ⏳ en cours |
| Sauvegarde et restauration de la base | ⏳ à venir |
| Terraform et Ansible | ⏳ à venir |
| Supervision (ELK), alertes, indicateurs DORA, tests de charge | ⏳ à venir |

## Architecture

Tout tourne **en local**, sur une machine Ubuntu de l'équipe : le cluster
Kubernetes est un **Minikube** (profil `orion`). GitHub conserve le code,
orchestre la CI et héberge le registre d'images.

```text
 Développeur ──PR──▶ GitHub (dépôt public, GitHub Actions)
                        │
          ┌─────────────┴──────────────────┐
          ▼                                ▼
 Runners hébergés par GitHub       Runner local ARC (dans Minikube)
 tests, scans, images,             analyse SonarQube
 version, publication              (et déploiement, à venir)
          │ images vX.Y.Z                  │
          ▼                                ▼
 GHCR (registre d'images) ──────▶ Cluster Minikube « orion »
                                   ├─ arc-runners : runners de la CI
                                   ├─ sonarqube   : SonarQube + PostgreSQL
                                   └─ dev         : MicroCRM (chart Helm)

 Dans le namespace dev :
 navigateur ──▶ front (nginx :8080) ──/api──▶ back (Spring Boot :8080)
                                                │ JDBC
                                                ▼
                                    PostgreSQL 18 (:5432, disque persistant)
```

- Le **front** sert les pages Angular et relaie `/api/…` vers le back :
  une seule adresse pour le navigateur, sans réglage CORS.
- Le **back** utilise PostgreSQL quand les variables
  `SPRING_DATASOURCE_*` sont fournies (Kubernetes), sinon une base
  HSQLDB en mémoire (tests, poste de développement). Les tables sont
  créées par **Flyway** (`back/src/main/resources/db/migration/`).
- Le runner local n'a ni Docker, ni sudo, ni droits élevés : tout ce qui
  construit ou exécute du code tourne sur les machines jetables de GitHub.

## Contenu du dépôt

```text
.github/
  workflows/ci.yml        pipeline CI
  dependabot.yml          mises à jour automatiques des dépendances
  release/                semantic-release (versions figées)
  ISSUE_TEMPLATE/         formulaires de tickets [Dev] et [Ops]
  CODEOWNERS, pull_request_template.md
front/                    application Angular, Dockerfile, nginx.conf
back/                     API Spring Boot (Gradle), Dockerfile
infra/
  helm/microcrm/          chart Helm de l'application
  postgres/               image PostgreSQL durcie (sans gosu, sans root)
  sonarqube/              SonarQube dans le cluster
  arc/                    runner local de la CI (image durcie, réglages)
  systemd/                démarrage automatique de Minikube
scripts/                  scripts d'automatisation et leurs tests
docs/                     audit, normalisation et plan CI, mesures de départ
sonar-project.properties  réglages de l'analyse SonarQube
.trivyignore              failles acceptées, justifiées et datées
```

## Pipeline CI

Fichier : [`.github/workflows/ci.yml`](.github/workflows/ci.yml). Il se
lance à **chaque PR vers `main`**, à **chaque fusion sur `main`**, et à la
main depuis l'onglet **Actions**.

| Job | Rôle | Outil | Où |
|---|---|---|---|
| `test-front` | Dépendances, tests et couverture du front | `install-deps.sh`, `run-tests.sh` (Karma, lcov) | GitHub |
| `test-back` | Dépendances, tests et couverture du back | `install-deps.sh`, `run-tests.sh` (JUnit, JaCoCo) | GitHub |
| `sonarqube` | Analyse statique et **Quality Gate** | SonarQube Community Build | runner local |
| `gitleaks` | Secrets oubliés dans tout l'historique | gitleaks | GitHub |
| `hadolint` | Bonnes pratiques des Dockerfiles | hadolint | GitHub |
| `shellcheck` | Erreurs courantes des scripts Bash | ShellCheck | GitHub |
| `script-tests` | Tests des scripts | bashunit, pytest | GitHub |
| `trivy` | Failles des dépendances (production et outillage) | Trivy | GitHub |
| `images` | Construction et scan des images front et back | Docker, Trivy | GitHub |
| `release` | Numéro de version et Release GitHub (sur `main`) | semantic-release | GitHub |
| `publish` | Publication des images sur GHCR (sur `main`) | Docker | GitHub |
| `notify` | Ticket et e-mail si la CI échoue sur `main` | `notify.py` | GitHub |

**Règles** :

- une PR n'est fusionnable que si les contrôles obligatoires sont verts
  et si elle est à jour avec `main` ; les échecs de Trivy portent sur les
  failles **hautes et critiques** ;
- les actions sont figées par empreinte de commit et les images des
  outils par empreinte (digest) ; Dependabot propose leurs mises à jour ;
- chaque job n'a que les droits dont il a besoin (`GITHUB_TOKEN`) ;
- une PR venant d'une copie extérieure du dépôt (fork) ne tourne jamais
  sur le runner local.

Les commandes des jobs de tests sont des **scripts**, que l'on peut lancer
à l'identique sur un poste : voir [`scripts/README.md`](scripts/README.md)
(but, fonctionnement, paramètres et conditions d'exécution de chaque
script).

Détails et choix : [normalisation et plan CI](docs/02-normalisation-plan-ci.md).

## Versions et publication

- Les messages de commit suivent les **Conventional Commits** (`fix:`,
  `feat:`, `build:`…). À chaque fusion sur `main`, **semantic-release**
  en déduit la version (SemVer) : `fix` → correctif (`1.0.1`), `feat` →
  mineure (`1.1.0`), changement incompatible → majeure. Les autres types
  ne publient pas de version.
- Il crée l'étiquette Git `vX.Y.Z` et la
  [Release GitHub](https://github.com/yohanbouchet/orion/releases) avec ses
  notes.
- Les images sont publiées sur GHCR avec deux étiquettes : la version
  (`v1.1.0`) et le commit (`sha-<7 caractères>`) :
  - `ghcr.io/yohanbouchet/orion-front`
  - `ghcr.io/yohanbouchet/orion-back`

## Lancer l'application sur un poste

Prérequis : Java 17, Node.js 24, Google Chrome (tests du front).

```shell
# API sur http://localhost:8080, base HSQLDB en mémoire
cd back && ./gradlew bootRun
```

Dans un second terminal :

```shell
# Dépendances aux versions exactes de package-lock.json
scripts/install-deps.sh front
# Front sur http://localhost:4200 ; /api est relayé vers le back
# (front/src/proxy.conf.json)
cd front && npx ng serve
```

Tests, comme dans la CI :

```shell
scripts/run-tests.sh front
scripts/run-tests.sh back
```

## Images Docker

Un Dockerfile par composant, en deux étapes (construction, puis image
d'exécution minimale), sans root, versions figées par empreinte.

```shell
docker build -t orion-front:local front/
docker build -t orion-back:local back/

# Back seul, avec sa base HSQLDB en mémoire : http://localhost:8080
docker run --rm -p 8080:8080 orion-back:local
```

Le front écoute sur le port **8080** (nginx sans droits d'administrateur).
Lancé seul, il affiche les pages mais n'a pas d'API : le relais `/api`
lui est fourni au déploiement, par le chart Helm.

Les images publiées par la CI se récupèrent avec
`docker pull ghcr.io/yohanbouchet/orion-back:v1.1.0` (et de même pour le
front).

## Déployer sur Kubernetes

Prérequis : le cluster Minikube `orion`
([installation](#installer-la-chaîne-sur-le-poste-ops)), `kubectl` et
`helm` 4.

```shell
# 1. Image PostgreSQL durcie, construite et chargée dans Minikube (elle
#    n'est jamais téléchargée : imagePullPolicy Never)
docker build -t orion/postgres:18.6-hardened infra/postgres
minikube -p orion image load orion/postgres:18.6-hardened
```

2. Namespaces `dev`, `staging` et `prod`, créés une seule fois au niveau
   de sécurité « restricted » : commande dans le
   [README du chart](infra/helm/microcrm/README.md#installation).

3. Déploiement, vérifié par un test de fumée, avec retour arrière
   automatique en cas d'échec
   ([détails](scripts/README.md#deploysh)) :

   ```shell
   scripts/deploy.sh dev              # ou : staging, prod ; étiquette
                                      # facultative : v1.1.0, sha-abc1234
   scripts/deploy.sh rollback dev     # retour à la version précédente
   ```

4. Accès à l'application :

   ```shell
   kubectl -n dev port-forward svc/microcrm-front 8080:8080
   ```

   puis http://localhost:8080 (depuis un autre poste : transfert de port
   de VS Code).

## Installer la chaîne sur le poste Ops

À faire une seule fois, sur la machine qui héberge le runner local et
SonarQube (Docker, `minikube`, `kubectl` et `helm` installés).

```shell
# 1. Cluster Minikube (4 cœurs, 7 Go), puis démarrage automatique :
#    voir infra/systemd/README.md
minikube start -p orion --driver=docker --cpus=4 --memory=7g \
  --kubernetes-version=v1.37.0

# 2. Contrôleur des runners (ARC), version figée
helm install arc --namespace arc-systems --create-namespace \
  --version 0.15.1 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# 3. Namespace des runners (Pod Security « restricted ») et accès de
#    l'application GitHub ; la clé privée reste hors du dépôt
kubectl apply -f infra/arc/namespace.yaml
kubectl -n arc-runners create secret generic orion-arc-github-app \
  --from-literal=github_app_id=<id> \
  --from-literal=github_app_installation_id=<installation> \
  --from-file=github_app_private_key=<chemin/de/la/clé.pem>

# 4. Image durcie du runner, chargée dans Minikube, puis groupe de runners
docker build -t orion/actions-runner:2.338.2-hardened.2 infra/arc
minikube -p orion image load orion/actions-runner:2.338.2-hardened.2
helm install orion-local --namespace arc-runners --version 0.15.1 \
  -f infra/arc/values-orion-runners.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

# 5. SonarQube et sa base (image PostgreSQL durcie chargée avant, voir
#    « Déployer sur Kubernetes », étape 1)
scripts/deploy-sonarqube.sh
```

Enfin, dans GitHub (**Settings** → **Environments** → `sonarqube`) : le
secret `SONAR_TOKEN` (jeton d'analyse du projet) et la variable
`SONAR_HOST_URL` (adresse de SonarQube vue depuis le runner).

## Sécurité

- **Aucun secret dans le dépôt** : gitleaks à chaque PR ; détection et
  blocage des secrets activés sur GitHub ; mots de passe des bases créés
  au déploiement, avec une valeur aléatoire, dans des Secrets Kubernetes.
- **Dépendances et images** : Trivy bloque les failles hautes et
  critiques ; une faille sans correctif n'est acceptée que justifiée et
  datée dans [`.trivyignore`](.trivyignore) ; Dependabot propose les mises
  à jour après un délai de refroidissement (sécurité : immédiat).
- **Images durcies** : sans root, versions figées, seulement le
  nécessaire ; image PostgreSQL sans `gosu`.
- **Cluster** : namespaces au niveau Pod Security « restricted »,
  conteneurs en lecture seule et sans capacité Linux, pare-feu entre pods
  (NetworkPolicy, refus par défaut).
- **CI** : actions figées par empreinte, droits minimaux par job, runner
  local jetable et non privilégié, jamais utilisé par un fork.

## Contribuer

1. Ouvrir un ticket avec le formulaire **[Dev]** (code de l'application)
   ou **[Ops]** (infrastructure, CI, scripts).
2. Créer une branche courte depuis `main`, puis une PR qui cite le ticket
   (`Closes #n`) ; le modèle de PR liste les vérifications.
3. Messages de commit : type et portée en anglais, description en
   français, par exemple `fix(front): corrige l'affichage des personnes`.
4. La PR est fusionnée quand la CI est verte ; les relecteurs sont
   ajoutés automatiquement ([`CODEOWNERS`](.github/CODEOWNERS)).

Règles complètes : [normalisation](docs/02-normalisation-plan-ci.md#2-normes-et-bonnes-pratiques).

## Documentation

| Document | Contenu |
|---|---|
| [Veille, audit et recommandations](docs/01-veille-audit-recommandations.md) | État initial, SWOT, comparatifs d'outils, recommandations (29/10/2026) |
| [Normalisation et plan CI](docs/02-normalisation-plan-ci.md) | Règles communes, pipeline cible, étapes, risques |
| [Mesures de départ](docs/mesures-avant/README.md) | Pipeline, qualité et sécurité de l'application d'origine |
| [Scripts](scripts/README.md) | Chaque script : but, fonctionnement, paramètres, tests |
| [Chart Helm](infra/helm/microcrm/README.md) | Déploiement Kubernetes, environnements, sécurité, limites |
| [Démarrage de Minikube](infra/systemd/README.md) | Service systemd du cluster |

## Versions des outils

Vérifiées le 02/11/2026 (dernière version publiée et fin de support sur
[endoflife.date](https://endoflife.date)) :

| Outil | Version |
|---|---|
| Spring Boot / Java | 4.1.2 / 17 |
| Angular / Node.js | 17.3 / 24 |
| PostgreSQL | 18.6 |
| Kubernetes (Minikube 1.39.0) | 1.37.0 (correctif 1.37.2 disponible) |
| Helm | 4.3.1 |
| ARC (runner local) | 0.15.1, runner 2.338.2 |
| SonarQube Community Build | 26.10 |
| Trivy / hadolint / gitleaks / ShellCheck | 0.76.1 / 2.15.1 / 8.30.1 / 0.11.0 |

Angular 17 n'est plus maintenu : sa montée de version est recommandée à
l'équipe Dev ([audit, R4](docs/01-veille-audit-recommandations.md#r4-remettre-le-socle-applicatif-sous-maintenance)) ;
en attendant, ses failles sans correctif sont suivies et datées dans
`.trivyignore`.
