# Scripts d'automatisation

Ce dossier regroupe les scripts qui installent, testent, notifient et
déploient (ticket #56). La CI de GitHub Actions
([`ci.yml`](../.github/workflows/ci.yml)) les appelle, et on peut lancer
**exactement les mêmes commandes en local** : ce qui marche sur un poste
marche dans la CI, et inversement.

| Script | But | Appelé par |
|---|---|---|
| [`install-deps.sh`](#install-depssh) | Installer (front) ou vérifier (back) les dépendances | jobs `test-front`, `test-back` |
| [`run-tests.sh`](#run-testssh) | Lancer les tests et vérifier le rapport de couverture | jobs `test-front`, `test-back` |
| [`notify.py`](#notifypy) | Signaler par ticket et e-mail une CI en échec sur `main` | job `notify` |
| [`lib/common.sh`](#libcommonsh) | Fonctions partagées : journal, arrêt, outils requis | les scripts Bash |
| [`deploy.sh`](#deploysh) | Déployer MicroCRM, le vérifier, revenir en arrière | l'opérateur ; job de déploiement (à venir) |
| [`deploy-sonarqube.sh`](#deploy-sonarqubesh) | Déployer SonarQube dans le cluster Minikube | l'opérateur, à la main |

À venir : la sauvegarde et la restauration de la base (`backup.sh`).

## Règles communes

Tous les scripts Bash suivent les mêmes règles :

- **`set -Eeuo pipefail`** : arrêt à la première commande en échec, à
  l'usage d'une variable inconnue ou à une erreur dans un tube (`|`).
- **Lançables de partout** : les chemins sont calculés depuis
  l'emplacement du script, pas depuis le dossier courant.
- **Journal horodaté (UTC) sur la sortie d'erreur** (stderr), au même
  format pour tous les scripts, `notify.py` compris :

  ```text
  2026-11-01T15:21:55Z INFO  install-deps.sh: front dependencies ready
  ```

- **Erreurs expliquées** : chaque arrêt prévu dit ce qui s'est passé
  **et comment corriger** (`fix: …`).
- **Codes de sortie** :

  | Code | Sens |
  |---|---|
  | 0 | Réussite |
  | 1 | Échec (tests rouges, fichier manquant, appel réseau en échec…) |
  | 2 | Mauvais usage (paramètre absent ou inconnu) : la syntaxe est rappelée |
  | 127 | Outil requis absent (`node`, `java`…) |

- **Messages, noms et paramètres en anglais**, commentaires en français.

## install-deps.sh

**But** : préparer les dépendances aux **versions exactes** des fichiers
de verrouillage, sans rien laisser dériver.

```shell
scripts/install-deps.sh front   # ou : back
```

**Fonctionnement** :

- `front` : `npm ci --ignore-scripts` installe exactement
  `front/package-lock.json`. `--ignore-scripts` bloque les scripts
  d'installation des paquets, une voie d'attaque de la chaîne
  d'approvisionnement ; l'audit des failles est fait par Trivy dans la CI.
- `back` : Gradle résout les dépendances des tests et les compare à
  `back/gradle.lockfile`. Une version différente apparaît « FAILED »
  **sans** que Gradle échoue : c'est le script qui la détecte et s'arrête.

**Conditions d'exécution** : `node` et `npm` (front), `java` (back) ; le
fichier de verrouillage doit exister. Dans la CI : Node 24 et Java 17.

**Arrêts expliqués** :

| Cas | Code | Correction proposée |
|---|---|---|
| `package-lock.json` absent | 1 | `npm install` dans `front/`, puis commit du fichier |
| `gradle.lockfile` absent | 1 | `./gradlew dependencies --write-locks` dans `back/` |
| Dépendance back différente du verrou | 1 | si c'est voulu, `--write-locks` puis commit |

## run-tests.sh

**But** : lancer les tests **une seule fois**, puis vérifier que le
rapport de couverture lu par SonarQube existe.

```shell
scripts/run-tests.sh front   # ou : back
```

**Fonctionnement** :

- `front` : `ng test` (Karma, Chrome sans écran) sans surveillance des
  fichiers ; rapport `front/coverage/microcrm/lcov.info`.
- `back` : `./gradlew test` (JUnit) ; rapport JaCoCo
  `back/build/reports/jacoco/test/jacocoTestReport.xml`.
- Si les tests réussissent mais que le rapport est absent ou vide, le
  script s'arrête : sinon SonarQube afficherait 0 % de couverture sans
  que personne ne le remarque.

**Paramètre** : `KARMA_BROWSER` (front) ; par défaut `ChromeHeadless`,
avec le bac à sable (sandbox) de Chrome. La CI passe
`ChromeHeadlessNoSandbox`, réglage d'origine du projet, sur des machines
jetables.

**Conditions d'exécution** : dépendances installées avant
(`install-deps.sh`) ; Chrome ou Chromium pour le front (`CHROME_BIN` si
le navigateur n'est pas trouvé) ; `java` pour le back.

**Arrêts expliqués** : tests rouges (code 1, sortie des tests au-dessus) ;
`node_modules` absent (code 1, `fix: run scripts/install-deps.sh front`) ;
rapport absent (code 1, vérifier `karma.conf.js` ou `build.gradle`).

## notify.py

**But** : prévenir l'équipe quand la CI échoue sur `main`, sans service
de messagerie à configurer ni secret à stocker.

**Fonctionnement** (job `notify`, après tous les autres, même en échec) :

| Situation | Action sur le ticket « CI failing on main » |
|---|---|
| Échec, aucun ticket ouvert | Ouvert, **assigné** au propriétaire du dépôt avec une **mention** : GitHub envoie l'e-mail |
| Échec, ticket déjà ouvert | Commentaire « Still failing » (pas de doublon) |
| Retour au vert, ticket ouvert | Commentaire « Fixed by … » puis fermeture |
| Vert, aucun ticket | Rien |

Le résultat est aussi écrit dans le résumé de l'exécution GitHub Actions.

**Paramètres** (variables d'environnement, fournies par la CI) :
`NEEDS_JSON` (résultat des jobs), `SIMULATE_FAILURE`, `GITHUB_TOKEN`, et
les variables standard `GITHUB_*` de GitHub Actions.

**Conditions d'exécution** : Python 3.14, bibliothèque standard seule
(aucun paquet à installer). Il ne tourne que sur `main`, jamais sur une
PR. **Sécurité** : jeton temporaire du job, avec le seul droit
`issues: write`, limité à ce job.

**Codes** : 0 réussi ; 1 appel à l'API GitHub en échec ; 2 paramètre
manquant ou invalide.

### Exercice d'alerte

Pour vérifier que l'alerte arrive vraiment, sans rien casser :

1. **Actions** → **CI** → **Run workflow**, branche `main`, cocher
   **« Notification drill: report a simulated failure »**.
2. Attendu : ticket « CI failing on main » ouvert avec le job
   `simulated-failure (notification drill)`, et e-mail reçu.
   L'exécution reste **verte** : aucun job n'a réellement échoué.
3. Relancer **sans** cocher : le ticket reçoit « Fixed by … » et se ferme.

Ces lancements manuels ne publient aucune version. Exercice réussi le
01/11/2026 (ticket #61 : deux e-mails reçus, mention et assignation).

## deploy.sh

**But** : installer ou mettre à jour MicroCRM (chart
[`infra/helm/microcrm`](../infra/helm/microcrm/README.md)) dans un
environnement, **vérifier que l'application répond**, et revenir à la
version précédente si ce n'est pas le cas.

```shell
scripts/deploy.sh dev                     # version du chart (appVersion)
scripts/deploy.sh staging v1.1.0          # image publiée vX.Y.Z
scripts/deploy.sh dev sha-abc1234         # image d'un commit de main
scripts/deploy.sh rollback prod           # version précédente
scripts/deploy.sh rollback prod 3         # révision choisie (helm history)
```

**Fonctionnement** :

1. contrôle des paramètres : environnement `dev`, `staging` ou `prod`
   (c'est aussi le namespace) ; étiquette au format `vX.Y.Z` ou
   `sha-xxxxxxx` uniquement, ce qui empêche d'injecter un réglage Helm
   (`v1.2.3,front.replicas=9` est refusé) ;
2. le namespace doit exister et imposer le niveau Pod Security
   « restricted ». Le script ne le crée pas : c'est une étape
   d'installation, qui demande des droits sur tout le cluster ;
3. Secret `microcrm-db` : créé **une seule fois**, avec une valeur
   aléatoire (`openssl rand`) passée à kubectl par un tube, donc jamais
   visible dans la ligne de commande ni affichée ; jamais remplacé, car la
   base garde le mot de passe de sa création ;
4. `helm lint` avec les réglages de l'environnement ;
5. `helm upgrade --install --wait --rollback-on-failure` : si les pods ne
   sont pas prêts en 6 minutes, Helm remet lui-même la version précédente ;
   les anciens pods servent jusqu'au bout (`maxUnavailable: 0`) ;
6. **test de fumée** : depuis le pod du front, appel de `/api/persons`
   (chemin complet front → back → base), 3 essais ; en cas d'échec,
   `helm rollback`, puis arrêt en erreur.

`rollback` lance `helm rollback` (révision précédente ou choisie), puis
le même test de fumée.

**Paramètres** : `TAG` (facultatif) ; `REVISION` (facultatif, pour
`rollback`) ; `SMOKE_DELAY`, secondes entre deux essais du test de fumée
(5 par défaut, 0 dans les tests).

**Conditions d'exécution** : `helm` 4, `kubectl`, `openssl` ; accès au
cluster (contexte `orion` sur le poste, compte de service dans la CI) ;
namespace créé ([README du chart](../infra/helm/microcrm/README.md#installation)) ;
image PostgreSQL durcie chargée dans Minikube
([README racine](../README.md#déployer-sur-kubernetes)).

**Arrêts expliqués** :

| Cas | Code | Correction proposée |
|---|---|---|
| Environnement, étiquette ou révision invalide | 2 | syntaxe rappelée |
| `helm`, `kubectl` ou `openssl` absent | 127 | installer l'outil |
| Namespace absent ou pas « restricted » | 1 | le créer ou poser l'étiquette |
| Pods pas prêts à temps | 1 | version précédente gardée par Helm ; `kubectl -n ENV get pods` |
| Test de fumée en échec | 1 | version précédente remise ; journaux du back |

**Vérifié le 02/11/2026** dans le cluster `orion` : déploiements de
`dev`, 1re installation de `staging` (Secret créé, 16 s), image
inexistante (retour automatique après 6 min, aucune coupure), retour à
une révision choisie. Le 1er essai a montré que, dans le conteneur,
`localhost` désigne d'abord l'IPv6 (`::1`), où nginx n'écoute pas : le
test de fumée vise donc `127.0.0.1`.

## lib/common.sh

Fonctions partagées, **chargées** par les scripts Bash
(`source "$SCRIPT_DIR/lib/common.sh"`) ; lancé seul, le fichier refuse
de s'exécuter (code 1).

| Fonction | Rôle |
|---|---|
| `log NIVEAU message…` | Ligne de journal horodatée sur stderr |
| `die message…` | Journal `ERROR`, puis arrêt avec le code 1 |
| `die_with CODE message…` | Pareil, avec le code choisi |
| `require_cmd outil…` | Arrêt avec le code 127 si un outil est absent |

## deploy-sonarqube.sh

**But** : installer ou mettre à jour SonarQube et sa base PostgreSQL dans
le cluster Minikube, puis **vérifier l'empreinte** de l'image réellement
lancée.

```shell
scripts/deploy-sonarqube.sh
```

**Fonctionnement** (5 étapes affichées) : namespace, pare-feu entre pods
(NetworkPolicy), secrets aléatoires créés une seule fois, base ; image
téléchargée **par empreinte** puis chargée dans Minikube ; chart Helm à
version figée ; contrôle de l'empreinte ; fin.

**Paramètre** : `MINIKUBE_PROFILE` (défaut : `orion`). Aucun secret en
argument.

**Conditions d'exécution** : `docker`, `minikube`, `kubectl`, `helm`,
`openssl` ; cluster Minikube démarré
([service de démarrage automatique](../infra/systemd/README.md)).

Ce script est antérieur à `lib/common.sh` : il a son propre journal et
`set -euo pipefail`. Il sera aligné sur les règles communes en phase 5.

## Tests des scripts

Le job `script-tests` lance tous les tests à **chaque PR**, et le job
`shellcheck` relit les scripts Bash. Les mêmes contrôles, en local,
depuis la racine du dépôt :

```shell
# Tests Bash (bashunit 0.52.0, avec de faux outils : ni npm, ni Gradle, ni
# cluster)
bashunit scripts/tests

# Tests Python (pytest 9.2.0) dans un conteneur jetable : paquets installés
# depuis requirements.txt, empreintes SHA-256 vérifiées
docker run --rm -v "$PWD":/src:ro -w /src -e PYTHONDONTWRITEBYTECODE=1 \
  python:3.14-slim sh -c 'pip install -q --root-user-action=ignore \
  --require-hashes --only-binary :all: -r scripts/tests/requirements.txt \
  && python -m pytest -p no:cacheprovider scripts/tests'

# Analyse statique des scripts Bash (ShellCheck 0.11.0, réglages dans
# .shellcheckrc à la racine)
docker run --rm -v "$PWD":/src:ro -w /src koalaman/shellcheck:v0.11.0 \
  scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh
```

| Fichier de test | Outil | Ce qui est vérifié |
|---|---|---|
| `tests/common_test.sh` | bashunit | journal, codes de `die` / `die_with`, outils requis, garde contre l'exécution directe |
| `tests/install_deps_test.sh` | bashunit | usage, `package-lock.json` absent, commandes npm et Gradle, « FAILED » détecté |
| `tests/run_tests_test.sh` | bashunit | usage, dépendances absentes, Karma lancé une fois, `KARMA_BROWSER`, tests rouges, rapport absent |
| `tests/deploy_test.sh` | bashunit | usage, étiquette piégée, namespace absent ou non « restricted », Secret créé par un tube ou conservé, lint et options de Helm, échec de Helm, test de fumée raté → retour arrière, `rollback` |
| `tests/test_notify.py` | pytest | jobs en échec, exercice, ouverture / commentaire / fermeture, résumé, paramètres |

Les tests Bash remplacent `npm`, `java`, `gradlew`, `helm` ou `kubectl`
par des **doublures** (faux programmes placés en tête du `PATH`) : ils
vérifient la logique du script en quelques secondes. Les tests Python
remplacent l'API GitHub par un faux client : aucun ticket réel n'est créé.

Versions des outils de test : bashunit est téléchargé dans la CI avec
vérification de son empreinte SHA-256 ; pytest et ses dépendances sont
figés avec empreintes dans `tests/requirements.txt`, mis à jour par
Dependabot.
