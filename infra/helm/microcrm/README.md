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
- **Pare-feu entre pods** (NetworkPolicy) : tout est refusé, sauf
  front → back → base et le DNS. Le front accepte en plus le runner de la
  CI (tests ZAP). La base ne peut joindre personne, le back n'a pas accès
  à Internet.
- **Mises à jour sans coupure** : un nouveau pod doit être prêt avant
  qu'un ancien soit arrêté (`maxUnavailable: 0`) ; sondes de démarrage,
  de disponibilité et de vie sur chaque composant.

## Installation à la main (dev)

Le script `scripts/deploy.sh` automatisera ces étapes (ticket #56).

```shell
# 1. Namespace, avec le niveau de sécurité « restricted »
kubectl create namespace dev
kubectl label namespace dev pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

# 2. Secret de la base : valeur aléatoire, jamais affichée ni versionnée
kubectl -n dev create secret generic microcrm-db \
  --from-literal=password="$(openssl rand -hex 32)"

# 3. Contrôles, puis installation ; en cas d'échec, retour automatique à
#    la version précédente (--rollback-on-failure, Helm 4)
helm lint infra/helm/microcrm
helm upgrade --install microcrm infra/helm/microcrm -n dev \
  -f infra/helm/microcrm/values-dev.yaml --rollback-on-failure --wait

# 4. Accès depuis le poste : http://localhost:8080 (transfert de port
#    de VS Code)
kubectl -n dev port-forward svc/microcrm-front 8080:8080
```

Version d'une autre image : `--set front.image.tag=sha-abc1234` (et de même
pour `back`).

## Limites connues

- La taille du disque de la base ne se change plus après la création
  (champ figé d'un StatefulSet).
- Les sondes du back testent la racine de l'API (`/`) : elle ne vérifie
  pas la base. Spring Boot Actuator donnerait un vrai contrôle de santé.
- L'application utilise le compte propriétaire de la base ; un compte aux
  droits limités serait plus sûr.
- Ressources (`requests`, `limits`) : valeurs de départ, à ajuster après
  mesure avec metrics-server.
