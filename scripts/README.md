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
| [`dora.py`](#dorapy) | Mesurer les 5 indicateurs DORA de la prod (livraison et stabilité) | workflow `dora.yml` (chaque jour ouvré) ; l'opérateur |
| [`lib/common.sh`](#libcommonsh) | Fonctions partagées : journal, arrêt, outils requis | les scripts Bash |
| [`deploy.sh`](#deploysh) | Déployer MicroCRM, le vérifier, revenir en arrière | l'opérateur ; job de déploiement de la CI (`deploy.yml`) |
| [`zap-scan.sh`](#zap-scansh) | Test d'intrusion de `staging` avec ZAP (passif ou actif) | job `zap` de la CI (`zap.yml`) ; l'opérateur |
| [`load-test.sh`](#load-testsh) | Test de charge de `staging` avec k6 (6 profils) | job `load-test` de la CI (`load-test.yml`) ; l'opérateur |
| [`backup.sh`](#backupsh) | Sauvegarder, vérifier et restaurer la base | l'opérateur ; tâches planifiées installées par Ansible (sauvegarde au démarrage du poste et chaque jour, vérification chaque semaine) |
| [`backup-openbao.sh`](#backup-openbaosh) | Sauvegarder le coffre OpenBao (instantané Raft vérifié) | tâche planifiée installée par Ansible (chaque jour, 11 h 50) ; l'opérateur, avant une opération risquée |
| [`e2e.sh`](#e2esh) | Tests de bout en bout : MicroCRM jetable, parcours dans un vrai navigateur | job `e2e` de la CI ; l'opérateur |
| [`deploy-sonarqube.sh`](#deploy-sonarqubesh) | Déployer SonarQube dans le cluster Minikube | l'opérateur, à la main |

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

- `front` : `ng test --no-watch` (Vitest, depuis le 08/11) : les tests
  tournent dans Node avec jsdom, un navigateur simulé, sans Chrome ;
  rapport `front/coverage/microcrm/lcov.info`.
- `back` : `./gradlew test` (JUnit) ; rapport JaCoCo
  `back/build/reports/jacoco/test/jacocoTestReport.xml`.
- Si les tests réussissent mais que le rapport est absent ou vide, le
  script s'arrête : sinon SonarQube afficherait 0 % de couverture sans
  que personne ne le remarque.

**Paramètre** : aucun en dehors de `front` ou `back` (le réglage
`KARMA_BROWSER` a disparu avec Karma).

**Conditions d'exécution** : dépendances installées avant
(`install-deps.sh`) ; `node` et `npx` pour le front (aucun navigateur) ;
`java` pour le back.

**Arrêts expliqués** : tests rouges (code 1, sortie des tests au-dessus) ;
`node_modules` absent (code 1, `fix: run scripts/install-deps.sh front`) ;
rapport absent (code 1, vérifier les options `coverage` du constructeur
`unit-test` dans `front/angular.json`, ou `build.gradle`).

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

## dora.py

**But** : mesurer la performance de livraison de l'équipe avec les
indicateurs **DORA** (DevOps Research and Assessment), sur les 30 derniers
jours, à partir de ce que GitHub enregistre déjà : aucune base, aucun
outil à installer (modèle du projet Four Keys de Google).

| Indicateur ([définitions DORA](https://dora.dev/guides/dora-metrics/)) | Calcul chez Orion |
|---|---|
| Fréquence de déploiement | déploiements **réussis** de l'environnement GitHub `production`, par semaine |
| Délai des changements | médiane, pour chaque commit livré, entre le commit et la fin de son déploiement en prod |
| Taux d'échec des changements | déploiements en échec, ou pendant lesquels un ticket `incident` a été ouvert, sur le total |
| Temps de rétablissement | médiane ouverture → fermeture des tickets `incident` |
| Taux de reprise des déploiements (5e indicateur, ajouté par DORA après les 4 historiques) | déploiements qui ne livrent que des correctifs (`fix`), sur les déploiements réussis |

**Lancement** : workflow **DORA metrics** chaque jour ouvré à 8 h et
15 h UTC, ou à la main (**Actions** → **DORA metrics** → **Run
workflow**) ; le tableau s'affiche sur la page du run, et les valeurs
sont importées dans VictoriaMetrics par un 2e job, sur le runner local
(tableau de bord Grafana **Orion - Delivery**). Le lancement planifié ne part que de `main`,
peut avoir quelques minutes de retard, et GitHub le désactive après 60
jours sans activité sur un dépôt public (le réactiver dans **Actions**).
En local, sans jeton (dépôt public) :

```shell
python3 scripts/dora.py                 # 30 derniers jours
DORA_DAYS=7 python3 scripts/dora.py     # 7 derniers jours
```

**Incidents** : un incident de prod s'ouvre avec le formulaire
**Incident de production** (étiquette `incident` posée d'office), dès la
détection, et se ferme au rétablissement.

**Paramètres** (variables d'environnement) : `DORA_DAYS` (30 par défaut),
`GITHUB_TOKEN` (facultatif), `DORA_METRICS_FILE` (facultatif : fichier
où écrire les mêmes valeurs au format texte de Prometheus, une ligne
`dora_*` par indicateur, sans ligne quand il n'y a pas de donnée), et
les variables standard `GITHUB_*` de
GitHub Actions. **Conditions d'exécution** : Python 3.14, bibliothèque
standard seule. **Sécurité** : lecture seule (`contents`, `deployments`,
`issues: read`), jeton temporaire du job.

**Codes** : 0 réussi ; 1 appel à l'API GitHub en échec ; 2 `DORA_DAYS`
invalide.

**Limites** (approximations assumées, à dire à l'oral) :

- historique court : déploiements en prod depuis le 03/11/2026 ; la
  fréquence est rapportée à toute la période (la 1re date est affichée) ;
- un incident est attribué au déploiement actif à son ouverture, même si
  sa cause est ailleurs (ex. la machine) ;
- « reprise » = commits `fix` seulement : un correctif planifié compte
  comme une reprise ;
- l'état d'un déploiement est son dernier état final (`success`,
  `failure`, `error`) : l'état « inactive », que GitHub ajoute quand une
  version est remplacée ou un environnement recréé, est ignoré (corrigé
  le 10/11 : il masquait les 22 déploiements de prod) ;
- le 1er déploiement n'a pas de délai (aucun déploiement précédent pour
  savoir quels commits il livre) ; 100 déploiements et 100 tickets au
  plus par appel (pas de pagination).

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
3. Secrets `microcrm-db` (superutilisateur de la base) et
   `microcrm-db-app` (compte limité de l'application), par la même
   fonction : chacun créé **une seule fois**, avec une valeur aléatoire
   (`openssl rand`) passée à kubectl par un tube, donc jamais visible dans
   la ligne de commande ni affichée ; jamais remplacé, car la base garde
   le mot de passe de sa création. Sur un environnement déjà installé,
   seul le Secret manquant est créé (test
   `test_missing_app_secret_is_created_and_admin_secret_kept`) ;
4. `helm lint` avec les réglages de l'environnement ;
5. `helm upgrade --install --wait --rollback-on-failure` : si les pods ne
   sont pas prêts en 6 minutes, Helm remet lui-même la version précédente ;
   les anciens pods servent jusqu'au bout (`maxUnavailable: 0`). Avec
   une étiquette, le chart est d'abord emballé avec ce numéro
   (`helm package --app-version`, archive temporaire effacée à la
   sortie) : `helm history` l'affiche dans la colonne APP VERSION
   (`1.8.2`, ou `sha-abc1234`), en plus de la DESCRIPTION
   (`image v1.8.2`) ;
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
namespace créé par OpenTofu ([`infra/terraform`](../infra/terraform/README.md)) ;
image PostgreSQL durcie chargée dans Minikube
([README racine](../README.md#déployer-sur-kubernetes)).

**Arrêts expliqués** :

| Cas | Code | Correction proposée |
|---|---|---|
| Environnement, étiquette ou révision invalide | 2 | syntaxe rappelée |
| `helm`, `kubectl` ou `openssl` absent | 127 | installer l'outil |
| Namespace absent, illisible avec ces identifiants, ou pas « restricted » | 1 | le créer ou le corriger par OpenTofu (`tofu apply`), ou vérifier le contexte kubectl |
| Pods pas prêts à temps | 1 | version précédente gardée par Helm ; `kubectl -n ENV get pods` |
| Test de fumée en échec | 1 | version précédente remise ; journaux du back |

**Vérifié le 02/11/2026** dans le cluster `orion` : déploiements de
`dev`, 1re installation de `staging` (Secret créé, 16 s), image
inexistante (retour automatique après 6 min, aucune coupure), retour à
une révision choisie. Le 1er essai a montré que, dans le conteneur,
`localhost` désigne d'abord l'IPv6 (`::1`), où nginx n'écoute pas : le
test de fumée vise donc `127.0.0.1`.

## zap-scan.sh

**But** : tester la sécurité de l'application **en fonctionnement** avec
ZAP (OWASP), comme le ferait un attaquant, sans accès au code. Le scan
tourne **dans le cluster**, à côté de l'application, sous les mêmes
règles « restricted ».

```shell
scripts/zap-scan.sh baseline   # passif : visite et inspecte les réponses
scripts/zap-scan.sh full       # actif : tente des attaques (injections, XSS)
```

**Fonctionnement** :

1. les règles [`infra/zap/rules.tsv`](../infra/zap/rules.tsv) (FAIL,
   WARN, INFO ou IGNORE pour chaque alerte) sont rangées dans la
   ConfigMap `zap-rules` ;
2. le Job Kubernetes `zap` est (re)créé dans `staging` avec l'image du
   projet `orion/zap` ([`infra/zap/Dockerfile`](../infra/zap/Dockerfile) :
   ZAP officiel corrigé, règles « bêta » ajoutées à la construction et
   vérifiées par empreinte), utilisateur non root, aucune capacité Linux,
   aucun jeton d'accès à l'API, mémoire limitée (4 Gio), durée limitée
   (15 min en passif, 40 min en actif), effacé une heure après la fin ;
3. ZAP visite le front (`http://microcrm-front:8080`), qui relaie `/api`
   vers le back. Le pare-feu du chart ne lui ouvre **que le front** :
   ni Internet, ni le back ou la base en direct. ZAP ne télécharge donc
   rien au démarrage (`-silent`) : seuls les modules de l'image servent ;
4. le rapport (Markdown) est écrit à la fin du journal du pod ; le script
   le récupère dans `REPORT_DIR` avec la sortie complète ;
5. code 1 si une alerte réglée sur **FAIL** est trouvée (les WARN sont
   signalées sans bloquer) : dans la CI, la prod n'est alors pas déployée.

En actif, ZAP explore 2 minutes puis attaque 10 minutes au plus. Il
**envoie des formulaires** : des données de test restent dans la base de
`staging`. C'est pour cela qu'il ne se lance qu'à la demande
(Actions → ZAP → Run workflow).

**Paramètres** : `REPORT_DIR`, dossier du rapport (`./zap-report` par
défaut, ignoré par Git) ; `NAMESPACE` (`staging` par défaut : seul
namespace où le pare-feu laisse passer ZAP).

**Conditions d'exécution** : `kubectl` ; accès au namespace avec le droit
de gérer des `jobs` (deployer de `staging` dans la CI, contexte `orion`
sur le poste) ; application déployée dans `staging` ; image
`orion/zap:2.17.0-hardened` chargée dans Minikube
([README racine](../README.md#déployer-sur-kubernetes)).

**Arrêts expliqués** :

| Cas | Code | Correction proposée |
|---|---|---|
| Mode inconnu | 2 | syntaxe rappelée |
| `kubectl` absent | 127 | installer l'outil |
| Fichier de règles absent | 1 | `infra/zap/rules.tsv` |
| Alerte réglée sur FAIL trouvée | 1 | lire le rapport, corriger, ou justifier et dater un changement de règle |
| Job pas fini à temps | 1 | `kubectl -n staging describe job zap` |

## load-test.sh

**But** : mesurer comment MicroCRM tient la charge, avant chaque mise en
production et à la demande, sans jamais charger la prod.

**Fonctionnement** : le scénario
[`infra/k6/microcrm.js`](../infra/k6/microcrm.js) est mis dans la
ConfigMap `k6-script`, puis un Job Kubernetes `k6` (image officielle
`grafana/k6` 2.3.0, figée par empreinte) le joue dans `staging`, contre
le front. Chaque utilisateur simulé (VU) suit le même parcours :
accueil → liste des personnes et des organisations → fiche d'une
personne → 1 fois sur 10, création puis suppression d'une personne
avec 1 à 3 s de pause entre deux écrans, comme un humain. À la fin
(`teardown`, une seule fois après tous les VUs), k6 supprime les
personnes de test restées après un test interrompu ou saturé.

| Profil ([types de tests de k6](https://grafana.com/docs/k6/latest/testing-guides/test-types/)) | Charge | Durée | Question | Lancement |
|---|---|---|---|---|
| `smoke` (fumée) | 1 VU | 30 s | le script et l'appli fonctionnent ? | **CI, après ZAP ; bloque la prod** |
| `average` (charge moyenne) | 20 VUs | 5 min | comportement normal ? | à la main |
| `stress` | 60 VUs (3 × la moyenne) | 5 min | au-delà du normal ? | à la main |
| `spike` (pic) | 0 → 100 VUs en 10 s | 1 min | arrivée brutale ? | à la main |
| `breakpoint` (point de rupture) | 10 → 100 parcours/s, 150 VUs au plus | 10 min au plus | capacité maximale ? | à la main |
| `soak` (endurance) | 20 VUs | 30 min | fuite de mémoire ? | à la main |

**Seuils** (un seuil dépassé fait échouer le test) : moins de 1 %
d'erreurs, p95 < 500 ms, p99 < 1,5 s, plus de 99 % de vérifications
réussies. Le point de rupture s'arrête de lui-même quand les erreurs
passent 5 % : c'est la capacité cherchée, le script le compte comme un
succès.

```shell
scripts/load-test.sh smoke             # 1 utilisateur, 30 s
scripts/load-test.sh stress            # 60 utilisateurs, 5 min
PUSH_METRICS=0 scripts/load-test.sh average   # sans envoi à Grafana
```

**Règle** : les profils lourds (`stress`, `spike`, `breakpoint`, `soak`)
se lancent par GitHub : **Actions** → **Load test** → **Run workflow**,
choisir le profil. Le test attend alors son tour derrière les
déploiements de staging (groupe `deploy-staging`) ; lancé à la main
pendant un pipeline, il se ferait fausser par la CI qui tourne sur le
même poste (vu le 05/11 : poste saturé, mesure perdue). Le script refuse
aussi de partir si un Job `k6` tourne déjà et, lancé depuis le poste,
si un job de CI tourne (pod dans `arc-runners`). Le résumé de k6 s'affiche sur la page de l'exécution (et en
artefact 30 jours). Les mesures arrivent dans VictoriaMetrics (sortie
`experimental-prometheus-rw` de k6, étiquette `testid` propre à chaque
test) : charge, temps de réponse et nombre de répliques se lisent sur la
même période dans Grafana.

**Paramètres** : `REPORT_DIR`, dossier du résumé (`./load-report` par
défaut, ignoré par Git) ; `NAMESPACE` (`staging` par défaut ; **`prod`
refusé** : elle sert de vrais utilisateurs) ; `PUSH_METRICS` (`1` par
défaut, `0` pour ne pas envoyer les mesures).

**Conditions d'exécution** : `kubectl` ; accès au namespace avec le droit
de gérer des `jobs` et des `configmaps` (deployer de `staging` dans la
CI, contexte `orion` sur le poste) ; application déployée dans `staging`
avec `networkPolicy.allowK6` (pare-feu : le pod k6 ne joint que le front,
le DNS et VictoriaMetrics) ; pile de supervision installée pour les
mesures.

**Sécurité** : pod sans privilège (non-root, aucune capacité, disque en
lecture seule, aucun jeton Kubernetes) ; image figée par empreinte ;
aucun secret ; données de test reconnaissables (`Load Test…`,
`@example.com`, domaine réservé aux exemples) et supprimées aussitôt,
puis par le ménage final. **Limites de ressources** du pod k6 (1 cœur,
512 Mio) : le générateur de charge ne prend pas au poste (cluster, runner
de la CI) les ressources de ce qu'il mesure.

**Limites** : k6 tourne sur la même machine que l'application et lui
prend du processeur : les chiffres servent à **comparer** (avant/après),
pas à annoncer une capacité absolue ; le point de rupture est plafonné
à ce que le poste supporte (à 200 parcours/s, c'est le poste qui a
cédé, pas l'appli) ; la charge « normale » de 20
utilisateurs et la part d'écritures (1 parcours sur 10) sont des
hypothèses, l'énoncé ne donnant aucun chiffre de fréquentation.

**Arrêts expliqués** :

| Cas | Code | Correction proposée |
|---|---|---|
| Profil inconnu | 2 | syntaxe rappelée |
| `NAMESPACE=prod` | 1 | tester `staging` |
| `PUSH_METRICS` autre que 0 ou 1 | 1 | `0` ou `1` |
| `kubectl` absent | 127 | installer l'outil |
| Scénario absent | 1 | `infra/k6/microcrm.js` |
| Un Job `k6` tourne déjà | 1 | attendre sa fin (`kubectl -n staging get job k6`) |
| Job de CI en cours (lancement depuis le poste) | 1 | attendre la fin du pipeline, ou passer par Actions → Load test |
| Seuil dépassé | 1 | lire le résumé ; corriger l'appli ou ses ressources |
| Job pas fini à temps | 1 | `kubectl -n staging describe job k6` |

## backup.sh

**But** : sauvegarder la base PostgreSQL de MicroCRM d'un environnement,
**prouver que la sauvegarde se restaure**, et restaurer toute la base ou
seulement les lignes disparues d'une table.

```shell
# Sauvegarder
scripts/backup.sh dev
# Restaurer la dernière sauvegarde dans une base temporaire (vérification)
scripts/backup.sh verify dev
# Restaurer toute la base
scripts/backup.sh restore dev <fichier>
# Remettre seulement les lignes disparues d'une table
scripts/backup.sh restore dev <fichier> --table person
```

**Fonctionnement** :

- **sauvegarde** : `pg_dump` au format « custom » (compressé, restauration
  d'une table possible), lancé **dans le pod de la base** : aucun outil
  PostgreSQL à installer sur le poste. Écriture dans un fichier
  temporaire, renommé seulement si tout a réussi ; empreinte SHA-256 dans
  un fichier `.sha256` ; contenu relu par `pg_restore --list` ; seules les
  `KEEP` sauvegardes les plus récentes sont gardées. Nom :
  `microcrm-<env>-<date UTC>.dump` ;
- **verify** : la dernière sauvegarde (ou celle donnée) est restaurée
  dans une base temporaire `microcrm_verify`, ses lignes sont comptées,
  puis la base est supprimée. La vraie base n'est pas touchée ;
- **restore** : contrôles d'abord (nom de table, clé primaire, empreinte
  du fichier), puis **sauvegarde de sécurité** de l'état actuel, puis :
  - toute la base : `pg_restore --clean --single-transaction`, tout ou
    rien. Les droits du compte limité de l'application font partie de la
    sauvegarde ; une sauvegarde qui ne les contient pas (faite avant ce
    compte) se restaure aussi : les tables recréées par le
    superutilisateur reçoivent ses droits « par défaut » (testé le 08/11
    en restaurant sans les droits, `pg_restore -x`) ;
  - une table (`--table`) : sur place, c'est impossible sans casser les
    liens (clés étrangères). La sauvegarde est donc restaurée dans une
    base annexe, puis seules les lignes **absentes** sont recopiées
    (`INSERT … ON CONFLICT DO NOTHING`, en une transaction) : les lignes
    actuelles ne sont pas modifiées. Une table sans clé primaire est
    refusée, car un doublon n'y serait pas détecté.

**Paramètres** : `BACKUP_DIR`, dossier des sauvegardes, hors du dépôt et
du cluster (défaut `~/backups/microcrm`, un sous-dossier par
environnement) ; `KEEP`, nombre de sauvegardes gardées par environnement
(défaut 7) ; `BACKUP_METRICS_DIR`, dossier lu par node_exporter : après
une sauvegarde réussie, le script y écrit l'heure de cette sauvegarde
(`microcrm_backup_last_success_timestamp_seconds`, fichier en 640, écrit
puis renommé), qui alimente l'alerte `BackupTooOld` (vide par défaut :
rien n'est écrit ; réglé par Ansible pour les sauvegardes planifiées).

**Conditions d'exécution** : `kubectl` et `sha256sum` ; accès au cluster
avec le droit `pods/exec` dans le namespace (il donne accès à la base :
PostgreSQL fait confiance aux connexions locales du pod, les connexions
réseau exigent le mot de passe) ; pod `microcrm-postgres-0` démarré.

**Sécurité** :

- fichiers en 600 et dossiers en 700 (`umask 077`) : une sauvegarde
  contient des données personnelles ;
- transport chiffré (API Kubernetes en TLS) ; au repos, disque de la
  machine chiffré (LUKS) ;
- un fichier dont l'empreinte ne correspond plus n'est jamais restauré ;
- nom de table limité aux minuscules et `_` : il entre dans une requête
  SQL (injection impossible).

**Arrêts expliqués** :

| Cas | Code | Correction proposée |
|---|---|---|
| Action, environnement ou nom de table invalide | 2 | syntaxe rappelée |
| `kubectl` ou `sha256sum` absent | 127 | installer l'outil |
| `pg_dump` en échec | 1 | état du pod ; aucun fichier partiel gardé |
| Aucune sauvegarde pour `verify` | 1 | lancer `scripts/backup.sh ENV` |
| Fichier ou `.sha256` absent, empreinte différente | 1 | choisir un autre fichier |
| Table absente ou sans clé primaire | 1 | restaurer toute la base |
| Restauration en échec | 1 | base inchangée ; chemin de la sauvegarde de sécurité affiché |

**Vérifié le 02/11/2026** dans le namespace `dev` : sauvegarde (8 Ko) et
`verify` ; personne supprimée puis remise par `--table person` sans
toucher aux autres ; lien et personne supprimés puis base entière
restaurée, application fonctionnelle ; fichier modifié refusé ; rotation.
**Temps de restauration (RTO) mesuré : 0,6 s**, sauvegarde de sécurité
comprise (base de 7 Ko).

**Objectifs actuels** : sauvegarde de la prod **au démarrage du poste**
(5 min après) et **chaque jour** (12 h 30), vérification de sa
restauration **chaque vendredi** (13 h) ; le poste est éteint le soir et
cron ne rattrape pas une tâche manquée, d'où ces horaires ; tâches
planifiées installées par Ansible ([`infra/ansible`](../infra/ansible/README.md),
rôle `backup`, journal `~/.local/state/microcrm-backup.log`), soit une
perte de données maximale (**RPO**) de 24 h ; 7 sauvegardes gardées, soit
une semaine d'historique. Testées le 04/11/2026 dans les conditions de
cron (environnement vide) : sauvegarde et vérification réussies.

**Limites connues et évolutions** :

| Limite | Évolution |
|---|---|
| RPO de 24 h, pas de retour à une minute précise | Archivage continu des journaux de transactions (WAL) et restauration à un instant donné (PITR) : opérateur CloudNativePG ou service managé (AWS RDS) |
| Sauvegarde complète à chaque fois | Complète hebdomadaire et incrémentale quotidienne (pgBackRest, ou `pg_basebackup --incremental` de PostgreSQL 17+), utile quand la base grossit ; la base fait 7 Ko |
| Deux copies : sur la machine, et hors site (Google Drive, dans l'archive chiffrée GPG AES-256 de la machine, chaque jour) | Règle 3-2-1 complète : 3e copie sur un autre support ; stockage S3 versionné dans la cible cloud |
| Sur la machine, fichiers non chiffrés un par un (protégés par le chiffrement du disque et les droits) ; la copie hors site est chiffrée | Chiffrement de chaque fichier (age) dès sa création, clé gardée hors de la machine |
| Sauvegarde faite avec le superutilisateur `microcrm` (l'application, elle, utilise un compte limité) | Compte de sauvegarde en lecture seule (rôle prédéfini `pg_read_all_data`) ; la restauration garde le superutilisateur |
| La table de liens `organization_persons` n'a pas de clé primaire : restauration par table impossible, liens en double possibles | Clé primaire `(organizations_id, persons_id)` par une migration Flyway (demande à l'équipe Dev) |

## backup-openbao.sh

**But** : sauvegarder chaque jour le coffre-fort OpenBao (identité de la
CI, jeton SonarQube) pour pouvoir le reconstruire après la perte de son
disque ou du cluster (recommandation 26 du rapport).

```shell
scripts/backup-openbao.sh   # instantané dans ~/backups/openbao
```

**Fonctionnement** : vérifie le jeton de sauvegarde (fichier présent, en
600) et que le coffre est déverrouillé ; dans le pod, prolonge le jeton
(7 jours) puis prend l'instantané Raft ; le copie sur le poste dans un
fichier temporaire, gardé seulement si son empreinte est la même que
dans le pod et si l'archive est complète et intacte (`state.bin`,
`meta.json`, empreintes `SHA256SUMS` vérifiées) ; écrit l'empreinte
(`.sha256`), garde les 7 plus récents, écrit la métrique de supervision ;
efface toujours le fichier du pod, même après une erreur.

**Paramètres** : `OPENBAO_BACKUP_TOKEN_FILE` (défaut
`~/.config/orion-openbao/backup-token`), `BACKUP_DIR` (défaut
`~/backups/openbao`), `KEEP` (défaut 7), `BACKUP_METRICS_DIR` (dossier
lu par node_exporter ; vide : aucune métrique).

**Conditions d'exécution** : poste Ops, `kubectl` relié au cluster,
coffre déverrouillé, jeton créé par l'Ops
([README d'OpenBao](../infra/openbao/README.md#sauvegarde-planifiée)).
Restauration : même README, « Restaurer ».

**Sécurité** : le jeton ne peut que lire l'instantané (règle
`openbao-backup`) ; il passe par l'entrée standard, jamais en argument
(invisible dans la liste des processus) ; fichiers en 600, dossier en
700 ; l'instantané reste chiffré par le coffre.

**Arrêts expliqués** :

| Cas | Code | Correction proposée |
|---|---|---|
| Argument donné | 2 | syntaxe rappelée (aucun argument) |
| `kubectl`, `sha256sum` ou `tar` absent | 127 | installer l'outil |
| Fichier du jeton absent | 1 | le créer (README d'OpenBao) |
| Fichier du jeton lisible par d'autres | 1 | `chmod 600` |
| Coffre scellé | 1 | le déverrouiller |
| Coffre injoignable | 1 | `kubectl -n openbao get pods` |
| Instantané refusé (jeton expiré après 7 jours sans sauvegarde) | 1 | refaire le jeton |
| Copie abîmée ou archive incomplète | 1 | aucun fichier gardé ; relancer |

## e2e.sh

**But** : vérifier les écrans de MicroCRM comme un utilisateur, avec un
vrai navigateur, avant la publication des images (recommandation 2 du
rapport).

```shell
scripts/e2e.sh FRONT_IMAGE BACK_IMAGE
# ex. images publiées d'un commit
scripts/e2e.sh ghcr.io/yohanbouchet/orion-front:sha-394d8fe \
  ghcr.io/yohanbouchet/orion-back:sha-394d8fe
```

**Fonctionnement** : tire un mot de passe de base au hasard ; démarre
avec Docker Compose ([`e2e/compose.yaml`](../e2e/compose.yaml)) une base
PostgreSQL en mémoire, le back et le front (même relais `/api` que le
chart Helm, disques système en lecture seule) ; attend que les trois
soient prêts (sondes de santé) ; lance Playwright (image officielle,
navigateurs inclus, sans root) qui joue les parcours de
[`e2e/tests/`](../e2e/tests/microcrm.spec.ts) ; garde les journaux du
back et du front, puis supprime tout, même après un échec.

**Parcours** : page d'accueil (listes des personnes et des
organisations) ; création d'une organisation, visible sur l'accueil ;
création d'une personne, rattachement à une organisation, personne
visible sur l'accueil. Chaque élément est trouvé par son rôle et son
nom lisible (comme un lecteur d'écran), jamais par une classe CSS.

**Résultats** : `e2e/playwright-report/` (rapport HTML) ;
`e2e/test-results/` (trace pas à pas, capture et vidéo de chaque échec,
journaux `stack.log`) ; gardés 7 jours par la CI en cas d'échec.

**Conditions d'exécution** : Docker avec Compose, `openssl` ; aucun
port publié sur la machine (réseau privé du projet).

**Vérifié le 12/11/2026** : 3 parcours réussis en 27 s (images déjà
téléchargées) ; contre-épreuve : relais `/api` cassé exprès, 2 parcours
en échec et code 1.

**Arrêts expliqués** :

| Cas | Code | Correction proposée |
|---|---|---|
| Pas exactement 2 images | 2 | syntaxe rappelée |
| `docker` ou `openssl` absent | 127 | installer l'outil |
| Base, back ou front pas prêts en 3 min | 1 | lire `e2e/test-results/stack.log` |
| Parcours en échec | 1 | ouvrir `e2e/playwright-report/index.html` |

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
`set -euo pipefail`, et il n'a pas de test bashunit (**limite** : outil
d'installation lancé rarement, à la main). Évolution : l'aligner et le
tester comme les autres scripts, ou décrire SonarQube en OpenTofu avec
le reste du socle (rapport, recommandation 28).

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
| `tests/run_tests_test.sh` | bashunit | usage, dépendances absentes, Vitest lancé une fois sans navigateur, tests rouges, Gradle lancé, rapport absent |
| `tests/backup_test.sh` | bashunit | usage, fichier privé (600/700) et empreinte, rotation, `pg_dump` en échec sans fichier partiel, `verify` (base temporaire), fichier abîmé refusé, sauvegarde de sécurité avant restauration, table : lignes absentes seulement, table sans clé refusée, nom de table piégé ; métrique de supervision écrite après une sauvegarde réussie (fichier en 640), aucune après un échec |
| `tests/backup_openbao_test.sh` | bashunit | usage, jeton absent ou lisible par d'autres, coffre scellé, instantané privé (600/700) avec empreinte, jeton passé par l'entrée standard et jamais en argument, jeton prolongé, métrique écrite (640), échec sans fichier ni métrique, copie abîmée ou archive à l'empreinte fausse refusées, rotation, fichier du pod toujours effacé |
| `tests/e2e_test.sh` | bashunit | usage, pile démarrée avec attente des sondes puis parcours lancés, images et mot de passe aléatoire transmis à compose, tout supprimé après un succès ou un échec, pile qui ne démarre pas (parcours non lancés, journaux gardés), parcours en échec (code 1), mot de passe jamais dans une commande |
| `tests/deploy_test.sh` | bashunit | usage, étiquette piégée, namespace absent ou non « restricted », Secret créé par un tube ou conservé, lint et options de Helm, chart emballé avec la version déployée (archive effacée ensuite) ou installé tel quel sans étiquette, échec de l'emballage ou de Helm, test de fumée raté → retour arrière, `rollback` |
| `tests/load_test_test.sh` | bashunit | usage, profil inconnu, prod refusée, `PUSH_METRICS` invalide, scénario absent, fumée dans `staging` contre le front (durée limitée), envoi des mesures activable, pod sans privilège sur image figée, résumé gardé, seuil dépassé (code 1), point de rupture atteint (succès) |
| `tests/zap_scan_test.sh` | bashunit | usage, mode inconnu, règles absentes, commandes passive et active (durée limitée), pod sans privilège ni jeton, rapport extrait du journal, échec (règle FAIL) avec rapport conservé |
| `tests/test_notify.py` | pytest | jobs en échec, exercice, ouverture / commentaire / fermeture, résumé, paramètres |
| `tests/test_dora.py` | pytest | dates de l'API, période, délai médian, échec par état ou par incident, rétablissement, reprise (`fix` seuls), aucune donnée, déploiements en attente ignorés, état « inactive » ignoré au profit du dernier état final, commits de fusion exclus, métriques au format de Prometheus (valeur absente non exportée), fichier écrit seulement sur demande, paramètre invalide (code 2), API injoignable (code 1) |

Les tests Bash remplacent `npm`, `java`, `gradlew`, `helm` ou `kubectl`
par des **doublures** (faux programmes placés en tête du `PATH`) : ils
vérifient la logique du script en quelques secondes. Les tests Python
remplacent l'API GitHub par un faux client : aucun ticket réel n'est créé.

Versions des outils de test : bashunit est téléchargé dans la CI avec
vérification de son empreinte SHA-256 ; pytest et ses dépendances sont
figés avec empreintes dans `tests/requirements.txt`, mis à jour par
Dependabot.

**Non testé** : la logique shell des deux actions composites de la CI
([`kube-access`](../.github/actions/kube-access/action.yml),
[`openbao-secret`](../.github/actions/openbao-secret/action.yml) :
demande du badge OIDC, appel d'OpenBao, kubeconfig) n'a pas de test
automatique ; elle est relue par zizmor et actionlint, et exercée à
chaque déploiement. Évolution : la déplacer dans `scripts/` et la
couvrir par bashunit, comme les autres scripts.
