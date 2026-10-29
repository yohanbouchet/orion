# Veille, audit et recommandations — MicroCRM

| Élément   | Valeur                                           |
| --------- | ------------------------------------------------ |
| Projet    | Démarche DevOps pour l'application MicroCRM      |
| Client    | Orion (destinataire : Maria, CTO)                |
| Auteur    | Yohan Bouchet                                    |
| Version   | 0.1 (brouillon : partie audit rédigée)           |
| Date      | 29/10/2026                                       |

## 1. Introduction

### 1.1 Objectifs

*À rédiger.*

### 1.2 Rappel du contexte

*À rédiger.*

## 2. Rapport de veille

### 2.1 Méthodologie

*À rédiger.*

### 2.2 Technologies évaluées

*À rédiger.*

### 2.3 Matrices comparatives

*À rédiger.*

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

*À rédiger.*

### 4.2 Recommandations

*À rédiger.*

## 5. Conclusion

### 5.1 Synthèse

*À rédiger.*

### 5.2 Prochaines étapes

*À rédiger.*
