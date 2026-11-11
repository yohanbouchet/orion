# Socle du cluster (fichiers Terraform, exécutés par OpenTofu)

Ces fichiers, écrits dans le langage de Terraform (HCL), décrivent le
**socle** du cluster Minikube : ce qui demande des droits sur tout le
cluster et ne change presque jamais. Ils sont exécutés par **OpenTofu**
(commande `tofu`), le successeur open source de Terraform (voir
[Passage à OpenTofu](#passage-à-opentofu-0911)). Helm
(`scripts/deploy.sh`) installe ensuite l'application **dans** ce socle
(ticket #64).

```text
OpenTofu (opérateur, droits d'administration)
  ├── namespace dev      ── compte deployer et ses droits
  ├── namespace staging  ── compte deployer et ses droits
  └── namespace prod     ── compte deployer et ses droits
      (chacun au niveau Pod Security « restricted » ; aucun jeton
      rangé : OpenBao en délivre de 15 min à la CI)
                 │
Helm (scripts/deploy.sh, avec le jeton court du deployer de l'environnement)
  └── MicroCRM dans le namespace : front, back, PostgreSQL
```

## Fichiers

| Fichier | Rôle |
|---|---|
| `versions.tf` | Versions exigées (OpenTofu 1.13, fournisseurs `hashicorp/kubernetes` 3.4.x, `hashicorp/helm` 3.3.x et `hashicorp/tls` 4.4.x) ; état local, rangé hors du dépôt |
| `providers.tf` | Connexion au cluster : kubeconfig de l'opérateur, contexte `orion` |
| `variables.tf` | Réglages : kubeconfig, contexte, environnements (`dev`, `staging`, `prod` seulement), version figée des règles Pod Security (`pod_security_version`, `v1.37`, `latest` refusé), adresse Gmail des alertes (`ops_email`, sensible, hors du dépôt) |
| `main.tf` | Un namespace par environnement, niveau Pod Security « restricted » |
| `rbac.tf` | Un compte `deployer` par namespace et ses droits (aucun jeton rangé depuis le 10/11) |
| `monitoring.tf` | Supervision : namespaces `monitoring` (« restricted ») et `monitoring-collector` (« privileged », collecteur de journaux seul), pile VictoriaMetrics + VictoriaLogs + Grafana (chart Helm figé), tableaux de bord ([détails](../monitoring/README.md)) |
| `openbao.tf` | Coffre-fort OpenBao : namespace `openbao` (« restricted »), autorité de certification et certificat TLS, chart Helm figé, droit d'OpenBao de créer des jetons courts des comptes `deployer` ([détails](../openbao/README.md)) |
| `outputs.tf` | Certificats publics : celui du cluster (`cluster_ca`) et celui de l'autorité d'OpenBao (`openbao_ca_cert`), copiés dans les variables `KUBE_CA` et `OPENBAO_CA` du dépôt ; plus aucun jeton depuis le 10/11 |
| `tests/cluster.tftest.hcl` | Tests unitaires avec de faux fournisseurs (sans cluster) |
| `.terraform.lock.hcl` | Versions et empreintes des fournisseurs (registre d'OpenTofu, signés), produit par `tofu init` |

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

Prérequis : OpenTofu 1.13 (installé par Ansible, rôle `ops_tools`) ; le
contexte `orion` dans le kubeconfig, avec les droits d'administration du
cluster.

```shell
cd infra/terraform

# 1. Une seule fois : l'état est rangé HORS du dépôt, car il contient
#    en clair les clés privées du certificat d'OpenBao et l'adresse
#    des alertes
mkdir -p -m 700 ~/.local/state/orion-terraform
tofu init \
  -backend-config="path=$HOME/.local/state/orion-terraform/terraform.tfstate"

# Si un namespace existe déjà (créé à la main), le rattacher à l'état
# au lieu de le recréer :
#   tofu import 'kubernetes_namespace_v1.env["dev"]' dev

# 2. Lire le plan, puis appliquer exactement ce plan ; le fichier
#    .tfvars doit exister AVANT (étape 1 de « Supervision », plus bas),
#    sinon OpenTofu demande l'adresse des alertes
tofu plan -var-file="$HOME/.local/state/orion-terraform/monitoring.tfvars" \
  -out="$HOME/.local/state/orion-terraform/tfplan"
tofu apply "$HOME/.local/state/orion-terraform/tfplan"
# Fichiers seulement : un chmod 600 sur un dossier (la sauvegarde
# d'avant OpenTofu) retire le droit d'y entrer
find ~/.local/state/orion-terraform -maxdepth 1 -type f -exec chmod 600 {} +
```

Contrôles des droits, par exemple pour `dev` :

```shell
SA=system:serviceaccount:dev:deployer
kubectl auth can-i patch deployments -n dev --as=$SA    # yes
kubectl auth can-i patch deployments -n prod --as=$SA   # no
```

**Aucun jeton de longue durée** (supprimés le 10/11/2026, après deux
pipelines complets réussis sans eux) : OpenBao délivre à la CI un jeton
de 15 min du même compte, contre le badge OIDC du job
([Identité de la CI](../openbao/README.md#identité-de-la-ci)) ;
OpenBao n'a que le droit d'en créer (`openbao.tf`). Les deux certificats
**publics** vont dans les variables de dépôt GitHub `KUBE_CA` et
`OPENBAO_CA` :

```shell
tofu output -raw cluster_ca        # lu dans la ConfigMap kube-root-ca.crt
tofu output -raw openbao_ca_cert
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
#    dans l'état OpenTofu ; Alertmanager démarre dès qu'il existe
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
tofu test     # 8 tests, faux fournisseurs : aucun cluster nécessaire
```

| Test | Vérifie |
|---|---|
| `three_restricted_namespaces` | 3 namespaces, tous au niveau « restricted » ; version des règles Pod Security figée (`v1.37`) sur les namespaces des environnements, de la supervision et d'OpenBao |
| `deployer_rights_stay_in_their_namespace` | aucun jeton monté dans un pod ; aucun joker `*` ; lecture de son seul namespace |
| `unknown_environment_is_refused` | un environnement inconnu est refusé par la validation |
| `unpinned_pod_security_is_refused` | une version de règles Pod Security non figée (`latest`) est refusée |
| `monitoring_namespaces_security` | `monitoring` en « restricted » ; le namespace du collecteur avertit de tout écart à « restricted » |
| `monitoring_stack_is_pinned` | chart de supervision à version figée ; un ConfigMap par tableau de bord (3) |
| `non_gmail_alert_address_is_refused` | une adresse d'alerte non Gmail est refusée |
| `openbao_is_locked_down` | namespace `openbao` en « restricted » ; chart figé (0.30.7) ; TLS gardé, injecteur désactivé, règle réseau, système de fichiers en lecture seule ; journal d'audit déclaré ; OpenBao ne peut créer que des jetons des comptes `deployer` ; clé de l'autorité en ECDSA |

Le job `opentofu` de la CI lance `tofu fmt -check`, `tofu validate` et
ces tests à chaque PR. Les fournisseurs y sont gardés en cache tant que
`.terraform.lock.hcl` ne change pas (toujours vérifiés par ses
empreintes) : une panne du registre ou de GitHub ne bloque plus ce
contrôle.

**Vérifié le 02/11/2026** (avec Terraform) : `apply` (19 objets créés,
`dev` et `staging` importés sans interruption de l'application) ;
second `plan` sans changement ; `deploy.sh dev` réussi avec le seul
jeton du `deployer` de `dev`, `staging` refusé avec ce même jeton ;
4 erreurs volontaires (niveau `baseline`, jeton monté, lecture de tous
les namespaces, joker) détectées par les tests.

## Passage à OpenTofu (09/11)

Terraform est passé en 2023 sous licence BUSL (code source visible, mais
pas open source). **OpenTofu** est son successeur open source (licence
MPL-2.0, projet de la Linux Foundation), compatible avec les mêmes
fichiers et le même état. Passage fait le 09/11/2026 :

1. OpenTofu 1.13.9 installé (signature GPG d'OpenTofu vérifiée, clé
   recoupée sur keys.openpgp.org, empreinte SHA-256 contrôlée).
2. Sur une **copie** de l'état : `tofu init`, `tofu validate`,
   `tofu plan` → **« No changes »** : OpenTofu lit l'état écrit par
   Terraform et ne recrée rien.
3. Avertissement d'OpenTofu corrigé (plus strict que Terraform) : les
   boucles de `rbac.tf` parcouraient l'objet complet des comptes, dont
   un attribut déprécié (`default_secret_name`) ; elles parcourent
   désormais leurs seules métadonnées (mêmes clés : rien n'est recréé).
4. Tests : les faux fournisseurs d'OpenTofu remplissent les attributs
   calculés d'une table vide ; jeton et certificat fictifs ajoutés au
   test (6 tests verts).
5. Fichier de verrouillage refait par `tofu init` : fournisseurs du
   registre d'OpenTofu (`registry.opentofu.org`), signés.
6. Étiquette `app.kubernetes.io/managed-by` des namespaces et des
   tableaux de bord : `terraform` → `opentofu` (elle nomme l'outil qui
   gère l'objet) ; plan sur la copie : 8 mises à jour sur place, rien
   de créé ni de supprimé.
7. Après la fusion, sur le vrai état : sauvegarde de l'état,
   `tofu init -reconfigure`, `tofu plan` (ces 8 étiquettes seulement),
   puis `tofu apply`.

Le dossier garde son nom (`infra/terraform`, état dans
`~/.local/state/orion-terraform`) : le langage reste celui de Terraform.

## Sécurité

- État hors du dépôt (dossier 700, fichiers 600) : il contient les clés
  privées du certificat d'OpenBao et l'adresse des alertes ; plan
  enregistré au même endroit.
- Aucun jeton dans l'état ni dans GitHub ; adresse des alertes marquée
  `sensitive` : jamais affichée par OpenTofu.
- Moindre privilège : un compte par environnement, enfermé dans son
  namespace.
- Versions des fournisseurs figées et vérifiées (`.terraform.lock.hcl`,
  signatures du registre d'OpenTofu) ; mises à jour proposées par
  Dependabot (écosystème `opentofu`).
- OpenTofu lui-même : archive officielle, empreinte vérifiée à
  l'installation (Ansible, empreinte tirée du fichier signé) ; dans la
  CI, version figée et empreinte contrôlée par `opentofu/setup-opentofu`.

## Limites connues et évolutions

| Limite | Évolution |
|---|---|
| Un `deployer` peut lire les Secrets de son namespace, dont le mot de passe de la base (Helm range ses versions dans des Secrets) | Inhérent à Helm ; à compenser par un mot de passe propre à chaque environnement (déjà le cas) et la rotation |
| État local sur une seule machine, sans verrou contre deux `apply` simultanés | État distant chiffré et verrouillé (par exemple S3 avec verrou, dans la cible cloud) |
| Le certificat d'OpenBao (valable jusqu'au 09/11/2027) n'est renouvelé que si quelqu'un lance `tofu plan` ; aucune alerte avant l'échéance | Alerte de la supervision 30 jours avant, ou cert-manager |
| Deux briques hors du socle : le runner local (ARC) et SonarQube sont installés à la main (README du dépôt) | Les décrire ici (`helm_release`), ou GitOps |
| Pas de module : deux dossiers de quelques fichiers, lus tels quels | Modules (`terraform-aws-modules` : réseau, EKS) dans la cible AWS, où le code se répète |
