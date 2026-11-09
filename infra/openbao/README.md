# OpenBao : le coffre-fort de secrets

OpenBao (licence MPL-2.0, fondation Linux, successeur open source de
HashiCorp Vault) garde les secrets de la chaîne et délivre des **accès
de courte durée**. Il servira de guichet d'identité à la CI : un badge
OIDC de GitHub contre un jeton Kubernetes de quelques minutes, à la
place des jetons longue durée rangés aujourd'hui dans GitHub.

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
l'historique du shell.

### 4. Activer le journal d'audit (Ops, une fois, après le 2)

Chaque demande faite à OpenBao est écrite sur la sortie du conteneur,
donc collectée par vlagent (VictoriaLogs) ; les secrets y sont
remplacés par leur empreinte (HMAC) :

```shell
kubectl -n openbao exec -it openbao-0 -- sh -c \
  'printf "Root token: "; read -rs BAO_TOKEN; echo; export BAO_TOKEN;
   bao audit enable file file_path=stdout'
```

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
| Déverrouillage manuel après chaque redémarrage | déverrouillage automatique par un KMS (AWS KMS dans la cible cloud) |
| Sortie réseau ouverte (API de Kubernetes, clés publiques de GitHub) | la limiter à ces deux adresses |
| Les 3 parts de clé sont chez une seule personne | en équipe : une part par personne |
