# OpenBao : le coffre-fort de secrets

OpenBao (licence MPL-2.0, fondation Linux, successeur open source de
HashiCorp Vault) garde les secrets de la chaîne et délivre des **accès
de courte durée**. Il sert de guichet d'identité à la CI (10/11/2026) :
un badge OIDC signé par GitHub contre un jeton Kubernetes de 15 min,
à la place des jetons longue durée rangés jusque-là dans GitHub
([Identité de la CI](#identité-de-la-ci)).

Installé le 09/11/2026 par OpenTofu
([`infra/terraform/openbao.tf`](../terraform/openbao.tf)), réglages du
chart dans [`values.yaml`](values.yaml).

| Brique | Version | Licence |
| --- | --- | --- |
| OpenBao | 2.7.2 (26/10/2026, branche 2.7 maintenue) | MPL-2.0 |
| Chart Helm `openbao` | 0.30.7 (06/11/2026) | MPL-2.0 |
| Fournisseur OpenTofu `hashicorp/tls` (certificat) | 4.4.2 | MPL-2.0 |

## Ce qui est installé

```text
namespace openbao (Pod Security « restricted »)
  ├── openbao-0 (StatefulSet, 1 serveur)
  │     ├── API en HTTPS (TLS 1.3 seulement) sur 8200
  │     ├── stockage intégré Raft : disque de 1 Gi, chiffré par OpenBao
  │     └── utilisateur 100, aucune capacité, disque système en lecture seule
  ├── Secret openbao-tls : certificat signé par une autorité propre au
  │     cluster (créée par OpenTofu, clés ECDSA P-256, 1 an)
  └── NetworkPolicy : entrée seulement depuis arc-runners (CI)
```

Choix et alternatives écartées :

| Choix | Pourquoi | Écarté |
| --- | --- | --- |
| Stockage **Raft** | « production ready » selon la documentation, sauvegarde à chaud (`bao operator raft snapshot`) | PebbleDB : arrivé en 2.7.0, pas présenté comme prêt pour la production ; `file` : retiré en 2.7 |
| **TLS** même dans le cluster | OpenBao transporte des secrets (chiffrement des échanges internes, OWASP ASVS) | `tlsDisable: true`, réglage par défaut du chart |
| Autorité de certification **créée par OpenTofu** | aucune autorité publique ne signe un nom en `.svc` ; rien à installer en plus | cert-manager : une brique de plus à maintenir pour un seul certificat |
| **Déverrouillage manuel** chaque matin | sans service de clés externe (KMS d'un cloud), c'est la seule façon de ne pas laisser la clé à côté du coffre | déverrouillage automatique : il demande un KMS (AWS KMS dans la cible cloud) |
| Clés en **3 parts, 2 suffisent** (Shamir) | la perte d'une part ne bloque pas le coffre | 1 part : la perdre, c'est perdre le coffre |
| Pas d'injecteur, pas de droit `auth-delegator` | inutiles ici : moins de composants et de droits | réglages par défaut du chart |

## Démarrage

### 1. Installer (Ops, une fois)

```shell
cd infra/terraform
tofu init -backend-config="path=$HOME/.local/state/orion-terraform/terraform.tfstate"
tofu plan -var-file="$HOME/.local/state/orion-terraform/monitoring.tfvars" \
  -out="$HOME/.local/state/orion-terraform/tfplan"
tofu apply "$HOME/.local/state/orion-terraform/tfplan"
find ~/.local/state/orion-terraform -maxdepth 1 -type f -exec chmod 600 {} +
kubectl -n openbao get pods   # openbao-0 Running, 0/1 : scellé, normal
```

### 2. Initialiser (Ops, une seule fois de toute la vie du coffre)

```shell
kubectl -n openbao exec -it openbao-0 -- \
  bao operator init -key-shares=3 -key-threshold=2
```

La commande affiche **3 clés de déverrouillage** et le **jeton racine**,
une seule fois : les ranger **tout de suite** dans Bitwarden (une note
sécurisée par clé, une pour le jeton), puis `clear` dans le terminal.
Ils ne sont écrits nulle part ailleurs : ni dans le dépôt, ni sur le
disque, ni dans GitHub.

### 3. Déverrouiller (Ops, chaque matin et après tout redémarrage)

Un OpenBao redémarré est **scellé** : il a ses données, mais pas la
clé pour les lire. Deux des trois clés suffisent :

```shell
kubectl -n openbao exec -it openbao-0 -- bao operator unseal   # clé 1
kubectl -n openbao exec -it openbao-0 -- bao operator unseal   # clé 2
kubectl -n openbao exec openbao-0 -- bao status | grep Sealed  # false
```

La clé est demandée **sans s'afficher** : elle n'entre pas dans
l'historique du shell. Oubli : l'alerte `OpenBaoSealed` envoie un
e-mail après 15 min ([supervision](../monitoring/README.md#openbaosealed)).

En entreprise, pas de geste manuel : 3 serveurs (un redémarrage ne coupe
pas le service) et **déverrouillage automatique** par un service de clés
externe : KMS d'un cloud, boîtier matériel (HSM, protocole PKCS#11 ou
KMIP) ou un second OpenBao (*Transit*) ; les parts de Shamir deviennent
des clés de récupération réparties entre plusieurs personnes. Écarté
ici : la clé « statique » sur le disque du poste, posée à côté du coffre.
Comparatif : [Déverrouillage automatique](#déverrouillage-automatique--comparatif).

### Journal d'audit

Chaque demande faite à OpenBao est écrite en JSON sur la sortie du
conteneur, donc collectée par vlagent (VictoriaLogs) ; secrets et
jetons y sont remplacés par leur empreinte (HMAC). Il est **déclaré
dans la configuration** ([`values.yaml`](values.yaml), bloc `audit`) :
depuis la 2.3.2, OpenBao refuse de l'activer par l'API (un opérateur
pourrait écrire des fichiers n'importe où sur l'hôte : constaté le
09/11, « cannot enable audit device via API ») ; il ne peut donc pas
être coupé sans une PR. Contrôle :

```shell
kubectl -n openbao logs openbao-0 | grep '"type":"request"' | tail -1
```

Un changement de la configuration (ConfigMap) n'est lu qu'au
démarrage : après le `tofu apply`, redémarrer le pod
(`kubectl -n openbao delete pod openbao-0`), puis le déverrouiller.

## Identité de la CI

Plus aucun jeton du cluster n'est rangé dans GitHub. Chaque job qui
touche au cluster (déploiement, ZAP, test de charge) **prouve qui il
est**, et reçoit un accès qui expire seul :

```text
job GitHub (runner local, environnement dev / staging / production)
  1. demande à GitHub son badge OIDC (jeton signé, quelques minutes) :
     dépôt, branche, environnement, workflow ; audience « openbao-orion »
  2. le présente à OpenBao (auth/jwt, rôle ci-<environnement>)
       OpenBao vérifie la signature (clés publiques de GitHub) et
       chaque condition du rôle → jeton OpenBao, règle ci-<env> seule
  3. demande kubernetes/creds/<environnement>
       OpenBao demande à Kubernetes (TokenRequest) un jeton du compte
       deployer de CE namespace → 15 min (45 min pour ZAP et k6)
  4. écrit son kubeconfig, déploie ; le jeton expire seul
```

| Condition du rôle `ci-<env>` | Ce qu'elle empêche |
| --- | --- |
| `repository_id` = 1436771310 | un autre dépôt, même renommé ou recréé sous le même nom |
| `sub` = `repo:yohanbouchet@184980551/orion@1436771310:environment:<env>` (format « immuable » de GitHub, avec les numéros du propriétaire et du dépôt) | un job d'un autre environnement, ou sans environnement (approbation de production contournée) ; un dépôt recréé sous le même nom |
| `ref` = `refs/heads/main` | une branche, une PR |
| `job_workflow_ref` : `deploy.yml` (+ `zap.yml`, `load-test.yml` en staging) | un autre workflow, même dans le dépôt |
| audience `openbao-orion` | un badge demandé pour un autre service |

Les droits ne changent pas : le compte `deployer` garde ceux de
[`rbac.tf`](../terraform/rbac.tf) ; seule la **durée** de l'accès change.
OpenBao n'a, dans chaque namespace, que le droit de créer un jeton de
ce compte (rôle `openbao-token-issuer`,
[`openbao.tf`](../terraform/openbao.tf)).

Configuration écrite en OpenTofu, dans un dossier à part
([`config/`](config/)), avec son propre état : un plan du socle n'a pas
besoin du coffre ouvert.

| Fichier | Rôle |
| --- | --- |
| [`config/main.tf`](config/main.tf) | méthode `jwt` (badges GitHub), rôles et règles par environnement, moteur `kubernetes` (jetons courts) |
| [`config/variables.tf`](config/variables.tf) | dépôt autorisé, environnements, namespaces, workflows, durées (10 à 45 min, contrôlées) |
| [`config/providers.tf`](config/providers.tf), [`config/versions.tf`](config/versions.tf) | fournisseur `hashicorp/vault` 5.13 (MPL-2.0, même API qu'OpenBao), HTTPS vérifié |
| [`config/sonarqube.tf`](config/sonarqube.tf) | moteur `kv` (secrets statiques), rôle et règle `ci-sonarqube` (lecture du seul jeton SonarQube) |
| [`config/tests/`](config/tests/) | 5 tests (`tofu test`, faux fournisseur) : conditions des rôles, règles limitées, jetons courts, durée refusée, rôle SonarQube |

### Appliquer la configuration (Ops, coffre déverrouillé)

Le jeton racine est saisi sans écho et n'existe que dans ce terminal :

```shell
# Terminal 1 : tunnel vers OpenBao (laisser ouvert)
kubectl -n openbao port-forward svc/openbao 8200:8200

# Terminal 2
cd infra/openbao/config
mkdir -p -m 700 ~/.local/state/orion-openbao
(cd ../../terraform && tofu output -raw openbao_ca_cert) \
  > ~/.local/state/orion-openbao/openbao-ca.pem
tofu init -backend-config="path=$HOME/.local/state/orion-openbao/terraform.tfstate"
printf 'Root token: '; read -rs VAULT_TOKEN; echo; export VAULT_TOKEN
tofu plan -var="openbao_ca_file=$HOME/.local/state/orion-openbao/openbao-ca.pem" \
  -out="$HOME/.local/state/orion-openbao/tfplan"
tofu apply "$HOME/.local/state/orion-openbao/tfplan"
unset VAULT_TOKEN
find ~/.local/state/orion-openbao -maxdepth 1 -type f -exec chmod 600 {} +
```

Côté GitHub, une seule valeur, **publique** : la variable de dépôt
`OPENBAO_CA` (certificat de l'autorité, `tofu output -raw
openbao_ca_cert` dans `infra/terraform`).

### Jeton SonarQube

SonarQube ne sait pas créer de jetons courts : son jeton d'analyse
(limité au projet) reste de longue durée, mais il est rangé dans
OpenBao (moteur `kv` version 2, chemin `kv/ci/sonarqube`) et plus dans
GitHub. Le job `sonarqube` le lit avec l'action
[`openbao-secret`](../../.github/actions/openbao-secret/action.yml)
(rôle `ci-sonarqube` : environnement `sonarqube`, workflow `ci.yml`,
`main` ou une PR du dépôt, lecture de ce seul chemin,
[`config/sonarqube.tf`](config/sonarqube.tf)). Chaque lecture est
tracée dans l'audit.

La **valeur** n'est jamais dans OpenTofu (elle finirait dans l'état) :
l'Ops l'écrit, saisie sans écho (jeton racine, puis jeton SonarQube) :

```shell
kubectl -n openbao exec -it openbao-0 -- sh -c \
  'printf "Root token: "; read -rs BAO_TOKEN; echo; export BAO_TOKEN;
   printf "SonarQube token: "; read -rs SONAR; echo;
   printf "%s" "$SONAR" | bao kv put -mount=kv ci/sonarqube token=-'
```

Rotation : nouveau jeton dans SonarQube (My Account → Security), même
commande (nouvelle version), puis révocation de l'ancien dans SonarQube.

## Déverrouillage automatique : comparatif

Évolution étudiée le 10/11/2026 (documentation d'OpenBao 2.7,
« Seals ») : remplacer le geste du matin par un service de clés
externe. Coût en **niveaux** (pas de montant : il dépend du contrat et
du volume) ; « testé » = cité par OpenBao dans ses modèles testés.

| Solution | Principe | Avantages | Inconvénients | Coût | Origine, licence |
| --- | --- | --- | --- | --- | --- |
| **Manuel, Shamir** (aujourd'hui) | 2 parts de clé sur 3, saisies par l'Ops | aucune dépendance ; la clé n'est jamais à côté du coffre | geste à chaque redémarrage ; service coupé jusque-là (alerte `OpenBaoSealed`) | nul | intégré à OpenBao (MPL-2.0) |
| **AWS KMS** | la clé du coffre est chiffrée par une clé KMS ; OpenBao s'ouvre seul, avec son rôle IAM | géré, haute disponibilité ; chaque ouverture tracée (CloudTrail) | dépend d'AWS et du réseau ; à réserver à la cible cloud | faible, à l'usage | Amazon (États-Unis), service propriétaire |
| **OVHcloud KMS** (protocole KMIP, intégré à OpenBao, **testé**) | même principe, chez un hébergeur européen | souveraineté (hébergeur français) ; pas de matériel à gérer | dépend d'OVHcloud et du réseau | faible, à l'usage | OVHcloud (France), service propriétaire |
| **HSM** (PKCS#11, module à installer depuis la 2.7) | boîtier matériel : la clé ne sort jamais du boîtier | le plus sûr ; souvent déjà présent (certificats, signatures) ; certifications de sécurité | achat, maintenance, au moins 2 boîtiers pour la disponibilité ; clé à créer avant l'initialisation | élevé (achat) ; partagé s'il existe déjà | **testés** : Utimaco (Allemagne), Securosys (Suisse), Nitrokey NetHSM (Allemagne, code ouvert), DuoKey ; Thales Luna (groupe français) : PKCS#11 standard, **absent de la liste testée**, à valider avant de le choisir |
| **Transit** (second OpenBao) | un petit OpenBao, très protégé, garde la clé du premier | 100 % open source, aucun achat, tout reste sur site | un second coffre à exploiter, lui-même déverrouillé à la main (rarement : il ne redémarre presque jamais) | moyen (exploitation) | OpenBao (MPL-2.0) |
| Clé statique (fichier ou variable) | la clé est lue sur le disque du serveur | automatique, gratuit | la clé est **à côté du coffre** : voler le disque, c'est ouvrir le coffre ; la documentation met en garde | nul | intégré à OpenBao |

**Recommandation** : cible AWS → **AWS KMS** (rien à exploiter) ; sur
site avec exigence de souveraineté → **OVHcloud KMS** (KMIP, testé) ou
un **HSM** testé, Thales seulement après validation ; petite équipe sur
site sans budget → **Transit**. Ici, poste unique : le manuel reste le
bon choix, avec l'alerte.

## Sauvegarde

```shell
kubectl -n openbao exec -it openbao-0 -- sh -c \
  'printf "Token: "; read -rs BAO_TOKEN; echo; export BAO_TOKEN;
   bao operator raft snapshot save /tmp/openbao.snap'
kubectl -n openbao cp openbao-0:/tmp/openbao.snap ./openbao.snap
kubectl -n openbao exec openbao-0 -- rm /tmp/openbao.snap
```

L'instantané reste chiffré (il faut les clés pour le relire).

## Certificat

Valable 1 an. `tofu plan` propose de le renouveler 30 jours avant la
fin ; après le `tofu apply`, redémarrer le pod pour qu'il le charge,
puis le déverrouiller :

```shell
kubectl -n openbao delete pod openbao-0
```

Certificat public de l'autorité (à donner aux clients) :
`tofu output -raw openbao_ca_cert`.

## Sécurité

- Testé dans un namespace jetable « restricted » avant l'installation
  (09/11) : accepté sans avertissement ; disque système en lecture
  seule (`touch /x` refusé) ; TLS 1.2 refusé, HTTP refusé, certificat
  inconnu refusé ; pare-feu : bloqué depuis `dev`, ouvert depuis
  `arc-runners` ; après redémarrage, scellé, puis déverrouillé par 2
  autres clés sur 3 ; données conservées.
- Clés de déverrouillage et jeton racine : seulement dans le Bitwarden
  de l'Ops. Le jeton racine ne sert qu'à la configuration initiale ;
  ensuite, révocation, et un nouveau jeton se fabrique avec les clés
  (`bao operator generate-root`) si besoin.
- Clés privées du certificat : dans l'état OpenTofu (hors du dépôt,
  600) et dans le Secret `openbao-tls`.

## Limites

| Limite | Évolution |
| --- | --- |
| Un seul serveur : s'il tombe, la CI ne peut plus se connecter (l'application, elle, continue) | 3 serveurs Raft (le chart le permet : `server.ha`) sur plusieurs nœuds |
| Déverrouillage manuel après chaque redémarrage (rappel : alerte `OpenBaoSealed`) | déverrouillage automatique ([comparatif](#déverrouillage-automatique--comparatif)) : AWS KMS dans la cible cloud ; sur site, OVHcloud KMS, HSM ou second OpenBao (*Transit*) |
| Sortie réseau ouverte (API de Kubernetes, clés publiques de GitHub) | la limiter à ces deux adresses |
| Les 3 parts de clé sont chez une seule personne | en équipe : une part par personne |
| La configuration d'OpenBao est appliquée avec le jeton racine | méthode d'authentification propre à l'Ops (OIDC de l'entreprise), jeton racine révoqué |
| Un jeton Kubernetes ne peut pas être révoqué avant sa fin (limite de Kubernetes) | durées déjà courtes (15 min ; 45 min pour les tests longs de staging) |
| Jeton SonarQube de longue durée (SonarQube ne crée pas de jetons courts), lisible par un job de PR du dépôt (comme avant dans GitHub) | rotation régulière ; jeton à date d'expiration (réglage de SonarQube) |
