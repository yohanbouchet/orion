# Plan de reprise d'activité (PRA) — plateforme MicroCRM

| Élément | Valeur |
| --- | --- |
| Projet | Démarche DevOps pour l'application MicroCRM |
| Client | Orion (destinataires : Maria, CTO, et l'équipe Ops) |
| Auteur | Yohan Bouchet |
| Version | 1.0 (12/11/2026) : procédure exécutée en entier le 12/11, corrigée de ses 4 écarts |
| Dépôt | [github.com/yohanbouchet/orion](https://github.com/yohanbouchet/orion) (public) |

**Accessibilité** : titres hiérarchisés, tableaux avec ligne d'en-tête,
aucune information portée par la couleur seule, sigles développés à
leur première apparition.

## 1. Objet et périmètre

Un **plan de reprise d'activité** (PRA, *disaster recovery plan*) décrit
comment remettre un service en route après un sinistre. Celui-ci est
une **procédure pas à pas** (*runbook*) : l'Ops la suit ligne à ligne,
sans improviser.

| Sinistre | Couvert par | Testé |
| --- | --- | --- |
| Une version défectueuse en production | retour arrière ([documentation CI/CD, 7.4](03-documentation-ci-cd.md#74-procédure-de-rollback)) | oui (02/11) |
| Données abîmées dans une base | restauration d'une sauvegarde ([scripts](../scripts/README.md#backupsh)) | oui, chaque semaine |
| **Perte totale du cluster Kubernetes** (suppression, corruption, changement de machine virtuelle) | **ce document** | **oui (12/11) : 48 min** |
| Perte du poste Ops lui-même (disque, vol) | restaurer d'abord la copie hors site chiffrée (sauvegardes, états OpenTofu, réglages), puis ce document | **non** : restauration de la copie testée seule (section 7) |

Ce que la procédure reconstruit : le cluster Minikube `orion`, le socle
(namespaces, comptes de déploiement, supervision, coffre-fort OpenBao,
Headlamp), le runner local de la CI, SonarQube et la production de
MicroCRM, **avec leurs données**. Les environnements `dev` et `staging`
sont redéployés par la CI (étape 9) ; leurs données de test ne sont pas
restaurées.

## 2. Objectifs

| Objectif | Valeur | Source |
| --- | --- | --- |
| **RTO** (*Recovery Time Objective*, temps de reprise) de la plateforme | **48 min**, mesuré le 12/11 (CI comprise) | section 6 |
| **RPO** (*Recovery Point Objective*, perte de données maximale) de la base de prod | **24 h** : une sauvegarde par jour | [documentation CI/CD, 7.6](03-documentation-ci-cd.md#76-stratégie-de-backup) |
| RPO du coffre OpenBao et de la base de SonarQube | 24 h en semaine ; l'alerte ne part qu'après 74 h (un week-end poste éteint) | idem |
| RPO des métriques et des journaux | **non sauvegardés** : l'historique repart de zéro (limite assumée, section 7) | section 7 |

Si le sinistre est prévisible (maintenance, changement de machine), on
lance d'abord des sauvegardes fraîches (étape 0) : la perte de données
est alors nulle. C'était le cas de l'exercice du 12/11.

## 3. Ce qu'il faut avoir sous la main

| Élément | Où il est | Sans lui |
| --- | --- | --- |
| Ce dépôt (code, chart, OpenTofu, Ansible, scripts) | GitHub | rien n'est possible |
| Sauvegardes : base de prod, instantané d'OpenBao, base de SonarQube | `~/backups/` sur le poste ; copie hors site chiffrée | les données sont perdues ; le coffre peut être refait à neuf (section 5) |
| États OpenTofu et adresse des alertes (`monitoring.tfvars`) | `~/.local/state/orion-terraform/` et `orion-openbao/`, droits 600 ; copie hors site | le socle est recréé quand même ; un nouveau certificat d'OpenBao est émis (variable `OPENBAO_CA` de GitHub à mettre à jour) |
| Clés de déverrouillage (2 sur 3) et jeton racine d'OpenBao | gestionnaire de mots de passe de l'Ops, **jamais sur le poste** | l'instantané est illisible : coffre neuf (section 5) |
| Clé privée de l'application GitHub du runner (ARC) | `~/.config/orion-arc/`, droits 600 | en créer une nouvelle dans GitHub (réglages de l'application) |
| Mot de passe d'application Gmail des alertes | à recréer dans le compte Google (il n'est gardé nulle part) | aucun e-mail d'alerte |
| Images du projet (PostgreSQL durcie, ZAP, runner) | reconstruites par Ansible à partir du dépôt | — |
| Images de l'application | GHCR, signées, une par version | — |

Les réglages de GitHub (environnements, approbation, variables
`KUBE_CA` et `OPENBAO_CA`) ne sont pas touchés par la perte du cluster.
`KUBE_CA` reste valable : l'autorité de certification de Minikube est
gardée sur le poste (`~/.minikube/ca.crt`) et réutilisée par le nouveau
cluster.

## 4. Procédure

**Règles** :

- un seul terminal pour toute la procédure, ouvert à la racine du
  dépôt ; un second seulement à l'étape 5.6 ;
- **ne pas redémarrer la machine** avant la fin (le service systemd
  relancerait un cluster incomplet) ; **ne rien fusionner** (une CI sans
  cluster échouerait) ;
- si une commande échoue : ne rien relancer avant d'avoir lu l'erreur ;
- chaque étape se termine par `etape N` : l'heure est notée dans un
  journal, pour mesurer le temps de reprise ;
- alertes attendues pendant la reprise : `OpenBaoSealed` (coffre scellé
  jusqu'à l'étape 5) et `MicrocrmProdDown` (prod absente jusqu'à
  l'étape 8). Tant que le cluster n'existe pas, **aucune alerte ne
  part** : la supervision est dans le cluster (section 7).

### Étape 0. Préparer

Seulement si le cluster fonctionne encore (reprise planifiée) : trois
sauvegardes fraîches. Dans tous les cas : noter les fichiers à
restaurer, car chaque restauration crée une sauvegarde de sécurité plus
récente (« la dernière » ne serait plus la bonne).

```shell
git switch main && git pull && git status --short   # rien d'affiché

# Chronomètre : note l'heure de fin de chaque étape
etape() { echo "$(date +%T) fin de l'étape $*" |
  tee -a ~/.local/state/pra.log; }

# Reprise planifiée seulement : sauvegardes fraîches, avec leur métrique
M=/var/lib/node_exporter/textfile
BACKUP_METRICS_DIR=$M scripts/backup.sh prod
BACKUP_METRICS_DIR=$M scripts/backup-openbao.sh
BACKUP_METRICS_DIR=$M scripts/backup-sonarqube.sh

# Fichiers à restaurer, gardés dans un fichier (rechargé par « source »
# si le terminal est fermé)
PROD_DUMP=$(ls -t ~/backups/microcrm/prod/microcrm-prod-*.dump | head -1)
OPENBAO_SNAP=$(ls -t ~/backups/openbao/openbao-*.snap | head -1)
SONAR_DUMP=$(ls -t ~/backups/sonarqube/sonarqube-*.dump | head -1)
printf 'PROD_DUMP=%s\nOPENBAO_SNAP=%s\nSONAR_DUMP=%s\n' \
  "$PROD_DUMP" "$OPENBAO_SNAP" "$SONAR_DUMP" > ~/.local/state/pra.env
chmod 600 ~/.local/state/pra.env
cat ~/.local/state/pra.env     # 3 chemins, aux dates attendues
```

### Étape 1. Supprimer ce qui reste du cluster

```shell
echo "$(date +%T) DÉBUT" | tee ~/.local/state/pra.log
minikube delete -p orion
etape 1
```

### Étape 2. Recréer le cluster

Mêmes réglages que l'installation ([README](../README.md#installer-la-chaîne-sur-le-poste-ops)) ;
le réseau est **fixé** (`--subnet`) : la supervision vise ces adresses.

```shell
minikube start -p orion --driver=docker --cpus=4 --memory=10g \
  --kubernetes-version=v1.37.0 --subnet=192.168.49.0/24
kubectl get nodes        # orion   Ready   …   v1.37.0
etape 2
```

### Étape 3. Poste et cluster (Ansible)

Images du projet construites et chargées dans le cluster,
metrics-server, sauvegardes planifiées, service systemd, pare-feu,
métriques de la machine.

```shell
(cd infra/ansible && ansible-playbook site.yml -K)   # mot de passe sudo
minikube -p orion image ls | grep orion/             # 3 images orion/…
etape 3
```

Attendu : `failed=0` dans le récapitulatif.

### Étape 4. Socle (OpenTofu)

L'état OpenTofu décrit l'ancien cluster : OpenTofu constate que tout a
disparu et propose de tout recréer. Les certificats d'OpenBao, eux,
sont dans l'état : ils ne doivent **pas** changer.

```shell
cd infra/terraform
tofu plan -var-file="$HOME/.local/state/orion-terraform/monitoring.tfvars" \
  -out="$HOME/.local/state/orion-terraform/tfplan"
# Dernière ligne attendue : « Plan: N to add, 0 to change, 0 to destroy »
tofu apply "$HOME/.local/state/orion-terraform/tfplan"
find ~/.local/state/orion-terraform -maxdepth 1 -type f -exec chmod 600 {} +
cd ../..

# Mot de passe d'application Gmail des alertes, saisi sans écho : sans
# lui, Alertmanager ne démarre pas et aucun e-mail ne part
read -rs -p "Gmail app password: " P; echo
printf '%s' "$P" | kubectl -n monitoring create secret generic \
  alertmanager-smtp --from-file=password=/dev/stdin; unset P

kubectl get ns                 # dev, staging, prod, monitoring, openbao…
kubectl -n openbao get pods    # openbao-0  0/1  Running : scellé, normal
etape 4
```

### Étape 5. Coffre-fort OpenBao, restauré depuis l'instantané

Le coffre recréé est **vide**. On l'initialise avec une clé et un jeton
**jetables**, on y restaure l'instantané, on redémarre le pod, puis ce
sont les **clés d'origine** qui le déverrouillent.

**5.1 Coffre temporaire** (1 clé, 1 jeton, à ne pas conserver) :

```shell
kubectl -n openbao exec -it openbao-0 -- \
  bao operator init -key-shares=1 -key-threshold=1
```

**5.2 Le déverrouiller avec la clé temporaire** (saisie sans écho) :

```shell
kubectl -n openbao exec -it openbao-0 -- bao operator unseal
```

**5.3 Contrôler l'instantané et l'envoyer dans le pod** :

```shell
(cd ~/backups/openbao &&
  sha256sum -c "$(basename "$OPENBAO_SNAP").sha256")     # … .snap: OK
kubectl -n openbao cp "$OPENBAO_SNAP" openbao-0:/tmp/restore.snap
```

**5.4 Restaurer** (jeton racine temporaire, saisi sans écho) :

```shell
kubectl -n openbao exec -it openbao-0 -- sh -c \
  'printf "Token: "; read -rs BAO_TOKEN; echo; export BAO_TOKEN;
   bao operator raft snapshot restore -force /tmp/restore.snap'
kubectl -n openbao exec openbao-0 -- rm /tmp/restore.snap
clear     # efface la clé et le jeton temporaires de l'écran
```

**5.5 Redémarrer le pod** : le processus garde en mémoire les réglages
du coffre temporaire (1 part) et refuserait les clés d'origine
(`invalid key size 33`) ; au redémarrage, il relit ceux de l'instantané.

```shell
kubectl -n openbao delete pod openbao-0
sleep 30
kubectl -n openbao exec openbao-0 -- bao status |
  grep -E 'Total Shares|Threshold'       # 3 et 2 : le coffre d'origine
```

**5.6 Déverrouiller avec les clés d'origine**, puis vérifier que la
configuration n'a pas bougé :

```shell
kubectl -n openbao exec -it openbao-0 -- bao operator unseal   # clé 1
kubectl -n openbao exec -it openbao-0 -- bao operator unseal   # clé 2
kubectl -n openbao exec openbao-0 -- bao status | grep Sealed  # false
```

Dans un **second terminal**, à laisser ouvert :

```shell
kubectl -n openbao port-forward svc/openbao 8200:8200
```

Dans le premier (jeton racine **d'origine**, saisi sans écho) :

```shell
cd infra/openbao/config
(cd ../../terraform && tofu output -raw openbao_ca_cert) \
  > ~/.local/state/orion-openbao/openbao-ca.pem
printf 'Root token: '; read -rs VAULT_TOKEN; echo; export VAULT_TOKEN
tofu plan \
  -var="openbao_ca_file=$HOME/.local/state/orion-openbao/openbao-ca.pem" \
  -out="$HOME/.local/state/orion-openbao/tfplan"
unset VAULT_TOKEN
find ~/.local/state/orion-openbao -maxdepth 1 -type f -exec chmod 600 {} +
cd ../../..
```

Attendu : `No changes`. Sinon, lire le plan avant toute application.
Arrêter ensuite le tunnel du second terminal (Ctrl+C).

**5.7 Preuve** : le jeton de sauvegarde est revenu avec le coffre.

```shell
scripts/backup-openbao.sh     # … snapshot ready
etape 5
```

### Étape 6. Runner local de la CI (ARC)

```shell
helm install arc --namespace arc-systems --create-namespace \
  --version 0.15.1 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
kubectl apply -f infra/arc/namespace.yaml
kubectl -n arc-runners create secret generic orion-arc-github-app \
  --from-literal=github_app_id=<id> \
  --from-literal=github_app_installation_id=<installation> \
  --from-file=github_app_private_key=<chemin/de/la/clé.pem>
helm install orion-local --namespace arc-runners --version 0.15.1 \
  -f infra/arc/values-orion-runners.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
kubectl -n arc-systems get pods    # contrôleur et « listener » Running
etape 6
```

Dans GitHub (**Settings → Actions → Runners**) : `orion-local` en ligne.

### Étape 7. SonarQube, base restaurée

On installe (base vide), on arrête SonarQube, on restaure sa base, on
le redémarre : il reconstruit son index de recherche.

```shell
scripts/deploy-sonarqube.sh                        # 5 à 10 min
kubectl -n sonarqube scale statefulset sonarqube-sonarqube --replicas=0
kubectl -n sonarqube wait --for=delete pod/sonarqube-sonarqube-0 \
  --timeout=180s
scripts/backup-sonarqube.sh restore "$SONAR_DUMP"
scripts/deploy-sonarqube.sh                        # index reconstruit

# Attendre « UP » : pendant la reconstruction de l'index, SonarQube peut
# redémarrer une fois (sonde de vie) ; une analyse lancée trop tôt échoue
until kubectl -n sonarqube exec sonarqube-sonarqube-0 -- \
  curl -s http://localhost:9000/api/system/status 2>/dev/null |
  grep -q '"status":"UP"'; do sleep 10; done; echo "SonarQube UP"
etape 7
```

### Étape 8. Production, base restaurée

La dernière version publiée est redéployée (liste : `git tag` ou les
Releases de GitHub), puis sa base restaurée.

```shell
scripts/deploy.sh prod <version>               # ex. v1.9.1 ; fumée OK
scripts/backup.sh restore prod "$PROD_DUMP"    # prod restored: N persons…
etape 8
```

### Étape 9. Preuve par la CI

La CI traverse tout ce qui vient d'être reconstruit : runner local,
OpenBao (badge OIDC, jeton de 15 min), SonarQube (jeton lu dans le
coffre), déploiement de `dev` et de `staging`, ZAP et k6.

1. GitHub → **Actions** → dernière exécution du workflow *CI* sur
   `main` → **Re-run all jobs**.
2. Attendre le vert : `sonarqube`, `deploy-dev`, `deploy-staging`,
   `zap`, `load-test`. `deploy-prod` reste « skipped » s'il n'y a pas de
   nouvelle version : normal, la prod vient d'être déployée à l'étape 8.

```shell
etape 9
echo "$(date +%T) FIN" | tee -a ~/.local/state/pra.log
cat ~/.local/state/pra.log
```

### Étape 10. Vérifications finales

```shell
kubectl get pods -A | grep -vE 'Running|Completed'   # rien, hors en-tête
helm list -A                                         # 9 releases
kubectl -n prod get hpa                              # autoscaling actif
crontab -l | grep -c ansible                         # 7 tâches planifiées
```

Puis : Grafana (tableaux de bord présents, alerte `Watchdog` seule
active après 30 min), Headlamp, SonarQube (historique du projet
`orion`), application de prod par `port-forward`.

## 5. Variante : coffre OpenBao neuf

Si l'instantané ou les clés d'origine sont perdus, le coffre est refait
par le code, sans restauration
([README d'OpenBao](../infra/openbao/README.md#démarrage)) :
initialisation (nouvelles clés et nouveau jeton, rangés aussitôt dans le
gestionnaire de mots de passe), déverrouillage, `tofu apply` dans
`infra/openbao/config`, nouveau jeton SonarQube écrit dans le coffre
(après l'étape 7), nouveau jeton de sauvegarde. Aucun secret de
production n'est perdu : le coffre ne contient que l'identité de la CI
et le jeton SonarQube, tous deux recréables.

## 6. Exercice du 12/11/2026

Perte du cluster simulée pour de vrai (`minikube delete`), sauvegardes
fraîches (étape 0), procédure suivie par l'Ops seul.

| Étape | Durée |
| --- | --- |
| 1 et 2. Supprimer puis recréer le cluster | 1 min 12 s |
| 3. Ansible | 6 min |
| 4. Socle OpenTofu | 2 min 36 s |
| 5. OpenBao (écart 1 compris) | 5 min 04 s |
| 6. Runner local | 35 s |
| 7. SonarQube | 18 min 07 s |
| 8. Production | 1 min 02 s |
| 9. CI complète (une relance du job `sonarqube` comprise, écart 2) | 13 min 20 s |
| **Total** (16:58:51 → 17:46:49) | **48 min** |

**Résultat** : 38 pods, comme avant ; mêmes namespaces et mêmes
9 releases Helm ; base de prod restaurée (mêmes nombres de personnes et
d'organisations) ; SonarQube avec ses 29 analyses depuis le 29/10 ;
clés d'origine d'OpenBao acceptées, configuration inchangée
(`No changes`) ; `KUBE_CA` et `OPENBAO_CA` inchangées dans GitHub ; CI
verte jusqu'au test de charge de `staging`.

**Quatre écarts trouvés, tous corrigés dans cette procédure** :

| # | Écart | Effet | Correction |
| --- | --- | --- | --- |
| 1 | Après la restauration, OpenBao refusait les clés d'origine (`invalid key size 33`) : le processus gardait en mémoire les réglages du coffre temporaire | étape 5 allongée | redémarrage du pod ajouté (étape 5.5) ; [README d'OpenBao](../infra/openbao/README.md#restaurer) corrigé |
| 2 | La CI a été relancée 28 s avant que SonarQube ait fini de reconstruire son index (il a redémarré une fois pendant ce travail) | job `sonarqube` en échec, relancé avec succès | attente de l'état `UP` ajoutée (étape 7) |
| 3 | Le nouveau cluster a reçu un autre réseau (192.168.49.0/24 au lieu de 192.168.58.0/24), alors que la supervision visait l'ancien en dur | métriques de la machine non lues (3 alertes de sauvegarde à tort), collecteur de journaux en échec | adresses corrigées et réseau fixé par `--subnet` (PR #157, étape 2) |
| 4 | Le mot de passe d'application Gmail, créé à la main et gardé nulle part, manquait dans la procédure | Alertmanager arrêté : aucun e-mail d'alerte pendant près d'une heure | création du secret ajoutée (étape 4) |

**Enseignement** : une procédure jamais jouée contient des erreurs.
Les quatre écarts étaient invisibles à la relecture ; ils ont tous été
trouvés en moins d'une heure d'exercice. À rejouer après chaque
changement important du socle, et au moins une fois par an.

## 7. Limites et évolutions

| Limite | Évolution |
| --- | --- |
| Procédure **manuelle** : une trentaine de commandes enchaînées par l'Ops (elles lancent des outils automatisés : Ansible, OpenTofu, scripts) | script d'orchestration une fois la procédure stabilisée ; surtout **GitOps** (Flux ou Argo CD) : le cluster se reconstruit lui-même à partir de Git ([rapport, recommandation 7](04-rapport-performance.md#83-recommandations)) |
| Runner local (ARC) et SonarQube installés à la main, hors d'OpenTofu (étapes 6 et 7) | les décrire en OpenTofu (recommandation 28) |
| Déverrouillage d'OpenBao par 2 clés saisies à la main : **voulu** en local (aucun script ne peut ouvrir le coffre seul) | déverrouillage automatique par un service de clés (KMS) dans la cible cloud (recommandation 23) |
| **Aucune alerte pendant la perte du cluster** : la supervision est dans le cluster ; personne n'est prévenu si tout tombe | faire surveiller l'alerte de contrôle `Watchdog` par un service externe (recommandation 11) |
| Historique des métriques et des journaux **non sauvegardé** : après la reprise, les courbes repartent de zéro (les indicateurs DORA sont recalculés depuis GitHub à l'exécution suivante du workflow) | sauvegarde de VictoriaMetrics (`vmbackup`) vers un stockage objet ; Velero (sauvegarde du cluster et de ses volumes, CNCF) dans la cible cloud |
| Mot de passe d'application Gmail gardé nulle part : à recréer à chaque reprise | le ranger dans OpenBao ou dans le gestionnaire de mots de passe |
| Perte du **poste** entier non rejouée : seule la restauration de la copie hors site a été testée (20/10), pas la réinstallation complète sur une autre machine | exercice sur une machine vierge ; dans la cible AWS : sauvegardes dans S3, base RDS Multi-AZ, état OpenTofu distant |
| RPO de 24 h pour la base de prod | restauration à un instant donné (journaux de transactions, CloudNativePG ou RDS ; recommandation 15) |
