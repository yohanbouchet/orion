# Configuration du poste Ops (Ansible)

Terraform crée ce qui vit **dans** le cluster (namespaces, comptes de
déploiement). Ansible configure et **durcit la machine** qui l'héberge :
une seule commande, relançable sans effet si tout est déjà en place
(**idempotente**).

| Rôle | Ce qu'il fait | Pourquoi |
|---|---|---|
| `ops_tools` | kubectl 1.37.2, minikube 1.39.0, helm 4.3.1 dans `~/.local/bin`, **empreinte SHA-256 vérifiée** ; contrôle de Terraform ≥ 1.17 | mêmes versions sur chaque poste Ops, sans sudo |
| `docker_hygiene` | journaux des conteneurs limités (3 × 10 Mo), `live-restore` ; **nettoyage chaque dimanche** des images et du cache de plus de 7 jours (jamais les volumes) | le disque plein est la 1re cause de panne d'un serveur unique (mesuré le 04/11 : 39 Go d'images et 16 Go de cache récupérables) |
| `minikube_service` | service `minikube@<utilisateur>` ([`infra/systemd`](../systemd/README.md)) activé | le cluster redémarre avec la machine |
| `cluster_images` | images `orion/postgres`, `orion/zap`, `orion/actions-runner` construites et chargées dans Minikube **seulement si elles manquent ou si leur Dockerfile a changé** | le cluster ne télécharge jamais ces images |
| `metrics_server` | addon metrics-server **0.9.1**, figé par empreinte (Minikube installe sinon la 0.9.0) | autoscaling (HPA) de la prod ; correctif de sécurité de la 0.9.1 |
| `backup` | sauvegarde de la base de prod **chaque nuit** (2 h 30) et **vérification de la restauration chaque dimanche** (3 h 30), journal dans `~/.local/state/microcrm-backup.log` | RPO de 24 h ; une sauvegarde jamais restaurée n'est pas une sauvegarde |
| `node_exporter` | node_exporter 1.12.1 (métriques de la machine : disque, mémoire), compte système sans shell, service durci, écoute **seulement** sur le réseau du cluster ; lit aussi le dossier `/var/lib/node_exporter/textfile`, où `backup.sh` écrit l'heure de la dernière sauvegarde | supervision de l'hôte (alertes « disque presque plein » et « sauvegarde trop ancienne ») |
| `hardening` | mises à jour de sécurité automatiques ; pare-feu **ufw** (entrée refusée, sauf SSH depuis le réseau local et métriques depuis le cluster) ; **fail2ban** sur SSH | surface d'attaque réduite |

Une dernière étape **vérifie** l'état obtenu : service du cluster activé,
node_exporter et fail2ban actifs, métriques lisibles depuis le réseau du
cluster, tâches planifiées présentes, pare-feu actif.

## Utilisation

Prérequis : Ubuntu (sudo classique `sudo.ws`, installé d'office), Docker, le
profil Minikube `orion` déjà créé, Ansible (ansible-core 2.21).

```shell
cd infra/ansible

# 1. Collections aux versions figées (requirements.yml), hors Git
ansible-galaxy collection install -r requirements.yml -p collections

# 2. Simulation : ce qui changerait, sans rien modifier (-K : mot de passe
#    sudo, utilisé seulement par les tâches marquées « become »)
ansible-playbook site.yml -K --check --diff

# 3. Application, puis 2e passage : il doit afficher changed=0
ansible-playbook site.yml -K
ansible-playbook site.yml -K

# Un seul rôle, ou seulement les vérifications
ansible-playbook site.yml -K --tags backup
ansible-playbook site.yml -K --tags verify
```

**1re application** : la configuration de Docker change, donc Docker
redémarre une fois et le cluster s'arrête **quelques minutes** (le rôle le
relance). Ensuite, `live-restore` garde les conteneurs actifs pendant un
redémarrage de Docker.

## Sécurité

- **Jamais lancé par la CI.** Le playbook agit sur l'hôte avec sudo ; le
  donner au runner (un pod sans droits) annulerait son durcissement. La CI
  **vérifie** le code (job `ansible` : syntaxe, ansible-lint profil
  « production ») ; l'opérateur **l'exécute**.
- **Pas de root par défaut** : seules les tâches qui en ont besoin
  demandent sudo (`become`) ; le playbook refuse d'être lancé en root.
- **Tout est figé et vérifié** : binaires par empreinte SHA-256, image de
  metrics-server par empreinte, collection `community.general` 14.0.0,
  outils de la CI par `pip --require-hashes`.
- **Pare-feu** : SSH est autorisé **avant** l'activation, pour ne pas couper
  la session en cours.
- **Sauvegardes** : dossier en 700, fichiers en 600 ; copie hors site par
  la sauvegarde chiffrée de la machine (GPG AES-256, puis Google Drive).

## Limites et évolutions

| Limite | Évolution |
|---|---|
| SSH accepte encore les mots de passe (fail2ban limite les essais) | clé seule (`PasswordAuthentication no`), après vérification que chaque Ops se connecte par clé |
| Docker gère ses propres règles réseau et contourne ufw pour les ports qu'il publie (ici, Minikube ne publie que sur `127.0.0.1`) | règles dans la chaîne `DOCKER-USER` si un port devait être publié sur le réseau |
| Sur une machine neuve, la simulation (`--check`) échoue dès qu'une tâche dépend d'un dossier ou d'un paquet pas encore installé : dès `ops_tools` (`~/.local/bin` absent), puis node_exporter et fail2ban (testé le 04/11 sur Ubuntu 26.04 vierge) | conditions `ansible_check_mode` sur ces tâches |
| Sans Terraform installé, le playbook s'arrête sur une erreur brute (« No such file or directory ») au lieu du message « Terraform >= 1.17 is required » | message clair, ou installation de Terraform par le dépôt apt signé de HashiCorp |
| `ansible.cfg` impose le sudo classique (`sudo.ws`) : Ansible bloque avec sudo-rs, le sudo par défaut d'Ubuntu depuis la 25.10 (bug Launchpad #2122414) | retirer `become_exe` quand le correctif d'Ansible sera publié |
| Un seul poste, en local (inventaire `localhost`) | inventaire de plusieurs machines, connexion SSH |
| Collections et versions des outils mises à jour à la main (Dependabot ne suit ni Galaxy ni ces binaires) | Renovate, qui sait les suivre |
| Tests : syntaxe, lint, idempotence et vérifications finales ; test manuel sur une Ubuntu 26.04 vierge (conteneur jetable, 04/11) des rôles `ops_tools`, `node_exporter`, `hardening` : 1er passage sans erreur, 2e passage changed=0. Les rôles liés au cluster ne sont pas testables en conteneur | Molecule (machine jetable) pour tester chaque rôle en CI ; machine virtuelle pour les rôles liés au cluster |
| L'image ZAP est reconstruite avec le cache : un correctif Debian récent n'est pris qu'en reconstruisant sans cache | reconstruction planifiée sans cache |

Fichiers : [`site.yml`](site.yml) (le playbook),
[`group_vars/all.yml`](group_vars/all.yml) (versions, empreintes,
horaires, réseaux), `roles/` (un dossier par rôle),
[`requirements.yml`](requirements.yml) (collections),
[`requirements-ci.txt`](requirements-ci.txt) (outils de la CI),
[`.ansible-lint`](.ansible-lint), [`ansible.cfg`](ansible.cfg),
[`inventory.ini`](inventory.ini).
