# Socle Terraform du cluster

Terraform décrit le **socle** du cluster Minikube : ce qui demande des
droits sur tout le cluster et ne change presque jamais. Helm
(`scripts/deploy.sh`) installe ensuite l'application **dans** ce socle
(ticket #64).

```text
Terraform (opérateur, droits d'administration)
  ├── namespace dev      ── compte deployer, ses droits, son jeton
  ├── namespace staging  ── compte deployer, ses droits, son jeton
  └── namespace prod     ── compte deployer, ses droits, son jeton
      (chacun au niveau Pod Security « restricted »)
                 │
Helm (scripts/deploy.sh, avec le jeton du deployer de l'environnement)
  └── MicroCRM dans le namespace : front, back, PostgreSQL
```

## Fichiers

| Fichier | Rôle |
|---|---|
| `versions.tf` | Versions exigées (Terraform 1.17, fournisseurs `hashicorp/kubernetes` 3.4.x et `hashicorp/helm` 3.3.x) ; état local, rangé hors du dépôt |
| `providers.tf` | Connexion au cluster : kubeconfig de l'opérateur, contexte `orion` |
| `variables.tf` | Réglages : kubeconfig, contexte, environnements (`dev`, `staging`, `prod` seulement), adresse Gmail des alertes (`ops_email`, sensible, hors du dépôt) |
| `main.tf` | Un namespace par environnement, niveau Pod Security « restricted » |
| `rbac.tf` | Un compte `deployer` par namespace, ses droits et son jeton |
| `monitoring.tf` | Supervision : namespaces `monitoring` (« restricted ») et `monitoring-collector` (« privileged », collecteur de journaux seul), pile VictoriaMetrics + VictoriaLogs + Grafana (chart Helm figé), tableaux de bord ([détails](../monitoring/README.md)) |
| `outputs.tf` | Jetons et certificat du cluster (valeurs sensibles, jamais affichées) |
| `tests/cluster.tftest.hcl` | Tests unitaires avec un faux fournisseur (sans cluster) |
| `.terraform.lock.hcl` | Version et empreintes du fournisseur, produit par `terraform init` |

## Droits d'un compte `deployer`

Chaque compte n'agit que dans **son** namespace, avec les seuls droits
dont `scripts/deploy.sh` (et, en `staging`, `scripts/zap-scan.sh`) a
besoin :

| Droit | Pourquoi |
|---|---|
| Gérer `configmaps`, `services`, `secrets` | Objets du chart ; Secret de la base ; historique des versions de Helm (rangé dans des Secrets) |
| Gérer `deployments`, `statefulsets`, `horizontalpodautoscalers`, `networkpolicies` | Front, back, base, HPA de la prod, pare-feu |
| Lire `pods`, `pods/log`, `events`, `persistentvolumeclaims`, `replicasets` | Attente des pods (`helm --wait`), diagnostic |
| Créer `pods/exec` | Test de fumée de `deploy.sh` |
| Lire **son** namespace (rôle de cluster limité à ce seul nom) | `deploy.sh` vérifie le niveau « restricted » |
| Gérer `jobs` (**`staging` seulement**) | Test d'intrusion ZAP (`scripts/zap-scan.sh`) |

Il ne peut pas : agir dans un autre namespace, créer des rôles ou des
comptes, lire les autres namespaces. Aucun joker `*`, droit `jobs`
réservé au deployer de `staging` (vérifiés par les tests). Son jeton n'est monté dans aucun pod.

## Utilisation

Prérequis : Terraform 1.17 ; le contexte `orion` dans le kubeconfig, avec
les droits d'administration du cluster.

```shell
cd infra/terraform

# 1. Une seule fois : l'état est rangé HORS du dépôt, car il contient
#    en clair les jetons des comptes deployer et l'adresse des alertes
mkdir -p -m 700 ~/.local/state/orion-terraform
terraform init \
  -backend-config="path=$HOME/.local/state/orion-terraform/terraform.tfstate"

# Si un namespace existe déjà (créé à la main), le rattacher à l'état
# au lieu de le recréer :
#   terraform import 'kubernetes_namespace_v1.env["dev"]' dev

# 2. Lire le plan, puis appliquer exactement ce plan ; le fichier
#    .tfvars doit exister AVANT (étape 1 de « Supervision », plus bas),
#    sinon Terraform demande l'adresse des alertes
terraform plan -var-file="$HOME/.local/state/orion-terraform/monitoring.tfvars" \
  -out="$HOME/.local/state/orion-terraform/tfplan"
terraform apply "$HOME/.local/state/orion-terraform/tfplan"
chmod 600 ~/.local/state/orion-terraform/*
```

Contrôles des droits, par exemple pour `dev` :

```shell
SA=system:serviceaccount:dev:deployer
kubectl auth can-i patch deployments -n dev --as=$SA    # yes
kubectl auth can-i patch deployments -n prod --as=$SA   # no
```

Chaque jeton est rangé, sans être affiché, dans le secret `KUBE_TOKEN`
de l'environnement GitHub correspondant (`dev`, `staging`,
`production`), et le certificat dans la variable de dépôt `KUBE_CA` ;
le job de déploiement les lit
([déploiement continu](../../README.md#déploiement-continu-ci)) :

```shell
terraform output -json deployer_tokens | jq -r .dev   # puis clear
terraform output -raw cluster_ca
```

## Supervision

La pile de supervision ([détails](../monitoring/README.md)) s'installe
avec le reste du socle. Quatre étapes, faites **une fois** par
l'Ops, dans son terminal :

```shell
# 1. Adresse Gmail des alertes : donnée personnelle, rangée HORS du dépôt
#    (à côté de l'état), lue par -var-file ; masquée dans le plan, mais
#    écrite en clair dans l'état
printf 'ops_email = "%s"\n' "ADRESSE@gmail.com" \
  > ~/.local/state/orion-terraform/monitoring.tfvars
chmod 600 ~/.local/state/orion-terraform/monitoring.tfvars

# 2. Plan puis application, comme plus haut (crée les 2 namespaces et
#    la pile)

# 3. Mot de passe d'application Gmail (compte Google → Sécurité → Mots de
#    passe des applications), saisi sans écho, jamais dans le dépôt ni
#    dans l'état Terraform ; Alertmanager démarre dès qu'il existe
#    (passé par l'entrée standard : jamais visible dans la liste des
#    processus)
read -rs -p "Gmail app password: " P; echo
printf '%s' "$P" | kubectl -n monitoring create secret generic \
  alertmanager-smtp --from-file=password=/dev/stdin; unset P

# 4. Première sauvegarde à la main, avec sa métrique : sans elle,
#    l'alerte BackupTooOld (« jamais sauvegardée ») part 15 min après
#    l'installation, avant la prochaine sauvegarde planifiée
BACKUP_METRICS_DIR=/var/lib/node_exporter/textfile scripts/backup.sh prod
```

## Tests

```shell
terraform test     # 6 tests, faux fournisseurs : aucun cluster nécessaire
```

| Test | Vérifie |
|---|---|
| `three_restricted_namespaces` | 3 namespaces, tous au niveau « restricted » |
| `deployer_rights_stay_in_their_namespace` | aucun jeton monté dans un pod ; aucun joker `*` ; lecture de son seul namespace |
| `unknown_environment_is_refused` | un environnement inconnu est refusé par la validation |
| `monitoring_namespaces_security` | `monitoring` en « restricted » ; le namespace du collecteur avertit de tout écart à « restricted » |
| `monitoring_stack_is_pinned` | chart de supervision à version figée ; un ConfigMap par tableau de bord (3) |
| `non_gmail_alert_address_is_refused` | une adresse d'alerte non Gmail est refusée |

Le job `terraform` de la CI lance `fmt -check`, `validate` et ces tests à
chaque PR.

**Vérifié le 02/11/2026** : `apply` (19 objets créés, `dev` et `staging`
importés sans interruption de l'application) ; second `plan` sans
changement ; `deploy.sh dev` réussi avec le seul jeton du `deployer` de
`dev`, `staging` refusé avec ce même jeton ; 4 erreurs volontaires
(niveau `baseline`, jeton monté, lecture de tous les namespaces, joker)
détectées par les tests.

## Sécurité

- État hors du dépôt (dossier 700, fichiers 600) : il contient les
  jetons ; plan enregistré au même endroit.
- Jetons et certificat marqués `sensitive` : jamais affichés par
  Terraform.
- Moindre privilège : un compte par environnement, enfermé dans son
  namespace.
- Version du fournisseur figée et vérifiée (`.terraform.lock.hcl`) ;
  mises à jour proposées par Dependabot.

## Limites connues et évolutions

| Limite | Évolution |
|---|---|
| Jetons de longue durée, rotation manuelle | Fédération d'identité OIDC entre GitHub et le cluster : jetons de quelques minutes, aucun secret stocké |
| Un `deployer` peut lire les Secrets de son namespace, dont le mot de passe de la base (Helm range ses versions dans des Secrets) | Inhérent à Helm ; à compenser par un mot de passe propre à chaque environnement (déjà le cas) et la rotation |
| État local sur une seule machine, sans verrou contre deux `apply` simultanés | État distant chiffré et verrouillé (par exemple S3 avec verrou, dans la cible cloud) |
| Terraform est sous licence BUSL (source disponible, pas open source) | OpenTofu, fork open source compatible, si la licence pose problème |
