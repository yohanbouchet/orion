# Headlamp : voir le cluster dans un navigateur, en lecture seule

Headlamp (projet `kubernetes-sigs` de Kubernetes, licence Apache 2.0) est
une interface web du cluster : namespaces, pods, journaux, déploiements,
événements, ressources consommées. Elle complète `kubectl` et Grafana
pour l'Ops ; elle ne remplace ni la supervision ni les alertes.

Installée le 12/11/2026 par OpenTofu
([`infra/terraform/headlamp.tf`](../terraform/headlamp.tf)), réglages du
chart dans [`values.yaml`](values.yaml).

| Brique | Version | Licence |
| --- | --- | --- |
| Headlamp (image figée par empreinte) | 0.46.0 (15/10/2026) | Apache 2.0 |
| Chart Helm `headlamp` | 0.46.0 (16/10/2026) | Apache 2.0 |

## Sécurité : lecture seule, de bout en bout

| Choix | Pourquoi | Réglage par défaut du chart, écarté |
| --- | --- | --- |
| Le compte de Headlamp n'a **aucun droit** | l'interface ne sait rien faire seule : chaque personne se connecte avec SON jeton | compte lié à **`cluster-admin`** (tous les droits sur tout le cluster) |
| Connexion avec un jeton du compte `headlamp-viewer`, rôle **`view`** de Kubernetes | tout voir (pods, journaux, déploiements), **rien modifier**, et jamais lire les Secrets | — |
| Jeton **court** (1 h), créé à la demande | rien de permanent à voler ; il expire seul | jeton de longue durée rangé dans un Secret |
| Session de l'interface : 1 h | même durée que le jeton | 24 h |
| Namespace « restricted », conteneur sans root, sans capacité, disque système en lecture seule | même niveau que l'application ; vérifié par une simulation dans `dev` (aucun avertissement) | sécurité incomplète (ni `readOnlyRootFilesystem`, ni `capabilities`) |
| Aucune entrée réseau (NetworkPolicy) ; accès par tunnel seulement | rien d'exposé, comme Grafana et SonarQube | — |

Ces réglages sont vérifiés par `tofu test` (test
`headlamp_is_read_only`) : remettre `cluster-admin` fait échouer la CI.

## Installer (Ops, une fois)

Avec le reste du socle :

```shell
cd infra/terraform
tofu plan -var-file="$HOME/.local/state/orion-terraform/monitoring.tfvars" \
  -out="$HOME/.local/state/orion-terraform/tfplan"
tofu apply "$HOME/.local/state/orion-terraform/tfplan"
find ~/.local/state/orion-terraform -maxdepth 1 -type f -exec chmod 600 {} +
kubectl -n headlamp get pods   # headlamp-… 1/1 Running
```

## Utiliser

```shell
# Terminal 1 : tunnel (laisser ouvert), puis http://localhost:4466
# (onglet PORTS de VS Code)
kubectl -n headlamp port-forward svc/headlamp 4466:80

# Terminal 2 : jeton de connexion, valable 1 h, à coller dans Headlamp
kubectl -n headlamp create token headlamp-viewer --duration=1h
```

Le jeton s'affiche une fois : le coller dans l'écran de connexion, puis
`clear`. Il n'est écrit nulle part.

## Limites

| Limite | Évolution |
| --- | --- |
| Accès par tunnel depuis le poste Ops seulement | en équipe : derrière l'authentification de l'entreprise (OIDC), chaque personne avec ses droits |
| Un seul niveau de droits (lecture) | rôles par équipe (Dev : leurs namespaces ; Ops : plus large), selon le besoin |
| Image et chart mis à jour à la main | suivi des versions avec les autres outils (README racine) |
