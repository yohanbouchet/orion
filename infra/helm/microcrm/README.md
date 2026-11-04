# Chart Helm de MicroCRM

Ce chart déploie toute l'application dans **un namespace** du cluster
Minikube : front (nginx), back (Spring Boot) et base PostgreSQL. Le même
chart sert aux trois environnements `dev`, `staging` et `prod` ; seuls les
réglages changent (ticket #64).

```text
navigateur ──► microcrm-front (nginx, :8080)
                 │  /api/… relayé vers le back (préfixe /api retiré)
                 ▼
               microcrm-back (Spring Boot, :8080)
                 │  JDBC ; tables créées par Flyway
                 ▼
               microcrm-postgres (PostgreSQL 18, :5432, disque persistant)
```

## Fichiers

| Fichier | Rôle |
|---|---|
| `Chart.yaml` | Nom, version du chart, version de l'application (`appVersion`) |
| `values.yaml` | Réglages par défaut (images, ressources, base, pare-feu) |
| `values-dev.yaml`, `values-staging.yaml`, `values-prod.yaml` | Différences de chaque environnement |
| `templates/_helpers.tpl` | Étiquettes, noms, image, durcissement : écrits une seule fois |
| `templates/front.yaml` | Service et Deployment du front |
| `templates/front-nginx-config.yaml` | Relais `/api` (ConfigMap), inclus par `front/nginx.conf` |
| `templates/back.yaml` | Service, Deployment et HPA (si activé) du back |
| `templates/postgres.yaml` | Service et StatefulSet de la base, avec son disque |
| `templates/network-policy.yaml` | Pare-feu entre pods |

## Environnements

| | dev | staging | prod |
|---|---|---|---|
| Répliques du back | 1 | 1 | 2 à 4 (HPA, processeur > 70 %) |
| Disque de la base | 1 Gio | 2 Gio | 5 Gio |

Le HPA a besoin de l'addon **metrics-server** de Minikube
(`minikube -p orion addons enable metrics-server`).

## Sécurité

- **Aucun secret dans le chart** : le mot de passe de la base est lu dans
  le Secret `microcrm-db`, créé hors du chart avec une valeur aléatoire.
- **Conteneurs durcis**, conformes au niveau Pod Security
  **« restricted »** appliqué au namespace : utilisateur non root (101,
  1001, 70), aucune élévation de droits, aucune capacité Linux, disque
  système **en lecture seule** (seuls `/tmp` et les données sont
  inscriptibles), aucun jeton d'accès à l'API Kubernetes.
- **Pare-feu entre pods** (NetworkPolicy) : tout est refusé, pour
  **tous les pods du namespace** (même un pod lancé plus tard, hors du
  chart), sauf front → back → base et le DNS. En `staging` seulement
  (`networkPolicy.allowZap`), le pod du test d'intrusion ZAP peut joindre
  le front, et rien d'autre (ni Internet, ni le back, ni la base en
  direct). La base ne peut joindre personne, le back n'a pas accès à
  Internet.
- **Mises à jour sans coupure** : un nouveau pod doit être prêt avant
  qu'un ancien soit arrêté (`maxUnavailable: 0`) ; sondes de
  disponibilité et de vie sur chaque composant, plus une sonde de
  démarrage pour le back (Spring Boot démarre lentement).

## Installation

Les namespaces `dev`, `staging` et `prod` (niveau de sécurité
« restricted ») et les comptes qui ont le droit d'y déployer sont créés
une seule fois par Terraform : voir [`infra/terraform`](../../terraform/README.md).

```shell
# 1. Déploiement : Secret de la base (créé une seule fois, aléatoire),
#    helm lint, installation, test de fumée, retour arrière si besoin
scripts/deploy.sh dev

# 2. Accès depuis le poste : http://localhost:8080 (transfert de port
#    de VS Code)
kubectl -n dev port-forward svc/microcrm-front 8080:8080
```

Autre image : `scripts/deploy.sh dev sha-abc1234` (ou `v1.1.0`) ; retour
arrière : `scripts/deploy.sh rollback dev`. Détails :
[`scripts/README.md`](../../../scripts/README.md#deploysh).

## Limites connues

- La taille du disque de la base ne se change plus après la création
  (champ figé d'un StatefulSet).
- Le compte `microcrm` de l'application est **superutilisateur**
  PostgreSQL (réglage par défaut de l'image officielle) ; un compte aux
  droits limités, propriétaire du seul schéma de l'application, serait
  plus sûr.
- Sauvegardes : par `scripts/backup.sh`, avec leurs propres limites
  ([détails](../../../scripts/README.md#backupsh)).
- Ressources (`requests`, `limits`) : valeurs de départ, à ajuster après
  mesure avec metrics-server.
