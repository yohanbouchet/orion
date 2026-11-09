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
- [Sauvegarder la base](#sauvegarder-la-base)
- [Superviser](#superviser)
- [Sécurité](#sécurité)
- [Limites connues et évolutions](#limites-connues-et-évolutions)
- [Contribuer](#contribuer)
- [Documentation](#documentation)
- [Versions des outils](#versions-des-outils)

## État d'avancement

Au 08/11/2026 :

| Étape | État |
|---|---|
| Audit, veille et recommandations ; normalisation et plan CI | ✅ [`docs/`](docs/) |
| Pipeline CI : tests, couverture, SonarQube, scans de sécurité, images | ✅ |
| Versions automatiques (semantic-release) et publication des images | ✅ |
| Scripts : dépendances, tests, notification, avec leurs tests | ✅ [`scripts/`](scripts/README.md) |
| Chart Helm de l'application (testé dans `dev`) | ✅ [`infra/helm/microcrm/`](infra/helm/microcrm/README.md) |
| Script de déploiement avec test de fumée et retour arrière | ✅ [`scripts/deploy.sh`](scripts/README.md#deploysh) |
| Déploiement continu : `dev` puis `staging` à chaque fusion, `prod` sur une version après approbation | ✅ [`deploy.yml`](.github/workflows/deploy.yml) |
| Test d'intrusion automatisé (ZAP) : passif à chaque déploiement de `staging` (bloque la prod), actif à la demande | ✅ [`zap.yml`](.github/workflows/zap.yml), [règles](infra/zap/rules.tsv) |
| Sauvegarde, vérification et restauration de la base | ✅ [`scripts/backup.sh`](scripts/README.md#backupsh) ; prod sauvegardée au démarrage du poste et chaque jour, restauration vérifiée chaque semaine, copie hors site chiffrée |
| Socle du cluster en code : fichiers Terraform, exécutés par OpenTofu depuis le 09/11 (namespaces, comptes de déploiement aux droits limités) | ✅ [`infra/terraform/`](infra/terraform/README.md) |
| Ansible : configuration et durcissement du poste Ops (outils, cluster, images, sauvegardes, disque, pare-feu, métriques de l'hôte) | ✅ [`infra/ansible/`](infra/ansible/README.md) |
| Supervision : métriques, journaux, alertes par e-mail, 3 tableaux de bord (VictoriaMetrics, VictoriaLogs, Grafana) | ✅ [`infra/monitoring/`](infra/monitoring/README.md) |
| Coffre-fort de secrets OpenBao (TLS, déverrouillage manuel par l'Ops, clés hors du dépôt) | ✅ [`infra/openbao/`](infra/openbao/README.md) |
| Tests de charge k6 (6 profils) ; test de fumée k6 avant chaque mise en prod ; autoscaling (HPA) du back en `staging` et en `prod` | ✅ [`load-test.sh`](scripts/README.md#load-testsh) |
| Indicateurs DORA, calculés chaque lundi et à la demande | ✅ [`dora.py`](scripts/README.md#dorapy) |
| Front mis à jour vers Angular 22, tests passés à Vitest : 0 faille connue, 0 problème SonarQube | ✅ v1.7.1 |
| Compte limité de l'application dans la base (moindre privilège) | ✅ v1.8.0, [chart](infra/helm/microcrm/README.md#sécurité) |
| Mises à jour sans requête perdue (pause avant l'arrêt des pods) | ✅ v1.8.1, [chart](infra/helm/microcrm/README.md#sécurité) |
| Rapport de performance (mesures avant/après, recommandations) | ✅ [`docs/04`](docs/04-rapport-performance.md) |
| Documentation CI/CD complète (plans de tests et de sécurité, de conteneurs et de déploiement, de release, cible AWS) | ✅ [`docs/03`](docs/03-documentation-ci-cd.md) |

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
 tests, scans, images,             analyse SonarQube, déploiement
 version, publication              (dev, staging, prod), test ZAP
          │ images vX.Y.Z                  │
          ▼                                ▼
 GHCR (registre d'images) ──────▶ Cluster Minikube « orion »
                                   ├─ arc-runners : runners de la CI
                                   ├─ sonarqube   : SonarQube + PostgreSQL
                                   ├─ monitoring  : métriques, journaux,
                                   │  Grafana, alertes (+ collecteur de
                                   │  journaux : monitoring-collector)
                                   └─ dev, staging, prod : MicroCRM
                                      (+ pod ZAP éphémère en staging)

 Dans chaque namespace de l'application :
 navigateur ──▶ front (nginx :8080) ──/api──▶ back (Spring Boot :8080)
                                                │ JDBC
                                                ▼
                                    PostgreSQL 18 (:5432, disque persistant)
```

- Le **front** sert les pages Angular et relaie `/api/…` vers le back :
  une seule adresse pour le navigateur, sans réglage CORS.
- Le **back** utilise PostgreSQL quand les variables
  `SPRING_DATASOURCE_*` sont fournies (Kubernetes), sinon une base
  HSQLDB en mémoire (tests, poste de développement). Dans Kubernetes, il
  se connecte avec un compte aux droits limités ; les tables sont créées
  par **Flyway** (`back/src/main/resources/db/migration/`), avec le
  compte propriétaire de la base.
- Le runner local n'a ni Docker, ni sudo, ni droits élevés : tout ce qui
  construit ou exécute du code tourne sur les machines jetables de GitHub.
  Le test d'intrusion tourne dans un pod jetable de `staging`, lancé par
  le runner avec les droits du deployer de `staging`.

## Contenu du dépôt

```text
.github/
  workflows/ci.yml        pipeline CI
  workflows/deploy.yml    déploiement d'un environnement (appelé par ci.yml)
  workflows/zap.yml       test d'intrusion de staging (ci.yml ou à la main)
  workflows/load-test.yml test de charge k6 de staging (ci.yml ou à la main)
  workflows/dora.yml      indicateurs DORA (chaque lundi ou à la main)
  workflows/runner-smoke-test.yml  test du runner local (à la main)
  actions/kube-access/    accès au cluster des jobs du runner local
  dependabot.yml          mises à jour automatiques des dépendances
  release/                semantic-release (versions figées)
  ISSUE_TEMPLATE/         formulaires de tickets [Dev] et [Ops]
  CODEOWNERS, pull_request_template.md
front/                    application Angular, Dockerfile, nginx.conf
back/                     API Spring Boot (Gradle), Dockerfile
infra/
  terraform/              socle du cluster, fichiers Terraform exécutés
                          par OpenTofu (namespaces, comptes deployer,
                          installation de la supervision et d'OpenBao)
  monitoring/             supervision : réglages, alertes, tableaux de bord
  openbao/                coffre-fort de secrets (réglages, exploitation)
  ansible/                configuration et durcissement du poste Ops
  zap/                    règles du test d'intrusion (bloquant ou non)
  k6/                     scénario des tests de charge
  helm/microcrm/          chart Helm de l'application
  postgres/               image PostgreSQL durcie (sans gosu, sans root)
  sonarqube/              SonarQube dans le cluster
  arc/                    runner local de la CI (image durcie, réglages)
  systemd/                démarrage automatique de Minikube
scripts/                  scripts d'automatisation et leurs tests
docs/                     audit, normalisation et plan CI, documentation
                          CI/CD, mesures de départ, rapport de performance
sonar-project.properties  réglages de l'analyse SonarQube
.trivyignore              failles acceptées, justifiées et datées
```

## Pipeline CI

Fichier : [`.github/workflows/ci.yml`](.github/workflows/ci.yml). Il se
lance à **chaque PR vers `main`**, à **chaque fusion sur `main`**, et à la
main depuis l'onglet **Actions**.

| Job | Rôle | Outil | Où |
|---|---|---|---|
| `test-front` | Dépendances, tests et couverture du front | `install-deps.sh`, `run-tests.sh` (Vitest, lcov) | GitHub |
| `test-back` | Dépendances, tests et couverture du back | `install-deps.sh`, `run-tests.sh` (JUnit, JaCoCo) | GitHub |
| `sonarqube` | Analyse statique et **Quality Gate** | SonarQube Community Build | runner local |
| `gitleaks` | Secrets oubliés dans tout l'historique | gitleaks | GitHub |
| `hadolint` | Bonnes pratiques des Dockerfiles | hadolint | GitHub |
| `shellcheck` | Erreurs courantes des scripts Bash | ShellCheck | GitHub |
| `script-tests` | Tests des scripts | bashunit, pytest | GitHub |
| `opentofu` | Mise en forme, validité et tests du socle (fichiers Terraform) | OpenTofu (`fmt`, `validate`, `test`) | GitHub |
| `ansible` | Syntaxe et bonnes pratiques du code Ansible (jamais exécuté par la CI) | ansible-playbook `--syntax-check`, ansible-lint (profil production) | GitHub |
| `trivy` | Failles des dépendances (production et outillage) | Trivy | GitHub |
| `images` | Construction et scan des images front et back | Docker, Trivy | GitHub |
| `release` | Numéro de version et Release GitHub (sur `main`) | semantic-release | GitHub |
| `publish` | Publication des images sur GHCR (sur `main`) | Docker | GitHub |
| `deploy-dev`, `deploy-staging` | Déploiement de l'image du commit (`sha-xxxxxxx`) dans `dev`, puis `staging` (sur `main`) | `deploy.yml`, `deploy.sh` | runner local |
| `zap` | Test d'intrusion passif de `staging` ; une alerte réglée sur FAIL bloque la prod | `zap.yml`, `zap-scan.sh` (ZAP) | runner local |
| `load-test` | Test de fumée k6 de `staging` (1 utilisateur simulé, 30 s) : un seuil dépassé bloque la prod | `load-test.yml`, `load-test.sh` (k6) | runner local |
| `deploy-prod` | Déploiement de la version `vX.Y.Z` dans `prod`, après approbation (si une version vient d'être publiée, si ZAP n'a rien trouvé de bloquant et si le test de fumée k6 a réussi) | `deploy.yml`, `deploy.sh` | runner local |
| `notify` | Ticket et e-mail si la CI échoue sur `main` | `notify.py` | GitHub |

**Règles** :

- une PR n'est fusionnable que si les contrôles obligatoires sont verts
  et si elle est à jour avec `main` ; les échecs de Trivy portent sur les
  failles **hautes et critiques** ;
- les actions sont figées par empreinte de commit et les images des
  outils par empreinte (digest) ; Dependabot propose les mises à jour des
  actions et des images de base des Dockerfiles, mais pas celles des
  images d'outils citées dans les workflows (Trivy, gitleaks, hadolint,
  ShellCheck), mises à jour à la main ;
  seules les actions d'une liste d'autorisation peuvent s'exécuter
  (Settings → Actions → General) ;
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
  ne publient pas de version, ni les portées qui ne sont pas livrées avec
  l'application (`monitoring`, `ansible`, `scripts`…) : seuls `back`,
  `front`, `helm`, `postgres` et `deps` en créent une
  ([règle](docs/03-documentation-ci-cd.md#73-système-de-versioning)).
- Il crée l'étiquette Git `vX.Y.Z` et la
  [Release GitHub](https://github.com/yohanbouchet/orion/releases) avec ses
  notes.
- Les images sont publiées sur GHCR avec deux étiquettes : la version
  (`v1.1.0`) et le commit (`sha-<7 caractères>`) :
  - `ghcr.io/yohanbouchet/orion-front`
  - `ghcr.io/yohanbouchet/orion-back`

## Lancer l'application sur un poste

Prérequis : Java 17, Node.js 24 (les tests du front n'ont plus besoin de
navigateur depuis Vitest).

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

Un Dockerfile par composant, sans root, versions figées par empreinte.
Le front est construit en deux étapes (construction, puis image
d'exécution minimale). Le back n'est pas compilé dans Docker : son image
emballe le jar déjà compilé et testé (dans la CI, celui du job
`test-back`). Le jar livré est donc celui que les tests ont validé, et
la construction de l'image ne télécharge rien (ni Gradle ni
bibliothèque).

```shell
docker build -t orion-front:local front/
# Back : le jar d'abord (build/libs/), puis l'image qui l'emballe
(cd back && ./gradlew bootJar)
docker build -t orion-back:local back/

# Back seul, avec sa base HSQLDB en mémoire : http://localhost:8080
docker run --rm -p 8080:8080 orion-back:local
```

Le front écoute sur le port **8080** (nginx sans droits d'administrateur).
Lancé seul, il affiche les pages mais n'a pas d'API : le relais `/api`
lui est fourni au déploiement, par le chart Helm.

Les images publiées par la CI se récupèrent avec
`docker pull ghcr.io/yohanbouchet/orion-back:<version>` (par exemple
`v1.8.1`, liste dans les
[Releases](https://github.com/yohanbouchet/orion/releases) ; de même pour
le front).

## Déployer sur Kubernetes

Prérequis : le cluster Minikube `orion`
([installation](#installer-la-chaîne-sur-le-poste-ops)), `kubectl`,
`helm` 4 et OpenTofu 1.13.

Les images du projet (PostgreSQL durcie, ZAP, runner) sont construites et
chargées dans Minikube par Ansible ([`infra/ansible`](infra/ansible/README.md),
rôle `cluster_images`). À la main :

```shell
# 1. Image PostgreSQL durcie, construite et chargée dans Minikube (elle
#    n'est jamais téléchargée : imagePullPolicy Never)
docker build -t orion/postgres:18.6-hardened infra/postgres
minikube -p orion image load orion/postgres:18.6-hardened

# Image du test d'intrusion (ZAP corrigé, règles bêta vérifiées par
# empreinte), utilisée dans staging par scripts/zap-scan.sh
docker build -t orion/zap:2.17.0-hardened infra/zap
minikube -p orion image load orion/zap:2.17.0-hardened
```

2. Socle du cluster, une seule fois, par OpenTofu : namespaces `dev`,
   `staging` et `prod` au niveau de sécurité « restricted », et un compte
   de déploiement par namespace, enfermé dans celui-ci
   ([`infra/terraform`](infra/terraform/README.md#utilisation)).

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

### Déploiement continu (CI)

Après une fusion sur `main`, si tous les contrôles sont verts et les
images publiées, la CI lance la même commande `scripts/deploy.sh` sur le
runner local, avec le workflow réutilisable
[`deploy.yml`](.github/workflows/deploy.yml) :

```text
publish ──▶ deploy-dev ──▶ deploy-staging ──▶ zap ──────▶ load-test ──▶ deploy-prod
            image          même image         test        test de      vX.Y.Z, si
            sha-xxxxxxx    (promotion)        passif      fumée k6     release en a
                                              (FAIL :     (seuil       publié une ;
                                              arrêt)      dépassé :    approbation
                                                          arrêt)
```

| Environnement (GitHub / namespace) | Branche | Type de déploiement | Accès | Particularités |
|---|---|---|---|---|
| `dev` / `dev` | `main` | automatique, à chaque fusion (image `sha-xxxxxxx`) | `kubectl -n dev port-forward svc/microcrm-front 8080:8080` | 1 réplique par composant ; réglages par défaut du chart |
| `staging` / `staging` | `main` | automatique, après la réussite de `dev` (même image) | idem, `-n staging` | back de 1 à 4 répliques (autoscaling HPA, comme la prod mais à partir d'une), autres composants à 1 ; cible des tests ZAP et k6 : seuls ces pods peuvent joindre le front |
| `production` / `prod` | `main` | à chaque version `vX.Y.Z`, **après approbation** | idem, `-n prod` | front à 2 répliques ; back à 2 répliques au minimum, autoscaling (HPA) ; mise à jour progressive sans coupure |

Chaque environnement GitHub garde le secret `KUBE_TOKEN`, jeton du
compte `deployer` de son namespace. `ci.yml` transmet ce seul secret à
`deploy.yml` (pas `secrets: inherit`, qui transmettrait tous les
secrets du dépôt, même ceux ajoutés plus tard) ; sans cette
transmission, GitHub donne une valeur vide sans erreur : `deploy.yml`
l'exige donc (`required: true`) et s'arrête avec un message clair si le
jeton est vide. Chaque déploiement est tracé dans l'onglet
**Deployments** du dépôt (environnement, commit, exécution) et dans le
résumé de l'exécution (image déployée).

- Chaque job ne reçoit que le jeton de **son** environnement, et ce jeton
  ne permet d'agir que dans **son** namespace
  ([OpenTofu](infra/terraform/README.md#droits-dun-compte-deployer)).
- Les règles s'appliquent aussi aux administrateurs du dépôt
  (contournement désactivé).
- Le certificat public de l'autorité du cluster est la variable de dépôt
  `KUBE_CA` : le job vérifie qu'il parle au vrai cluster
  (`https://kubernetes.default.svc`, adresse interne).
- `kubectl` et `helm` sont les binaires officiels, refusés si leur
  empreinte SHA-256 diffère de celle notée dans `deploy.yml`.
- Un seul déploiement à la fois par environnement ; un échec du test de
  fumée remet la version précédente et fait échouer le job.

**Vérifié le 02/11/2026**, avant la première exécution par GitHub : les
étapes de `deploy.yml`, lancées dans un pod de l'image du runner local
avec le jeton de `dev`, ont déployé `sha-c2f1558` (révision 12, test de
fumée réussi) ; une empreinte fausse arrête le job avant toute connexion ;
le fichier de connexion est en 600 et supprimé à la fin. Limite de ce
test : le jeton y était fourni à la main ; la première exécution par
GitHub a échoué (jeton vide, secret non transmis par `ci.yml`, ticket
#77), corrigée ensuite. Le cluster n'a pas été modifié (`dev` resté à la
révision 12).

### Test d'intrusion (ZAP)

[ZAP](https://www.zaproxy.org/) (OWASP) teste l'application **en
fonctionnement**, comme un attaquant sans accès au code. Il tourne dans
`staging`, en Job Kubernetes, avec l'image du projet
[`infra/zap`](infra/zap/Dockerfile) et le script
[`zap-scan.sh`](scripts/README.md#zap-scansh) :

| Mode | Quand | Ce qu'il fait | Durée mesurée |
|---|---|---|---|
| `baseline` (passif) | après chaque déploiement de `staging` (job `zap` de `ci.yml`) | visite les pages et inspecte les réponses (en-têtes, cookies, fuites d'information) | ~30 s |
| `full` (actif) | à la demande : Actions → **ZAP** → Run workflow | en plus, tente des attaques (injections SQL et de commandes, XSS, traversée de dossiers) | ~2 min |

Chaque alerte reçoit une décision dans
[`infra/zap/rules.tsv`](infra/zap/rules.tsv) : **FAIL** (bloque la prod),
WARN (signalée), INFO ou IGNORE. Le rapport est dans le **résumé de
l'exécution** et en **artefact** (`zap-baseline-report`, 30 jours).

Premiers résultats (03/11/2026, `staging`) : aucune alerte bloquante,
5 alertes WARN ; triées, puis **corrigées avant la prod** quand elles
dépendaient de l'exploitation :

| Alerte | Risque | Décision |
|---|---|---|
| En-tête CSP absent | Moyen | **Corrigé** : `front/nginx.conf` ; règle passée en FAIL |
| En-têtes Permissions-Policy et d'isolation (Spectre) absents | Faible | **Corrigés** avec la CSP ; règles en FAIL |
| Angular 17.3.12 vulnérable (bibliothèque JavaScript) | Élevé | **Corrigé** le 08/11 : Angular 22 (ticket #113) ; règle passée en FAIL |
| CSS Bulma chargé d'un CDN sans contrôle d'intégrité (SRI) | Moyen | **Corrigé** le 08/11 : Bulma installé avec npm et servi par le site, CSP limitée au site ; règle passée en FAIL |
| Contenu gardé par les caches sans durée fixée (*Storable and Cacheable Content*, 09/11) | Information | **Corrigé** : `Cache-Control` par type d'adresse ; API `no-store` (données personnelles) ; fichiers à empreinte gardés un an ; le reste revalidé |

Vérifié avant la fusion : avec les règles en FAIL, le front sans les
en-têtes fait échouer ZAP (3 alertes FAIL, prod bloquée) ; avec les
en-têtes, 0 FAIL et 64 règles passées ; l'application fonctionne dans
Chromium et Firefox, sans aucune violation de la CSP (liste, détail,
création).

Revérifié le 08/11 avec Angular 22 et Bulma servi par le site : ZAP en
local, 0 FAIL, 0 WARN, 66 règles passées ; pages affichées dans Chrome
avec la CSP stricte, sans aucune erreur.

Les protections déjà en place (anti-cadre, `nosniff`, aucune version du
serveur affichée, aucune injection ni XSS trouvée…) sont réglées sur
FAIL : leur disparition bloquerait la prod.

Sécurité du scan lui-même : pod éphémère, sans root, sans jeton, isolé
par le pare-feu (il ne joint que le front, pas Internet) ; ZAP ne
télécharge rien (`-silent`) : ses modules sont figés dans l'image et
vérifiés par empreinte à la construction.

## Installer la chaîne sur le poste Ops

À faire une seule fois, sur la machine qui héberge le runner local et
SonarQube (Docker, `minikube`, `kubectl` et `helm` installés).

La configuration de la machine elle-même (outils à version figée,
démarrage automatique du cluster, images, metrics-server, sauvegardes
planifiées, hygiène du disque, pare-feu, fail2ban, métriques de l'hôte)
est faite par **Ansible**, après l'étape 1 :
`cd infra/ansible && ansible-playbook site.yml -K`
([détails](infra/ansible/README.md)).

```shell
# 1. Cluster Minikube (4 cœurs, 10 Gio), puis démarrage automatique :
#    voir infra/systemd/README.md. 10 Gio depuis le 06/11 : à 7, le nœud
#    saturait quand la CI et un test de charge coïncidaient (rapport de
#    performance) ; Minikube ne redimensionne pas un cluster existant :
#    agrandi à chaud avec « docker update --memory 10g --memory-swap 12g
#    orion » + "Memory": 10240 dans ~/.minikube/profiles/orion/config.json
minikube start -p orion --driver=docker --cpus=4 --memory=10g \
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

## Sauvegarder la base

```shell
scripts/backup.sh dev                          # ~/backups/microcrm/dev/
scripts/backup.sh verify dev                   # se restaure-t-elle ?
scripts/backup.sh restore dev <fichier>        # toute la base
scripts/backup.sh restore dev <fichier> --table person
```

En production, Ansible planifie la sauvegarde au démarrage du poste et
chaque jour à 12 h 30, et la vérification de sa restauration chaque
vendredi (le poste est éteint le soir : rien n'est planifié la nuit) ;
le dossier est copié
hors site par la sauvegarde chiffrée de la machine (GPG, Google Drive).
Chaque restauration est précédée d'une sauvegarde de sécurité de l'état
actuel. Objectifs : perte de données maximale (RPO) de 24 h avec une
sauvegarde quotidienne ; temps de restauration (RTO) mesuré à 0,6 s.
Une alerte (`BackupTooOld`) prévient si la dernière sauvegarde réussie de
la prod date de plus de 26 h.
Fonctionnement, sécurité et limites : [`scripts/README.md`](scripts/README.md#backupsh).

## Superviser

Pile **VictoriaMetrics + VictoriaLogs + Grafana** (open source, Apache 2.0
sauf Grafana en AGPL v3), installée par OpenTofu dans deux namespaces :
`monitoring` (« restricted ») et `monitoring-collector` (collecteur de
journaux seul, verrouillé). Elle lit les métriques de l'API (Spring Boot
Actuator, port de gestion 8081), de Kubernetes et de la machine
(node_exporter), et les journaux des conteneurs (gardés 7 jours). Huit
alertes sont envoyées par e-mail : disponibilité (prod arrêtée,
redémarrages en boucle), performance (erreurs 5xx, lenteur), machine
(disque, sauvegarde) et sécurité (rafale de requêtes refusées, journaux
qui n'arrivent plus). Trois tableaux de bord sont disponibles :
disponibilité, performance, sécurité. Consommation mesurée le 07/11 :
≈ 1,1 Gio et 0,1 cœur. Détails, premiers gestes face à une alerte,
sécurité et limites : [`infra/monitoring/README.md`](infra/monitoring/README.md).

## Sécurité

- **Aucun secret dans le dépôt** : gitleaks à chaque PR ; détection et
  blocage des secrets activés sur GitHub ; mots de passe des bases créés
  au déploiement, avec une valeur aléatoire, dans des Secrets Kubernetes.
- **Dépendances et images** : Trivy bloque les failles hautes et
  critiques ; une faille sans correctif n'est acceptée que justifiée et
  datée dans [`.trivyignore`](.trivyignore) ; Dependabot propose les mises
  à jour après un délai de refroidissement (sécurité : immédiat).
- **En-têtes de sécurité du front** (nginx) : CSP stricte (scripts du
  site seulement, aucun style en ligne), anti-cadre, `nosniff`,
  `Referrer-Policy`, `Permissions-Policy`, isolation (COOP, CORP, COEP),
  `Cache-Control` (réponses de l'API jamais gardées par un cache).
- **Images durcies** : sans root, versions figées, seulement le
  nécessaire ; image PostgreSQL sans `gosu`.
- **Cluster** : namespaces au niveau Pod Security « restricted »,
  conteneurs en lecture seule et sans capacité Linux, pare-feu entre pods
  (NetworkPolicy, refus par défaut) ; un compte de déploiement par
  namespace, sans droit ailleurs (OpenTofu).
- **Base de données** : l'API se connecte avec un compte limité
  (`microcrm_app`) qui ne peut que lire et écrire des lignes : une
  injection SQL ne pourrait ni supprimer une table, ni créer un compte,
  ni lancer une commande système. Le superutilisateur ne sert qu'aux
  migrations Flyway et aux sauvegardes
  ([détails](infra/helm/microcrm/README.md#sécurité)).
- **CI** : actions figées par empreinte et limitées par une liste
  d'autorisation du dépôt (actions de GitHub,
  `SonarSource/sonarqube-scan-action`, `opentofu/setup-opentofu`) :
  toute autre action est refusée au démarrage du pipeline ; droits
  minimaux par job ; runner local jetable et non privilégié, jamais
  utilisé par un fork ; jetons de déploiement rangés dans les
  environnements GitHub (`main` seulement, approbation pour la prod).
- **Test d'intrusion** : ZAP passif sur `staging` à chaque déploiement,
  actif à la demande ; les alertes réglées sur FAIL bloquent la prod
  ([détails](#test-dintrusion-zap)).
- **Sauvegardes** : fichiers en 600, dossiers en 700, empreinte SHA-256
  contrôlée avant toute restauration, restauration vérifiée chaque
  semaine ; copie hors site chiffrée ; disque de la machine chiffré.
- **Machine hôte** (Ansible) : mises à jour de sécurité automatiques,
  pare-feu (entrée refusée sauf SSH du réseau local), fail2ban, journaux
  Docker limités, outils à version figée et empreinte vérifiée ; le
  playbook n'est jamais lancé par la CI.

## Limites connues et évolutions

Ce qui reste à améliorer, détaillé dans chaque README :

| Limite | Évolution | Détails |
|---|---|---|
| Tout tourne sur une seule machine (Minikube) | Cible cloud AWS : EKS sur 2 zones, RDS Multi-AZ, S3 | [documentation CI/CD, 5.2.1](docs/03-documentation-ci-cd.md#521-schéma-dinfrastructure-cloud) |
| Sauvegarde quotidienne complète, non chiffrée fichier par fichier sur la machine (la copie hors site, elle, est chiffrée) | Restauration à un instant donné (WAL, CloudNativePG ou RDS), sauvegarde incrémentale | [scripts](scripts/README.md#backupsh) |
| Poste Ops : SSH accepte encore les mots de passe ; un seul poste ; rôles Ansible testés par lint et idempotence, sans machine jetable | Clé SSH seule, inventaire multi-machines, Molecule | [Ansible](infra/ansible/README.md#limites-et-évolutions) |
| Déploiement « poussé » par la CI : un jeton du cluster est rangé dans GitHub, une modification faite à la main dans le cluster n'est pas détectée | GitOps avec Argo CD : le cluster lit lui-même Git et corrige tout écart | [CI](#déploiement-continu-ci) |
| Jetons de déploiement de longue durée, état OpenTofu local | Fédération OIDC GitHub → cluster (jetons de quelques minutes) ; état distant chiffré et verrouillé | [OpenTofu](infra/terraform/README.md#limites-connues-et-évolutions) |
| Versions de `kubectl` et `helm` (jobs du runner local) et images d'outils des workflows (Trivy, gitleaks, hadolint, ShellCheck) mises à jour à la main : Dependabot ne les suit pas (l'image ZAP, elle, est suivie via `infra/zap/Dockerfile`) | Image du runner contenant ces outils, et fichier d'images d'outils, suivis par Dependabot | [CI](#déploiement-continu-ci) |
| Test d'intrusion limité au front : l'API ne publie pas de description OpenAPI, le scan actif n'atteint donc pas ses routes ; scan actif lancé à la main | OpenAPI (`springdoc`, équipe Dev) puis `zap-api-scan` ; scan actif planifié chaque semaine | [ZAP](#test-dintrusion-zap) |
| Image ZAP : 421 failles hautes ou critiques sans correctif, dans le système de base de l'image officielle | Suivre les versions de ZAP ; pod éphémère, isolé par le pare-feu, sans root (risque accepté) | [ZAP](#test-dintrusion-zap) |
| Une seule personne : elle approuve ses propres déploiements en prod | En équipe : une autre personne approuve (« Prevent self-review ») | [CI](#déploiement-continu-ci) |
| L'API utilise un compte limité, mais le mot de passe du superutilisateur de la base reste dans son pod (migrations Flyway au démarrage) | Migrations dans un Job séparé avant le déploiement ; API sans ce mot de passe | [chart](infra/helm/microcrm/README.md#limites-connues) |
| Supervision sur un seul nœud ; journaux techniques gardés 7 jours, masqués à la source seulement ; pas de journal d'audit (l'application n'a pas d'authentification) | VictoriaMetrics/VictoriaLogs en cluster ; Vector ou Alloy pour masquer centralement ; authentification puis audit pseudonymisé (6 mois à 1 an) | [supervision](infra/monitoring/README.md#limites-et-évolutions) |
| Table de liens sans clé primaire | Migration Flyway (équipe Dev) | [scripts](scripts/README.md#backupsh) |
| CSP sans style en ligne : un futur style de composant Angular serait bloqué | Jeton par page (« nonce », `ngCspNonce`) servi par nginx | [ZAP](#test-dintrusion-zap) |
| Outil de version (semantic-release, CI seulement) : 2 failles moyennes (déni de service) dans `glob` et `minimatch`, **intégrées au paquet npm** qu'il embarque : aucune surcharge de version possible, même la dernière version de npm (12.2.2, 04/11) les contient. Non bloquantes (seuil : haute), jamais livrées, et le module qui utilise npm n'est pas chargé (`.releaserc.yml`) | Mise à jour dès que npm les corrige (proposée par Dependabot) | [`.github/release/`](.github/release/package.json) |
| Pas d'ESLint dans le front | ESLint (équipe Dev) | [audit, R4](docs/01-veille-audit-recommandations.md#r4-remettre-le-socle-applicatif-sous-maintenance) |
| Réglage par défaut de Spring Boot `spring.jpa.open-in-view` actif (avertissement au démarrage du back) : chaque requête garde sa connexion à la base jusqu'à la fin de sa réponse ; sous forte charge, la réserve de connexions s'épuise plus vite | Le désactiver, après les tests du back et un test de charge avant et après (équipe Dev) | [réglages du back](back/src/main/resources/application.properties) |
| Après une création, l'API renvoie l'adresse du nouvel élément (en-tête `Location`) sans le préfixe `/api` ni le port : le relais du front ne transmet pas l'adresse d'origine ; le front ne se sert pas de cet en-tête | Relais qui transmet le préfixe et l'hôte d'origine (`X-Forwarded-Prefix`, `X-Forwarded-Host`), lus par Spring Boot (`server.forward-headers-strategy=framework`) | [chart](infra/helm/microcrm/README.md#limites-connues) |
| Base de SonarQube non sauvegardée : l'historique de la qualité serait perdu avec son disque | La sauvegarder comme les bases de MicroCRM | [rapport, recommandation 20](docs/04-rapport-performance.md#83-recommandations) |

## Contribuer

1. Ouvrir un ticket avec le formulaire **[Dev]** (code de l'application)
   ou **[Ops]** (infrastructure, CI, scripts).
2. Créer une branche courte depuis `main`, puis une PR qui cite le ticket
   (`Closes #n`) ; le modèle de PR liste les vérifications.
3. Messages de commit : type et portée en anglais, description en
   français, par exemple `fix(front): corrige l'affichage des personnes`.
   La portée est obligatoire pour `feat` et `fix` : elle décide si une
   version est créée (voir [Versions et publication](#versions-et-publication)).
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
| [Documentation CI/CD complète](docs/03-documentation-ci-cd.md) | Tests, architecture (actuelle et cible AWS), sécurité, releases, retour arrière, sauvegardes, supervision |
| [Rapport de performance](docs/04-rapport-performance.md) | Mesures avant/après (DORA, tests, sécurité, charge), incidents, recommandations |
| [Chart Helm](infra/helm/microcrm/README.md) | Déploiement Kubernetes, environnements, sécurité, limites |
| [OpenTofu](infra/terraform/README.md) | Socle du cluster, comptes de déploiement, installation de la supervision et d'OpenBao |
| [OpenBao](infra/openbao/README.md) | Coffre-fort : installation, initialisation, déverrouillage du matin, sauvegarde |
| [Ansible](infra/ansible/README.md) | Configuration et durcissement du poste Ops |
| [Supervision](infra/monitoring/README.md) | Métriques, journaux, alertes, tableaux de bord, premiers gestes |
| [Démarrage de Minikube](infra/systemd/README.md) | Service systemd du cluster |

## Versions des outils

Vérifiées le 07/11/2026 (dernière version publiée et fin de support sur
[endoflife.date](https://endoflife.date)) :

| Outil | Version |
|---|---|
| Spring Boot / Java | 4.1.2 / 17 (image 17.0.21, correctif trimestriel d'octobre, en prod depuis v1.8.2) |
| Angular / Node.js | 22.2 (TypeScript 6.0, Vitest 5) / 24 |
| PostgreSQL | 18.6 |
| Kubernetes (Minikube 1.39.0) | 1.37.0 (correctif 1.37.2 disponible) |
| Helm / kubectl (jobs du runner local) | 4.3.1 / 1.37.2 |
| ZAP (test d'intrusion) | 2.17.0 |
| OpenTofu / fournisseurs Kubernetes et Helm | 1.13.9 (poste et CI) / 3.4.0 et 3.3.0 |
| Ansible (ansible-core / ansible-lint / community.general) | 2.21 (2.21.6 dans la CI) / 26.10.1 / 14.0.0 |
| metrics-server / node_exporter | 0.9.1 / 1.12.1 |
| ARC (runner local) | 0.15.1, runner 2.338.2 |
| SonarQube Community Build | 26.10 |
| Trivy / hadolint / gitleaks / ShellCheck | 0.76.2 / 2.15.1 / 8.30.1 / 0.11.0 |
| Grafana / chart victoria-metrics-k8s-stack | 13.2.5 (dernière 13.2 ; 13.3.0 sortie) / 0.97.1 |
| k6 (tests de charge) | 2.3.0 |

Angular est passé de 17 (plus maintenu) à 22 le 08/11, une version
majeure à la fois ([audit, R4](docs/01-veille-audit-recommandations.md#r4-remettre-le-socle-applicatif-sous-maintenance),
ticket #113) : `.trivyignore` ne contient plus aucune exception.
