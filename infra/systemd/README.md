# Démarrage automatique du cluster Minikube

Le cluster Minikube `orion` héberge le runner local de la CI (ARC) et
SonarQube. Sans ce service, il reste éteint après un redémarrage de la
machine : le job `sonarqube` reste alors « Queued » et les PR sont bloquées
(risque « runner local indisponible » du
[plan CI, section 3.5](../../docs/02-normalisation-plan-ci.md#35-gestion-des-risques),
ticket #29).

`minikube@.service` est un **modèle** de service systemd :

- il démarre le cluster **après Docker** et l'arrête proprement **avant
  Docker** à l'extinction ;
- il tourne sous l'utilisateur indiqué après le `@` (`%i`), **pas en root** ;
- aucun nom d'utilisateur ni chemin propre à une machine n'est versionné :
  chaque membre de l'équipe Ops l'installe sur son poste.

## Prérequis

- Docker installé et activé au démarrage (`systemctl is-enabled docker`).
- L'utilisateur est membre du groupe `docker`.
- `minikube` est installé dans `~/.local/bin` de cet utilisateur et le profil
  `orion` existe déjà (`minikube profile list`).

## Installation

Depuis la racine du dépôt :

```bash
# 1. Vérifier le fichier (aucune sortie = aucune erreur)
systemd-analyze verify infra/systemd/minikube@.service

# 2. Copier le modèle : propriétaire root, lisible par tous, modifiable
#    par root seulement
sudo install -m 644 infra/systemd/minikube@.service /etc/systemd/system/
sudo systemctl daemon-reload

# 3. Activer l'instance de l'utilisateur courant et la lancer
sudo systemctl enable --now "minikube@$USER.service"
```

Le shell remplace `$USER` par le nom de l'utilisateur avant l'exécution de
`sudo` : ce nom n'apparaît que sur la machine.

## Vérification

| Commande | Résultat attendu |
| --- | --- |
| `systemctl is-enabled "minikube@$USER.service"` | `enabled` |
| `systemctl status "minikube@$USER.service"` | `active (exited)` : normal pour un service `oneshot` |
| `journalctl -u "minikube@$USER.service"` | `Done!` au démarrage, `1 node stopped` à l'arrêt |
| `kubectl --context orion get pods -A` | pods ARC et SonarQube `Running` |

Test réalisé le 31/10/2026 : après `sudo reboot`, Docker démarre, puis le
service (26 s), puis tous les pods sont prêts, sans aucune action manuelle.
À l'extinction, le cluster s'arrête proprement en 6 s.

## Dépannage et relance

- **Le job `sonarqube` reste « Queued »** : vérifier le service
  (`systemctl status "minikube@$USER.service"`), le relancer si besoin
  (`sudo systemctl restart "minikube@$USER.service"`), puis relancer le job
  dans GitHub (« Re-run failed jobs ») : les jobs annoncés pendant la panne ne
  sont pas renvoyés au runner.
- **Le service est en échec** : lire `journalctl -u "minikube@$USER.service"
  -n 50`. Un démarrage qui dépasse 10 minutes est interrompu
  (`TimeoutStartSec`).
- **Le message « kubectl not found » dans le journal** est sans gravité :
  systemd n'utilise pas le `PATH` de l'utilisateur, et minikube n'a pas besoin
  de kubectl pour démarrer.

## Désinstallation

```bash
sudo systemctl disable --now "minikube@$USER.service"
sudo rm /etc/systemd/system/minikube@.service
sudo systemctl daemon-reload
```

## Limites

- Le membre du groupe `docker` a des droits proches de root sur la machine
  ([documentation Docker](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)) :
  acceptable sur un poste de laboratoire, à éviter sur un serveur partagé.
- Le chemin `~/.local/bin/minikube` et le profil `orion` sont écrits dans le
  modèle. L'installation pourra être automatisée par Ansible (phase 6).
