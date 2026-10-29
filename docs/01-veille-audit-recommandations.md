# Veille, audit et recommandations — MicroCRM

| Élément   | Valeur                                           |
| --------- | ------------------------------------------------ |
| Projet    | Démarche DevOps pour l'application MicroCRM      |
| Client    | Orion (destinataire : Maria, CTO)                |
| Auteur    | Yohan Bouchet                                    |
| Version   | 1.0 (à valider)           |
| Date      | 29/10/2026                                       |

## 1. Introduction

### 1.1 Objectifs

Ce document donne à la direction technique d'Orion une vision objective de
la façon dont MicroCRM est aujourd'hui développé, testé, livré et exploité,
et propose une feuille de route pour y installer une démarche DevOps. Il
répond à trois questions :

1. **Quelles technologies retenir ?** Rapport de veille (section 2).
2. **Où en est-on ?** Audit des processus actuels, chiffré (section 3).
3. **Que faire, et dans quel ordre ?** Recommandations (section 4) et
   prochaines étapes (section 5).

### 1.2 Rappel du contexte

Orion développe **MicroCRM**, une application de gestion de la relation
client qui relie des personnes à des organisations : un front Angular et une
API Spring Boot, réunis dans un même dépôt.

Deux équipes travaillent sur l'application :

- **Dev** (4 personnes, responsable : Roubina) : à l'aise en TypeScript,
  Angular et Docker, débutante en Java, Spring et Gradle ;
- **Ops** (2 personnes, responsable : Nico) : à l'aise en Bash, Ansible,
  Debian et Docker, de niveau moyen en PostgreSQL.

Le processus actuel est en grande partie manuel : la version est remise aux
Ops, qui la scannent avec Trivy puis la déploient à la main avec Docker. Des
failles de sécurité ont **retardé le premier déploiement de démonstration**.
Les deux équipes demandent davantage d'automatisation : analyse statique du
code pour les Dev, contrôles de sécurité en amont et registre d'images
interne pour les Ops.

## 2. Rapport de veille

### 2.1 Méthodologie

La veille ne compare que les briques où un choix réel se pose. Chaque
comparaison part d'un **besoin constaté** dans l'audit (section 3) ou dans les
sondages des équipes, puis évalue deux solutions selon les mêmes critères :

1. **Réponse au besoin** d'Orion ;
2. **Coût** : gratuit pour un dépôt public et une exécution locale ;
3. **Maturité et maintenance** : dernière version publiée, date de fin de
   support, projet actif ;
4. **Sécurité** : incidents connus, licence, exposition ;
5. **Compétences des équipes** : outils déjà maîtrisés (sondages).

Sources : documentation officielle des éditeurs, pages des versions publiées
sur GitHub et endoflife.date, consultées entre le 19 et le 29/10/2026. Les
outils de travail sont ceux décrits dans la méthodologie de l'audit (3.2).

### 2.2 Technologies évaluées

| Brique | Technologie | Catégorie | Fonctionnalités clés | Cas d'usage chez Orion | Référence (29/10/2026) |
| --- | --- | --- | --- | --- | --- |
| CI/CD | GitHub Actions | Orchestrateur de pipelines | Workflows en YAML, déclenchement sur push et PR, marketplace d'actions | Tester, analyser, construire et livrer MicroCRM | Gratuit pour un dépôt public |
| Runner | Actions Runner Controller (ARC) | Exécuteur de tâches dans Kubernetes | Runners jetables (un par tâche), mise à l'échelle automatique jusqu'à zéro | Exécuter le pipeline en local, au plus près de Minikube et de SonarQube | `gha-runner-scale-set` 0.15.1 (23/10/2026) |
| Qualité du code | SonarQube Community Build | Analyse statique (SAST) | Notes de qualité, couverture, duplication, Quality Gate | Bloquer le code de mauvaise qualité, mesurer la couverture | 26.10 (conteneur officiel) |
| Scan des images | Trivy | Scanner de failles | Images, dépendances, configuration (IaC), secrets, SBOM | Bloquer une image vulnérable avant sa publication | v0.76.1 (21/10/2026), Apache-2.0 |
| Registre d'images | GitHub Container Registry (GHCR) ou Harbor | Registre d'images OCI | Stockage versionné des images, droits d'accès | Livrer des images traçables aux Ops | Choix en phase 3 |
| Orchestration | Kubernetes (Minikube) | Orchestrateur de conteneurs | Redémarrage automatique, sondes de santé, mise à jour progressive et retour arrière | Déployer MicroCRM sans intervention manuelle | 1.37, supporté jusqu'au 28/10/2027 |
| Supervision | ELK (Elasticsearch, Logstash, Kibana) | Centralisation des journaux et tableaux de bord | Recherche dans les journaux, tableaux de bord, alertes | Suivre la disponibilité, les erreurs et les indicateurs DORA | Elastic 8.19 supporté jusqu'au 15/07/2027 ; 9.5 actuelle |
| Base de données | PostgreSQL | Base relationnelle | Persistance, transactions, sauvegardes | Conserver les données de MicroCRM | 18, supportée jusqu'au 14/11/2030 |

### 2.3 Matrices comparatives

#### 2.3.1 Plateforme CI/CD : GitHub Actions contre GitLab CI

| Critère | GitHub Actions | GitLab CI (GitLab.com Free) |
| --- | --- | --- |
| Coût | Gratuit pour un dépôt public, runners auto-hébergés compris | 400 minutes de calcul par mois sur les runners partagés |
| Sécurité intégrée | Dependabot et analyse CodeQL gratuits pour un dépôt public | Rapports SAST et secrets en JSON ; analyse des dépendances réservée à l'offre Ultimate |
| Indicateurs DORA | À calculer soi-même | Natifs, mais réservés à l'offre Ultimate |
| Point d'attention | Facturation à la minute des runners auto-hébergés annoncée en 12/2025 pour les dépôts privés, puis reportée | Modèles Terraform dépréciés (licence BSL) |

**Choix : GitHub Actions**, validé avec le mentor. Le dépôt public y reçoit
gratuitement les fonctions de sécurité qui seraient payantes sur GitLab.

#### 2.3.2 Runner : ARC auto-hébergé contre runner hébergé par GitHub

| Critère | ARC dans Minikube | Runner hébergé par GitHub |
| --- | --- | --- |
| Accès à l'infrastructure locale | Oui : il tourne dans le cluster | Non : il ne voit ni Minikube ni SonarQube |
| Isolation | Un runner jetable par tâche, détruit ensuite | Machine virtuelle neuve par tâche |
| Coût | Gratuit, mais consomme la machine locale | Gratuit pour un dépôt public |
| Point d'attention | À protéger : un dépôt public ne doit pas lancer de code de PR externe sur ce runner | Aucun accès aux secrets locaux |

**Choix : ARC**, imposé par l'exécution 100 % locale. Runner jetable et limité
aux branches protégées.

#### 2.3.3 Qualité du code : SonarQube Community Build contre CodeQL

| Critère | SonarQube Community Build | CodeQL (GitHub) |
| --- | --- | --- |
| Qualité et maintenabilité | Oui : notes, dette, duplication | Non |
| Couverture des tests | Oui (rapports JaCoCo et lcov) | Non |
| Quality Gate bloquant | Oui | Non |
| Détection des injections (SQL, XSS) | Non (« Limited security analysis ») | Oui |
| Hébergement | Local, en conteneur | Résultats publiés sur GitHub ; gratuit pour un dépôt public |

**Choix : SonarQube Community Build**, demandé par les Dev (analyse statique)
et seul à fournir le Quality Gate et la couverture. CodeQL est une option
**complémentaire** à étudier en phase 3.

#### 2.3.4 Scan des images : Trivy contre Grype

| Critère | Trivy | Grype (Anchore) |
| --- | --- | --- |
| Périmètre | Failles, configuration, secrets, SBOM | Failles (SBOM via l'outil Syft) |
| Version et licence | v0.76.1 (21/10/2026), Apache-2.0 | v0.121.0 (19/10/2026), Apache-2.0 |
| Compétences | Déjà utilisé par les Ops (sondage) | Inconnu des équipes |
| Sécurité | **Compromis en mars 2026** (CVE-2026-33634) : version 0.69.4 et actions GitHub piégées, qui volaient les secrets des pipelines | Pas d'incident relevé |

**Choix : Trivy**, déjà maîtrisé par les Ops. L'incident de mars 2026 impose
une règle : **version figée par empreinte (digest ou SHA de commit)**, jamais
d'étiquette mobile comme `latest`. Les versions utilisées pour l'audit
(0.75.0 et 0.76.1) sont postérieures à l'incident.

#### 2.3.5 Registre d'images : GHCR contre Harbor

| Critère | GHCR | Harbor |
| --- | --- | --- |
| Hébergement | Service GitHub, externe | Auto-hébergé : registre **interne**, comme le demandent les Ops |
| Coût | Gratuit pour les images publiques | Gratuit (Apache-2.0), mais au minimum 2 CPU, 4 Go de RAM et 40 Go de disque |
| Sécurité | Droits liés au dépôt, jeton du pipeline | Scan Trivy intégré, droits par projet, réplication |
| Exploitation | Rien à maintenir | Un service de plus à mettre à jour et sauvegarder |
| Version | — | v2.14.6 (23/10/2026) |

**Décision reportée à la phase 3**, en fonction des ressources de la machine
locale.

#### 2.3.6 Orchestration : Kubernetes contre Docker Compose

| Critère | Kubernetes (Minikube) | Docker Compose |
| --- | --- | --- |
| Résilience | Redémarre les conteneurs, sondes de santé | Redémarrage simple, une seule machine |
| Déploiement | Mise à jour progressive et retour arrière intégrés | Arrêt puis relance |
| Complexité | Plus élevée (nouvelle compétence) | Faible, Docker déjà maîtrisé par les Ops |
| Point d'attention | Le module ingress-nginx de Minikube n'est plus maintenu depuis mars 2026 | — |

**Choix : Kubernetes**, qui automatise ce que les Ops font aujourd'hui à la
main. Docker Compose reste utilisé pour les outils autour (SonarQube).

#### 2.3.7 Supervision : ELK contre Prometheus et Grafana

| Critère | ELK | Prometheus + Grafana |
| --- | --- | --- |
| Donnée principale | Journaux (texte, événements) | Métriques (nombres dans le temps) |
| Licences | ELv2, SSPL ou AGPLv3 au choix (AGPLv3 depuis 09/2024) | Apache-2.0 (Prometheus), AGPL-3.0 (Grafana) |
| Alertes gratuites | Limitées dans l'offre gratuite (types de connecteurs) | Oui, dans Grafana |
| Version | Elastic 9.5 | Prometheus v3.15.1, Grafana v13.3.0 |

**Choix : ELK**, attendu par le projet. Il répond au besoin le plus urgent
de l'audit : des journaux aujourd'hui en texte libre et non centralisés.

#### 2.3.8 Base de données : PostgreSQL contre HSQLDB

| Critère | PostgreSQL 18 | HSQLDB (actuel) |
| --- | --- | --- |
| Persistance | Oui, sur disque | Mode mémoire utilisé : données perdues à chaque redémarrage (un mode fichier existe) |
| Usage visé | Production | Développement et tests |
| Support | Jusqu'au 14/11/2030 | — |
| Compétences | Connu des Ops (niveau moyen) | — |
| Mutualisation | Même image durcie que la base de SonarQube | — |

**Choix : PostgreSQL 18**, avec l'image durcie du projet (sans gosu, sans
root).

## 3. Audit

### 3.1 Objectifs

L'audit dresse l'état des lieux de MicroCRM et de la façon dont l'application
est aujourd'hui développée, testée, livrée et exploitée. Il sert de **point de
départ mesuré** : chaque gain annoncé plus tard (rapport de performance) sera
comparé aux chiffres relevés ici.

### 3.2 Méthodologie

L'audit croise trois sources :

1. **Les sondages internes** des équipes Dev (4 personnes) et Ops
   (2 personnes) : compétences, outils, processus actuels, attentes.
2. **La lecture du code et de la configuration** du dépôt d'origine
   (commit `4298760`) : `Dockerfile`, `.gitlab-ci.yml`, `build.gradle`,
   `package.json`, configuration Spring et Angular.
3. **Des mesures outillées**, réalisées les 27 et 28/10/2026 sur ce même
   commit, sans aucune modification de l'application :

| Mesure                        | Outil                                   |
| ----------------------------- | --------------------------------------- |
| Durée du pipeline d'origine   | gitlab-ci-local 4.77.0 (exécution locale) |
| Qualité du code               | SonarQube Community Build 26.10         |
| Failles des images Docker     | Trivy                                   |
| Failles des dépendances front | npm audit                               |
| Bonnes pratiques Dockerfile   | hadolint                                |
| Alertes de dépendances        | GitHub Dependabot                       |
| Fins de support               | endoflife.date                          |

Résultats chiffrés et captures : [docs/mesures-avant/](mesures-avant/README.md).

Outils : trivy, hadolint, SonarQube, npm audit et gitlab-ci-local pour les
mesures ; documentation officielle des éditeurs pour la veille ; assistant IA
(Claude, Anthropic) pour la rédaction et la recherche, chaque fait et chaque
chiffre étant vérifié par l'auteur.

### 3.3 Processus audités

#### 3.3.1 Gestion du code et des versions

- **Description** : un dépôt unique (monorepo) contient le front Angular et le
  back Spring Boot. La version de l'application est figée à
  `0.0.1-SNAPSHOT`.
- **Forces** : un seul dépôt, simple à cloner et à construire ; les outils de
  construction sont embarqués (Gradle Wrapper, `package-lock.json`).
- **Faiblesses** : aucune stratégie de branches ni de relecture documentée ;
  aucune version publiée (pas de numérotation sémantique, pas de tag) ; un
  dossier de compilation (`back/bin/`) est versionné ; la dépendance
  `spring-boot-starter-data-jpa` est déclarée deux fois.
- **Risques** : impossible de savoir quelle version tourne en production, ni de
  revenir proprement à la précédente en cas d'incident.

#### 3.3.2 Intégration continue

- **Description** : un pipeline de 2 étapes (`test`, `build`) et 4 tâches.
  Mesuré à froid : **4,67 min**, 4 tâches sur 4 réussies.
- **Forces** : le pipeline existe, il est fonctionnel et lance déjà les tests
  front et back à chaque modification.
- **Faiblesses** :
  - images de construction non figées (`node`, `gradle:jdk17`,
    `cypress/browsers:latest`) : le résultat peut changer d'un jour à l'autre ;
  - aucun cache : les dépendances npm et Gradle sont retéléchargées à chaque
    tâche, et le téléchargement de l'image Cypress prend à lui seul
    2,61 min sur les 3,43 min de la tâche `test-front` ;
  - les tests sont rejoués dans l'étape `build` (`./gradlew build`) ;
  - aucun rapport (tests, couverture), aucune analyse de code, aucun scan de
    sécurité, aucune image construite ni publiée.
- **Risques** : la CI valide seulement « ça compile » ; les défauts et les
  failles arrivent jusqu'aux Ops, qui les découvrent à la main.

#### 3.3.3 Tests et qualité du code

- **Description** : 2 tests back (démarrage du contexte, dépôt `Person`) et
  8 tests front (6 fichiers). Analyse SonarQube du 28/10/2026 sur 960 lignes
  de code (Java 226, TypeScript 332, HTML 401).
- **Forces** : maintenabilité notée **A**, duplication faible (2,5 %), dette
  technique estimée à 49 min seulement ; tous les tests existants passent.
- **Faiblesses** :
  - couverture des tests : **0 %** mesurée (aucun outil de couverture
    branché : ni JaCoCo côté back, ni rapport lcov côté front) ;
  - **37 problèmes** relevés : fiabilité notée **D** (33 problèmes, dont
    12 appels asynchrones dont l'échec n'est jamais traité en TypeScript et
    2 risques de `NullPointerException` en Java), sécurité notée **C**
    (4 problèmes) ;
  - la dette technique de 49 min est trompeuse : SonarQube l'obtient en
    additionnant le temps de correction estimé par règle (2 à 5 min) des
    seuls 11 problèmes de type « code smell ». Le temps estimé pour corriger
    les bugs (117 min) et les vulnérabilités (725 min) n'y est pas compté ;
  - accessibilité : 14 problèmes relevés dans les gabarits HTML ;
  - le Quality Gate par défaut (« Sonar way ») ne juge que le code nouveau :
    la première analyse passe donc **sans aucune condition vérifiée**.
- **Risques** : une régression peut être livrée sans qu'aucun test ne la
  détecte ; l'équipe Dev, débutante en Java, Spring et JUnit d'après le
  sondage, manque de garde-fous sur la partie back.

#### 3.3.4 Sécurité

- **Description** : aucun contrôle de sécurité automatisé. Les Ops scannent
  les images à la main avec Trivy, après réception d'une version.
- **Forces** : les Ops connaissent déjà Trivy ; les dépendances sont
  verrouillées (`package-lock.json`), ce qui rend les scans reproductibles.
- **Faiblesses** :

| Constat                              | Mesure (avant)                         |
| ------------------------------------ | -------------------------------------- |
| Image back (et image tout-en-un)     | 95 failles : 8 critiques, 33 hautes    |
| Image front                          | 10 failles : 2 hautes                  |
| Dépendances npm du front             | 91 failles : 5 critiques, 52 hautes    |
| Alertes Dependabot ouvertes          | 165                                    |
| Dockerfile (hadolint)                | 9 remarques : 6 avertissements         |

  - les conteneurs tournent en **root** ; l'image de base `alpine:3.19` n'est
    plus maintenue depuis le 01/11/2025 ;
  - Spring Boot 3.2 n'est plus maintenu depuis le 31/12/2024, Angular 17
    depuis le 15/05/2025 ;
  - l'API REST est **sans authentification** (création, modification et
    suppression ouvertes) et le CORS accepte toutes les origines
    (`allowedOrigins("*")`, relevé 3 fois par SonarQube, OWASP A05) ;
  - l'application manipule des données personnelles (noms, e-mails) : le RGPD
    s'applique, sauvegardes comprises.
- **Risques** : c'est le risque majeur. Les failles ont **déjà retardé le
  premier déploiement de démonstration** (sondage Dev) ; une faille critique
  exploitée exposerait les données des clients.

#### 3.3.5 Construction et livraison des images

- **Description** : un `Dockerfile` unique à 3 cibles : `front` (Caddy),
  `back` (Java) et `standalone` (les deux, lancés par supervisord).
- **Forces** : construction en plusieurs étapes (multi-stage) déjà en place ;
  les 3 images répondent aux besoins exprimés par l'équipe Dev.
- **Faiblesses** : le back est compilé en Java 17 mais exécuté en Java 21 ;
  l'image back déclare le port 4200 alors que l'application écoute sur 8080 ;
  aucune sonde de santé (`HEALTHCHECK`) ; l'image `standalone` recopie tout le
  système de fichiers des deux autres ; aucun registre d'images : les Ops
  souhaitent un registre interne plutôt que Docker Hub.
- **Risques** : des images lourdes, différentes d'une construction à l'autre
  et impossibles à tracer jusqu'au code source.

#### 3.3.6 Déploiement et exploitation

- **Description** : déploiement manuel par les Ops (réception de la version,
  scan Trivy, lancement à la main avec Docker).
- **Forces** : les Ops maîtrisent Bash, Ansible, Debian et Docker (sondage) :
  une base solide pour automatiser.
- **Faiblesses** :
  - base de données **HSQLDB en mémoire** : toutes les données sont perdues à
    chaque redémarrage ;
  - adresse de l'API écrite en dur dans le front (`http://localhost:8080`) :
    bloquant dès que front et back ne tournent plus sur le même poste ;
  - aucun point de santé ni métrique (pas de Spring Boot Actuator), journaux
    en texte libre, aucune supervision ni alerte ;
  - aucune sauvegarde, aucune procédure de retour arrière.
- **Risques** : perte de données, indisponibilité non détectée, temps de
  rétablissement inconnu.

#### 3.3.7 Communication et collaboration

- **Description** : échanges Dev/Ops par e-mail et de vive voix ; la version
  est « remise » aux Ops, qui la contrôlent ensuite.
- **Forces** : des équipes petites, proches, et demandeuses d'automatisation
  (analyse statique côté Dev, scans en amont côté Ops).
- **Faiblesses** : aucune trace partagée des décisions ni des problèmes ; les
  compétences sont cloisonnées (Dev à l'aise en front, débutants en Java ;
  Ops à l'aise en système, moyens en PostgreSQL).
- **Risques** : retours tardifs, responsabilité floue en cas d'incident,
  dépendance à quelques personnes.

### 3.4 Synthèse

| Forces                                      | Faiblesses                                   |
| ------------------------------------------- | -------------------------------------------- |
| Application petite et lisible (960 lignes)  | Tests quasi absents, couverture 0 %          |
| Maintenabilité notée A                      | 95 failles dans l'image back, 91 côté npm    |
| Pipeline existant et fonctionnel            | Socle hors maintenance (Spring Boot 3.2, Angular 17, Alpine 3.19) |
| Ops compétents (Bash, Ansible, Docker, Trivy) | Déploiement manuel, base en mémoire, aucune supervision |

| Opportunités                                | Menaces                                      |
| ------------------------------------------- | -------------------------------------------- |
| Équipes demandeuses d'analyse statique et de scans en amont | Exploitation d'une faille critique, fuite de données personnelles (RGPD) |
| Outils gratuits et matures (SonarQube, Trivy, Kubernetes) | Livraisons retardées par les failles, comme pour la démo |
| Montée de version vers des socles maintenus | Perte de données à chaque redémarrage        |

**Priorités issues de l'audit** : (1) arrêter l'arrivée de failles en
production en automatisant les contrôles dans la CI ; (2) fiabiliser le
pipeline (images figées, cache, rapports, Quality Gate réel) ; (3) livrer des
images versionnées dans un registre ; (4) rendre l'exploitation mesurable
(base persistante, santé, journaux, supervision).

## 4. Recommandations

### 4.1 Objectifs

Les recommandations traitent les 4 priorités de l'audit (3.4). Chacune vise un
résultat **mesurable**, comparé aux mesures de départ
([docs/mesures-avant/](mesures-avant/README.md)) :

| Objectif | Mesure avant | Cible |
| --- | --- | --- |
| Aucune faille connue livrée sans décision | 95 failles dans l'image back (8 critiques) | 0 faille critique ou haute corrigeable dans une image publiée |
| Qualité contrôlée à chaque modification | Quality Gate sans condition | Quality Gate bloquant sur chaque PR |
| Tests mesurés | Couverture 0 % | Couverture mesurée et publiée à chaque PR |
| Pipeline plus rapide malgré plus de contrôles | 4,67 min (cache froid) | Durée suivie à chaque exécution ; gain mesuré dans le rapport de performance |
| Livraison traçable | Aucune image publiée, version `0.0.1-SNAPSHOT` | Chaque image liée à une version et à un commit |
| Déploiement sans action manuelle | Déploiement manuel par les Ops | Déploiement et retour arrière automatisés |

Les choix s'appuient sur des référentiels reconnus du métier : **OWASP
Top 10:2025** (application), **OWASP Top 10 CI/CD Security Risks**
(pipeline), **Pod Security Standards** de Kubernetes (cluster) et les fins de
support publiées sur **endoflife.date** (maintenance).

### 4.2 Recommandations

#### R1. Fiabiliser et accélérer le pipeline CI

- **Description** : réécrire le pipeline en GitHub Actions sur le runner ARC :
  images d'outils figées par empreinte, cache des dépendances npm et Gradle,
  tests lancés une seule fois, rapports de tests (JUnit) et de couverture
  (JaCoCo côté back, lcov côté front) conservés.
- **Raisonnement** : l'audit montre des téléchargements répétés, des tests
  rejoués et aucun rapport (3.3.2) ; une étiquette mobile comme `latest` est
  la porte d'entrée de l'attaque subie par Trivy en mars 2026 (2.3.4).
- **Implémentation** : phase 3 ; actions GitHub figées par SHA de commit ;
  runner jetable, limité aux branches protégées (risque OWASP CICD-SEC-4,
  « Poisoned Pipeline Execution », sur un dépôt public).
- **Impacts** : pipeline reproductible et plus court ; résultats de tests
  visibles par les Dev dans chaque PR.

#### R2. Intégrer les contrôles qualité et sécurité dans la CI

- **Description** : bloquer la fusion d'une PR si l'un des contrôles échoue :
  Quality Gate SonarQube, Trivy (dépendances et images), hadolint
  (Dockerfiles), gitleaks (secrets) ; Dependabot pour les mises à jour.
- **Raisonnement** : c'est la demande des deux équipes (analyse statique côté
  Dev, scans en amont côté Ops) et la réponse au risque majeur de l'audit
  (3.3.4). Le Quality Gate par défaut ne contrôlant que le code nouveau, des
  conditions sur l'ensemble du code sont à définir.
- **Implémentation** : phase 3. Le runner doit joindre SonarQube : soit
  SonarQube rejoint le cluster (chart Helm officiel de SonarSource), soit il
  reste en conteneur et devient joignable depuis Minikube ; choix à faire au
  début de la phase 3. Analyse CodeQL à étudier en complément (2.3.3).
- **Impacts** : les failles sont arrêtées avant la livraison, et non plus
  découvertes à la main par les Ops.

#### R3. Construire des images durcies, versionnées et publiées

- **Description** : corriger le `Dockerfile` (versions figées et maintenues,
  utilisateur non root, sonde de santé, bon port exposé, image `standalone`
  sans copie du système de fichiers entier) ; numérotation sémantique (semver)
  et tags Git ; publication dans un registre.
- **Raisonnement** : images lourdes, en root, sur une base Alpine non
  maintenue et impossibles à tracer (3.3.5).
- **Implémentation** : phase 3 ; registre GHCR ou Harbor à décider (2.3.5) ;
  image PostgreSQL durcie déjà réalisée (86 failles → 0, sans root).
- **Impacts** : chaque version déployée est identifiable, rejouable et
  contrôlée.

#### R4. Remettre le socle applicatif sous maintenance

- **Description** : monter Spring Boot 3.2 vers une version maintenue
  (4.1, maintenue jusqu'au 31/07/2027) et Angular 17 vers une version
  maintenue (22, jusqu'au 30/06/2028), puis maintenir ces versions grâce à
  Dependabot.
- **Raisonnement** : sans maintenance, plus aucun correctif de sécurité n'est
  publié (3.3.4), et les correctifs des dépendances (91 failles npm côté
  front) visent en priorité les versions maintenues.
- **Implémentation** : à planifier avec l'équipe Dev, à l'aise en Angular mais
  débutante en Spring ; chaque montée de version passe par une PR et la CI de
  R1 et R2.
- **Impacts** : moins de failles à la source ; effort de développement à
  prévoir.

#### R5. Automatiser le déploiement sur Kubernetes

- **Description** : déployer MicroCRM sur Kubernetes avec Helm, avec une base
  PostgreSQL 18 persistante, des sondes de santé (Spring Boot Actuator), une
  adresse d'API configurable, une mise à jour progressive et un retour arrière
  en une commande ; sauvegarde régulière de la base.
- **Raisonnement** : déploiement manuel, données perdues à chaque redémarrage,
  aucune procédure de retour arrière (3.3.6).
- **Implémentation** : phases 4 et 5 ; environnements séparés par espaces de
  noms ; conteneurs non root conformes aux Pod Security Standards ;
  Headlamp pour visualiser le cluster.
- **Impacts** : livraisons fréquentes et sans risque ; temps de
  rétablissement mesurable.

#### R6. Rendre l'exploitation observable

- **Description** : journaux structurés, centralisés dans ELK ; tableaux de
  bord et alertes sur la disponibilité, les performances et la sécurité ;
  indicateurs DORA (fréquence de déploiement, délai de mise en production,
  taux d'échec, temps de rétablissement).
- **Raisonnement** : aucune supervision ni alerte aujourd'hui (3.3.6).
- **Implémentation** : phase 6 ; ELK placé hors du cluster supervisé, pour
  rester disponible en cas d'incident sur celui-ci (répartition à confirmer).
- **Impacts** : incidents détectés avant les utilisateurs ; progrès de la
  démarche DevOps mesurés.

#### R7. Outiller la collaboration Dev/Ops

- **Description** : toute modification passe par une PR relue ; messages de
  commit normalisés (Conventional Commits) ; documentation versionnée dans le
  dépôt ; décisions et incidents tracés dans des tickets.
- **Raisonnement** : échanges par e-mail et de vive voix, sans trace partagée
  (3.3.7).
- **Implémentation** : règles détaillées dans le document de normalisation
  (`02-normalisation-plan-ci.md`).
- **Impacts** : responsabilités claires ; connaissances partagées entre Dev et
  Ops.

## 5. Conclusion

### 5.1 Synthèse

MicroCRM est une petite application, lisible et bien structurée, mais sa
chaîne de production ne protège ni la qualité ni la sécurité : couverture des
tests nulle, 95 failles dans l'image back dont 8 critiques, socle hors
maintenance, déploiement manuel et aucune supervision. Les deux équipes
disposent pourtant des compétences de base (Docker, Bash, Ansible, Trivy) et
demandent elles-mêmes l'automatisation.

Les technologies retenues sont gratuites, maintenues et adaptées à ces
compétences : GitHub Actions avec un runner local jetable, SonarQube, Trivy,
Kubernetes, PostgreSQL et ELK. Les 7 recommandations installent d'abord des
**contrôles automatiques** (R1 à R3), puis le **déploiement automatisé**
(R5) et la **supervision** (R6), en s'appuyant sur des référentiels reconnus
(OWASP, Pod Security Standards, endoflife.date).

### 5.2 Prochaines étapes

| Étape | Contenu | Recommandations |
| --- | --- | --- |
| 1. Normalisation | Règles communes (code, branches, revue, tests, sécurité) et plan de mise en œuvre de la CI | R7 |
| 2. Intégration continue | Pipeline GitHub Actions avec contrôles bloquants et images publiées | R1, R2, R3 |
| 3. Déploiement continu | Infrastructure en code, déploiement Kubernetes, base persistante, sauvegardes | R5 |
| 4. Supervision | ELK, alertes, indicateurs DORA | R6 |
| 5. Bilan | Rapport de performance : comparaison avec les mesures de départ | — |

La montée de version du socle (R4) est à planifier avec l'équipe Dev, en
parallèle des étapes 2 et 3. Le calendrier détaillé, les responsables et les
risques figurent dans le plan de mise en œuvre
(`02-normalisation-plan-ci.md`).
