# Supervision : métriques, journaux, alertes, tableaux de bord

La pile **VictoriaMetrics + VictoriaLogs + Grafana** surveille MicroCRM
dans ses trois environnements, ainsi que la machine qui héberge le
cluster. Elle est installée par OpenTofu
([`infra/terraform/monitoring.tf`](../terraform/monitoring.tf)), avec le
chart officiel `victoria-metrics-k8s-stack` **0.97.1** à version figée
(ticket #83).

```text
                 namespace monitoring (Pod Security « restricted »)
  ┌──────────────────────────────────────────────────────────────────────┐
  │ vmagent ── lit toutes les 30 s ──► VictoriaMetrics (métriques, 30 j) │
  │   ▲                                      │                           │
  │   │                    vmalert ◄─────────┤                           │
  │   │                       └──► Alertmanager ─────────────────────────┼──► Gmail
  │   │                                      │                           │
  │   │                    Grafana ◄─────────┴──── VictoriaLogs (7 j)    │
  └───┼─────────────────────────────────────────────────▲────────────────┘
      │ métriques                                       │ journaux
      │      namespace monitoring-collector             │ (« privileged »)
      │      vlagent : lit /var/log/pods ───────────────┘ en lecture seule
      │
  API MicroCRM (port 8081, dev / staging / prod) ; kube-state-metrics ;
  kubelet ; node_exporter de la machine (Ansible, 192.168.49.1:9100)
```

## Composants et licences

| Composant | Rôle | Licence |
|---|---|---|
| VictoriaMetrics 1.155.0 (vmsingle, vmagent, vmalert, vmauth) | base de métriques, lecture des cibles, évaluation des alertes | Apache 2.0 |
| VictoriaLogs 1.53.0 (vlsingle) et vlagent | base de journaux, collecteur | Apache 2.0 |
| Opérateur VictoriaMetrics 0.75.2 | crée les pods à partir des objets `VM*` | Apache 2.0 |
| Alertmanager 0.34.2 | regroupe les alertes, envoie les e-mails | Apache 2.0 |
| Grafana 13.2.5 + module VictoriaLogs 0.33.1 | tableaux de bord | Grafana : AGPL v3 ; module : Apache 2.0, signé (signature vérifiée par Grafana au chargement) |
| kube-state-metrics 2.20.0 | état des objets Kubernetes (pods prêts, redémarrages) | Apache 2.0 |

Pourquoi VictoriaMetrics plutôt que Prometheus, et VictoriaLogs plutôt
qu'ELK ou Loki : outils open source, très utilisés, compatibles avec le
langage de requête de Prometheus, et conseillés par le mentor pour leur
**faible consommation**. Mesure réelle sur la pile installée
(05/11/2026, `kubectl top pods` des 2 namespaces) : **≈ 1 Gio de
mémoire et 0,1 cœur** (103m) pour toute la pile, dont la moitié pour
Grafana (509 Mi) ; disques : 10 Gi (métriques) + 5 Gi (journaux). Le
nœud entier utilise alors 5,7 Gio sur 15 et 0,8 cœur sur 8.

## Fichiers

| Fichier | Rôle |
|---|---|
| [`values.yaml.tftpl`](values.yaml.tftpl) | réglages de la pile ; modèle (fonction `templatefile` d'OpenTofu) : l'adresse e-mail des alertes y est insérée à l'installation, **jamais écrite dans le dépôt** |
| [`extras.yaml`](extras.yaml) | cibles lues (API, machine), **nos alertes**, pare-feu réseau des 2 namespaces |
| [`dashboards/`](dashboards/) | les 4 tableaux de bord (JSON), chargés dans Grafana par des ConfigMaps (OpenTofu) |

## Ce qui est surveillé

| Source | Comment | Ce qu'on en tire |
|---|---|---|
| API MicroCRM | Spring Boot Actuator + Micrometer, **port de gestion 8081** (jamais exposé par le Service public, ticket #84) | requêtes, codes HTTP, temps de réponse (histogramme), mémoire Java |
| Kubernetes | kube-state-metrics, kubelet (cAdvisor) | pods prêts, redémarrages, CPU et mémoire par pod, autoscaling |
| Machine hôte | node_exporter installé par Ansible | disque, mémoire ; heure de la dernière sauvegarde de la base (écrite par `scripts/backup.sh`), de la base de SonarQube (`scripts/backup-sonarqube.sh`) et du coffre OpenBao, expiration du certificat du coffre (`scripts/backup-openbao.sh`) |
| Journaux | vlagent lit les fichiers des conteneurs | erreurs, réponses 4xx du front ; **sauf** `kube-system` et les jobs de la CI (`arc-*`) |

## Alertes

Évaluées toutes les 20 s par vmalert, envoyées par e-mail (Gmail) par
Alertmanager, regroupées par alerte et par namespace, rappelées toutes
les 4 h tant qu'elles durent.

Rangées par groupe dans [`extras.yaml`](extras.yaml) (disponibilité,
performance, machine, sécurité). Les trois alertes de sécurité (ticket
#106, puis `OpenBaoSealed` le 09/11) répondent à la catégorie A09 de
l'OWASP Top 10 2025, « Security
Logging and Alerting Failures » : détecter une attaque, et savoir quand
on ne peut plus la détecter.

| Alerte | Domaine | Condition | Gravité |
|---|---|---|---|
| <a id="microcrmproddown"></a>`MicrocrmProdDown` | disponibilité | aucun pod prêt pour le back ou le front de la prod pendant 2 min | critique |
| <a id="podrestartloop"></a>`PodRestartLoop` | disponibilité | un conteneur redémarre plus de 3 fois en 30 min | avertissement |
| <a id="microcrmhigherrorrate"></a>`MicrocrmHighErrorRate` | performance | plus de 5 % de réponses 5xx en prod pendant 5 min | critique |
| <a id="microcrmslowresponses"></a>`MicrocrmSlowResponses` | performance | p95 au-dessus de 500 ms pendant 10 min (sous charge k6, le 03/11 : p95 = 401 ms) | avertissement |
| <a id="hostdiskalmostfull"></a>`HostDiskAlmostFull` | machine | disque de la machine rempli à plus de 85 % | avertissement |
| <a id="backuptooold"></a>`BackupTooOld` | machine | dernière sauvegarde réussie de la prod il y a plus de 26 h, ou jamais | critique |
| <a id="openbaocertexpiringsoon"></a>`OpenBaoCertExpiringSoon` | machine | certificat TLS du coffre OpenBao expiré dans moins de 30 jours (date lue chaque jour par `backup-openbao.sh`) | avertissement |
| <a id="openbaobackuptooold"></a>`OpenBaoBackupTooOld` | machine | dernier instantané du coffre OpenBao il y a plus de 74 h (un week-end poste éteint n'alerte pas), ou jamais ; le jeton de sauvegarde expire après 7 jours sans sauvegarde | avertissement |
| <a id="sonarqubebackuptooold"></a>`SonarQubeBackupTooOld` | machine | dernière sauvegarde de la base de SonarQube il y a plus de 74 h (un week-end poste éteint n'alerte pas), ou jamais ; la qualité se mesure encore, seul l'historique est en jeu | avertissement |
| <a id="microcrmclienterrorspike"></a>`MicrocrmClientErrorSpike` | sécurité | plus de 50 réponses 4xx de l'API de la prod en 5 min (5 au plus vues depuis le 05/11) : balayage ou tentative d'intrusion probable | avertissement |
| <a id="logingestionstopped"></a>`LogIngestionStopped` | sécurité | aucune ligne de journal reçue par VictoriaLogs depuis 15 min (10 min sans ligne, constaté pendant 5 min), ou mesure disparue : une intrusion ne laisserait plus de trace | critique |
| <a id="openbaosealed"></a>`OpenBaoSealed` | sécurité | coffre-fort OpenBao scellé (ou absent) depuis 15 min : après chaque démarrage du poste, il attend le déverrouillage de l'Ops ; sans lui, la CI n'obtient plus d'accès | avertissement |
| `Watchdog` | contrôle | toujours active : prouve que la chaîne d'alerte fonctionne ; jamais envoyée | — |

**Compter des événements : trois fonctions, selon le besoin** (testé le
05/11 avec 5 réponses 404 en prod, puis le 07/11 avec 60) :

- erreurs de l'API **qui durent** (`MicrocrmHighErrorRate`) :
  `increase`. Spring Boot ne crée le compteur d'un code (404, 500…)
  qu'à sa 1re réponse ; `rate` et `increase_prometheus` ne mesurent
  qu'une variation entre deux relevés et affichaient 0 ; `increase`
  compte aussi la 1re valeur relevée, **si elle est petite** (5 le
  05/11). Une grande valeur est ignorée, mais des erreurs qui durent
  font monter le compteur à chaque relevé ;
- **rafale** d'erreurs (`MicrocrmClientErrorSpike`) : `increase_pure`,
  qui part toujours de 0. Le 07/11, les 60 requêtes de test sont
  tombées entre deux relevés : compteurs nés à 44 et 16, comptés 0 par
  `increase` (alerte manquée), 60 par `increase_pure`. Revers : après
  une coupure des relevés de plus de 5 min, un ancien compteur est
  recompté en entier ; fausse alerte possible si l'API a déjà renvoyé
  plus de 50 réponses 4xx depuis son démarrage (aucune sur l'historique
  depuis le 05/11 ; compteurs remis à 0 à chaque déploiement) ;
- compteurs de **kube-state-metrics** (redémarrages) :
  `increase_prometheus`. Ils sont publiés avec tout leur passé ; après
  une réinstallation, `increase` compterait d'anciens redémarrages.

**Chercher dans les journaux** (corrigé le 07/11/2026) : dans
VictoriaLogs, un mot cherché respecte la casse et doit être un mot
entier ; `error` ne trouvait ni `ERROR` (niveau des journaux de Spring)
ni `ConversionFailedException`. Le panneau *Error logs* cherche donc un
motif insensible à la casse :
`~"(?i)(error|exception|denied|forbidden|unauthorized)"` (en staging,
190 → 236 lignes trouvées, dont 2 `ERROR` et les exceptions d'une
erreur 500 du 05/11, jusque-là invisibles).

**Journaux structurés (JSON, 09/11/2026)** : chaque ligne écrite par
l'application est un objet JSON ; vlagent la découpe en champs, qu'une
recherche peut viser directement, sans motif fragile sur le texte.

| Composant | Format | Champs utiles | Exemple de recherche |
| --- | --- | --- | --- |
| back (Spring Boot) | **ECS** (Elastic Common Schema), intégré à Spring Boot, activé par le chart (`LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs`) | `log.level`, `log.logger`, `message`, `service.version`, `service.environment`, `error.stack_trace` (trace complète sur une seule ligne) | `log.level:ERROR` |
| front (nginx) | `log_format front_json` de [`front/nginx.conf`](../../front/nginx.conf) | `status`, `method`, `path`, `request_time`, `upstream_time` (temps du back), `remote_addr`, `user_agent` | `kubernetes.container_name:front AND status:~"^4"` |

Choix de sécurité et d'exploitation :

- le chemin du front est écrit **sans ses paramètres** (tout ce qui suit
  `?`) : une donnée passée dans l'adresse n'arrive jamais dans les
  journaux (OWASP Logging Cheat Sheet) ;
- `escape=json` : un client qui envoie des guillemets (en-tête
  `User-Agent` piégé) ne peut pas fabriquer un faux champ (testé) ;
- les **sondes de Kubernetes** ne sont plus écrites (plusieurs lignes
  par minute, sans intérêt) ;
- en local (`./gradlew bootRun`, tests), le back garde le texte
  habituel, plus lisible ;
- les lignes d'avant le 09/11, en texte, restent visibles pendant les
  7 jours de conservation, mais seul le motif sur le texte les trouve.

**Premiers gestes** (lien `runbook` de chaque alerte) :

- `MicrocrmProdDown` : `kubectl -n prod get pods`, puis
  `kubectl -n prod describe pod …` et les journaux dans Grafana ; si
  une version vient d'être déployée, `scripts/deploy.sh rollback prod`.
- `MicrocrmHighErrorRate` / `MicrocrmSlowResponses` : tableau de bord
  *Performance* (route la plus lente, mémoire Java), *Security* (journaux
  d'erreurs) ; base de données joignable ?
- `HostDiskAlmostFull` : `docker system df`, puis le nettoyage d'Ansible
  (`ansible-playbook site.yml -K --tags docker_hygiene`).
- `BackupTooOld` : `tail ~/.local/state/microcrm-backup.log`, puis
  `scripts/backup.sh prod` à la main.
- `OpenBaoBackupTooOld` : `tail ~/.local/state/openbao-backup.log` ;
  coffre scellé ? jeton expiré ? ([README d'OpenBao](../openbao/README.md#sauvegarde-planifiée)) ;
  puis `scripts/backup-openbao.sh` à la main.
- `SonarQubeBackupTooOld` : `tail ~/.local/state/sonarqube-backup.log`,
  `kubectl -n sonarqube get pods`, puis `scripts/backup-sonarqube.sh` à
  la main.
- `OpenBaoCertExpiringSoon` : renouveler le certificat
  ([README d'OpenBao](../openbao/README.md#certificat) : `tofu plan`,
  `tofu apply`, redémarrage du pod, déverrouillage).
- `PodRestartLoop` : `kubectl -n <ns> logs <pod> --previous`.
- `MicrocrmClientErrorSpike` : tableau de bord *Security* (codes 4xx,
  accès refusés, 4xx du front lues dans les journaux) ; dans les
  journaux du front, repérer l'origine et les chemins essayés ; vérifier
  qu'aucune requête inhabituelle n'a réussi (2xx) ; garder les journaux
  (preuves, 7 jours) ; si l'attaque continue, bloquer la source (voir
  les évolutions).
- `LogIngestionStopped` : `kubectl -n monitoring-collector get pods` et
  `kubectl -n monitoring get pods -l app.kubernetes.io/name=vlsingle` ;
  journaux du collecteur
  (`kubectl -n monitoring-collector logs ds/vlagent-vm --tail=50`) ;
  disque de VictoriaLogs (5 Gi) plein ? pare-feu réseau
  `vlsingle-from-collector` modifié ?
- `OpenBaoSealed` : déverrouiller avec 2 des 3 clés (Bitwarden),
  [procédure](../openbao/README.md#3-déverrouiller-ops-chaque-matin-et-après-tout-redémarrage) ;
  si le pod n'existe plus : `kubectl -n openbao get pods,pvc` et
  `tofu plan` (infra/terraform).

## Tableaux de bord

| Tableau de bord | Question à laquelle il répond |
|---|---|
| **Orion - Availability** | MicroCRM est-il debout, dans chaque environnement ? Pods prêts, API lue, redémarrages, disque et mémoire de la machine, âge de la dernière sauvegarde, alertes en cours |
| **Orion - Performance** | Les 4 signaux d'or : trafic, temps de réponse (p50/p95/p99), erreurs, saturation (CPU, mémoire, mémoire Java, autoscaling) |
| **Orion - Security** | Réponses 4xx/5xx, requêtes refusées (401/403), redémarrages du collecteur, 4xx du front lues dans les journaux, journaux d'erreurs |
| **Orion - Delivery** | La livraison va-t-elle bien ? Les 5 indicateurs DORA de la prod sur 30 jours et leur évolution, importés chaque jour ouvré par le workflow DORA metrics ([`dora.py`](../../scripts/README.md#dorapy)) |

Un sélecteur d'environnement (`prod`, `staging`, `dev`) en haut des
trois premiers tableaux.

**Déploiements marqués** : sur chaque tableau, un trait bleu indique
qu'une nouvelle image du front ou du back a démarré dans
l'environnement affiché ; son texte donne l'image (`…:v1.9.1`). Il
vient de kube-state-metrics (`kube_pod_container_info`), sans aucun
outil de plus : une dégradation se relie d'un coup d'œil à une version.

**Indicateurs DORA** : la règle réseau `vmsingle-from-runner`
([`extras.yaml`](extras.yaml)) laisse le runner local de la CI écrire
dans VictoriaMetrics (port 8428), comme celle de k6. **Limite** :
VictoriaMetrics n'a pas d'authentification ; tout job lancé sur ce
runner (`main` ou PR du dépôt, jamais une copie extérieure) pourrait y
écrire. Le workflow ne transmet que des lignes `dora_*` contrôlées.

Un panneau sans donnée affiche ce que cela veut dire (`no traffic`,
`no firing alert`) : « No data » reste réservé aux cas anormaux
(collecte en panne, requête fausse). Seule exception, **Error logs** :
un panneau de journaux ne sait pas afficher de message personnalisé,
donc « No data » y signifie « aucune erreur sur la période » (vérifié
en prod le 07/11/2026 : 0 ligne, même sans tenir compte de la casse).

## Utilisation

Installation et mise à jour : par OpenTofu
([README](../terraform/README.md#supervision)). Accès à Grafana, depuis
le poste Ops seulement :

```shell
# Mot de passe admin, généré par le chart (affiché dans TON terminal)
kubectl -n monitoring get secret vm-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
# Tunnel, puis http://localhost:3000 (onglet PORTS de VS Code)
kubectl -n monitoring port-forward svc/vm-grafana 3000:80
```

Désinstaller (essai, ou `tofu destroy`) : supprimer **d'abord** le
collecteur, pendant que l'opérateur VictoriaMetrics tourne encore ;
sinon son verrou de suppression (*finalizer*) n'est jamais levé et la
désinstallation attend sans fin (vu le 04/11) :

```shell
kubectl delete vlagent vm -n monitoring-collector
```

Tester l'envoi d'un e-mail (alerte de test, résolue après 5 min ; testé
le 05/11 et le 07/11 : e-mails « FIRING » puis « RESOLVED » reçus, 6 min
d'écart le 07/11). Le tunnel met quelques secondes à s'ouvrir : sans
l'attente, le `curl` part trop tôt et l'alerte est perdue sans message
(vu le 07/11) ; `-sS` affiche les erreurs, `HTTP 200` confirme la
réception :

```shell
kubectl -n monitoring port-forward svc/vmalertmanager-vm 9093:9093 &
# Attendre que le tunnel réponde (20 s au plus)
for i in $(seq 20); do curl -s -o /dev/null localhost:9093/-/ready && break; sleep 1; done
curl -sS -w 'HTTP %{http_code}\n' -X POST localhost:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestEmail","severity":"warning"},"annotations":{"summary":"Test from the Ops host"}}]'
# Fermer le tunnel
kill %1
```

**Alertes de sécurité testées** le 07/11 (ticket #106) :

- syntaxe : `vmalert -dryRun`, même version que le cluster (1.155.0) ;
- tests unitaires sur des données simulées (`vmalert-tool unittest`,
  outil officiel de VictoriaMetrics), 6 cas : rafale de 4xx en prod,
  sur un compteur neuf ou ancien (alerte) ; même rafale en staging, 30
  réponses en prod ou 100 sur les sondes (pas d'alerte) ; journaux
  arrêtés, puis VictoriaLogs arrêté (alerte après 15 min).
  Contre-épreuve : une règle cassée exprès fait échouer les tests ;
- `OpenBaoSealed` (09/11) : `vmalert -dryRun` et 3 cas
  `vmalert-tool` (scellé 15 min : alerte ; déverrouillé à 8 min : rien ;
  mesure disparue : alerte), contre-épreuve en échec comme attendu ;
- `OpenBaoBackupTooOld` (11/11) : `vmalert -dryRun` et 4 cas
  `vmalert-tool` (instantané de 72 h : rien ; de 76 h : alerte ;
  métrique jamais vue : rien à 10 min, alerte à 20 min) ; contre-épreuve
  (seuil passé à 70 h) en échec comme attendu ;
- `OpenBaoCertExpiringSoon` (11/11) : 2 cas `vmalert-tool` (certificat
  qui expire dans 31 jours : rien ; dans 29 jours depuis plus d'1 h :
  alerte) ; contre-épreuve (seuil passé à 20 jours) en échec ;
- `SonarQubeBackupTooOld` (12/11) : `vmalert -dryRun` et 3 cas
  `vmalert-tool` (sauvegarde de 72 h : rien ; de 76 h : rien à 10 min,
  alerte à 20 min ; métrique jamais vue : alerte à 20 min) ;
  contre-épreuve (seuil passé à 70 h) en échec comme attendu ;
- conditions rejouées sur l'historique depuis le 05/11 : aucune fausse
  alerte. Sans le délai `for: 5m`, `LogIngestionStopped` aurait sonné à
  tort 3 fois (30 s à l'installation et au démarrage du poste, 2 min
  pendant un remplacement de VictoriaLogs) ;
- 1er test réel en prod (18:30, 60 réponses 404) : **alerte manquée**.
  Les tests unitaires simulaient un compteur né à 1, pas à 44 :
  `increase` ignorait la rafale (voir « Compter des événements »).
  Corrigé avec `increase_pure`, et le cas réel ajouté aux tests ;
- 2e test réel, après correction (18:57, 60 réponses 404) : e-mail
  « FIRING » reçu à 18:58, « RESOLVED » à 19:03 ; côté Alertmanager,
  aucun envoi en échec.

Test annoncé de `MicrocrmClientErrorSpike` : 60 requêtes vers une
adresse qui n'existe pas (réponses 404, rien n'est écrit), à travers le
front, comme un visiteur :

```shell
kubectl -n prod port-forward svc/microcrm-front 18080:8080 &
# Attendre que le tunnel réponde (20 s au plus)
for i in $(seq 20); do curl -s -o /dev/null localhost:18080/ && break; sleep 1; done
for i in $(seq 60); do curl -s -o /dev/null -w '%{http_code}\n' localhost:18080/api/orion-security-test; done | sort | uniq -c
# Fermer le tunnel
kill %1
```

## Sécurité

- **Deux namespaces** : tout est en « restricted », sauf le **collecteur
  de journaux**, seul composant qui lit des fichiers de la machine
  (`monitoring-collector`, « privileged », qui avertit de tout écart à
  « restricted »). Ce niveau l'autorise sans rien lui donner : le pod
  lui-même est verrouillé.
- **Collecteur verrouillé** (vérifié sur le nœud) : root, mais **aucune
  capacité** (`CapEff = 0`) : propriétaire des journaux (`root:root`,
  640), il n'en a pas besoin ; `DAC_READ_SEARCH`, d'abord prévue, a été
  retirée le 05/11 après test (journaux toujours reçus, aucune erreur) ;
  aucune montée de privilèges (`NoNewPrivs=1`) ; système de fichiers en
  lecture seule ; il ne peut envoyer qu'à VictoriaLogs, au DNS et à
  l'API de Kubernetes. L'avertissement Pod Security du namespace liste
  ses écarts à « restricted » : montages de l'hôte (`hostPath`) et root.
- **Piège de l'opérateur** : il met à jour le DaemonSet du collecteur par
  fusion ; un champ **retiré** des réglages (ici la capacité) reste sur
  le DaemonSet. Il faut alors le retirer aussi du DaemonSet
  (`kubectl patch ds vlagent-vm --type=json`, opération `remove`).
- **Montages réduits** : par défaut, l'opérateur VictoriaMetrics monte
  tout `/var/lib` de la machine, où kubelet range les **Secrets des
  autres pods** (23 comptés) ; on ne monte que `/var/log/containers` et
  `/var/log/pods`, en lecture seule (trouvé pendant l'essai du 04/11).
- **Données personnelles** : journaux techniques **minimisés** (namespaces
  exclus, champs `password`/`token`/`authorization` retirés avant
  l'envoi) et gardés **7 jours** ; aucune donnée de client du CRM n'est
  journalisée aujourd'hui (vérifié). La traçabilité (« qui a fait
  quoi ») est un autre besoin, avec une autre durée (CNIL : 6 mois à
  1 an) : voir les évolutions.
- **Rien d'exposé** : pas d'Ingress ; Grafana seulement par
  `port-forward`, sans compte anonyme ni inscription ; pare-feu réseau
  (seuls les pods de la supervision et le collecteur entrent, plus le
  pod du test de charge k6 de `staging`, qui écrit ses mesures dans
  VictoriaMetrics : [`load-test.sh`](../../scripts/README.md#load-testsh)).
- **Contenu relu** : le téléchargement automatique des tableaux de bord
  et règles de la communauté (« sync-job », branches GitHub non figées)
  est coupé ; toutes les règles d'alerte et tous les tableaux de bord
  sont dans ce dossier, relus en PR (chart et images : versions figées).
- **Réglages de sécurité corrigés** : l'opérateur VictoriaMetrics et son
  job de nettoyage n'avaient pas de profil seccomp ni de compte non root
  (refusés par « restricted ») : ajoutés dans `values.yaml.tftpl`.
- **Secrets** : mot de passe d'application Gmail dans le Secret
  `alertmanager-smtp`, créé par l'Ops depuis son terminal, jamais
  dans le dépôt ni dans l'état OpenTofu. L'adresse des alertes, elle,
  est dans l'état OpenTofu et dans la release Helm (en clair, hors du
  dépôt, lisibles par l'Ops seul).

### Failles connues des images (Trivy, gravité haute et critique, 04/11/2026)

| Image | Résultat | Décision |
|---|---|---|
| VictoriaMetrics, vmagent, vmalert, vmauth 1.155.0 ; opérateur 0.75.2 ; Alertmanager 0.34.2 | 0 | — |
| VictoriaLogs, vlagent 1.53.0 | 4 hautes (bibliothèque standard de Go) | dernière version : risque accepté, à revoir à chaque version |
| kube-state-metrics 2.20.0 | 10 hautes (Go) | dernière version : risque accepté |
| Grafana 13.2.5 | 35 hautes | la 13.3.0 en a 39 : 13.2.5 gardée ; non exposé |
| k8s-sidecar | 2.11.2 du chart : 1 critique + 14 hautes | **forcé en 2.14.3** : 0 critique, 5 hautes |

## Limites et évolutions

| Limite | Évolution |
|---|---|
| Un seul nœud, une seule copie des données ; pas d'étages hot/warm/cold | VictoriaMetrics et VictoriaLogs en cluster, stockage objet pour l'archive |
| Masquage des données à la source seulement (pas de réécriture d'une valeur par le collecteur) | Pipeline Vector ou Alloy pour masquer centralement (il remplacerait vlagent, avec les mêmes droits) |
| Pas de journal d'audit (« qui a fait quoi ») : l'application n'a pas d'authentification | Authentification (équipe Dev), puis journal d'audit pseudonymisé, gardé 6 mois à 1 an ; journal d'audit de Kubernetes |
| Sortie réseau de `monitoring` ouverte (vmagent lit tous les namespaces, Alertmanager joint Gmail, Grafana télécharge son module) | Règles de sortie par composant |
| Le collecteur garde un dossier inscriptible sur la machine (`/var/lib/vlagent-data`, points de reprise) | — (nécessaire pour ne pas relire les journaux) |
| Grafana sans disque : un tableau de bord modifié à la main disparaît au redémarrage | Voulu : les tableaux de bord sont du code (dossier `dashboards/`) |
| Tableaux de bord de la communauté non installés | Les copier dans `dashboards/`, figés à une version |
| Alertes par e-mail seulement | Messagerie d'équipe (Slack, Teams), astreinte |
| `Watchdog` n'est envoyée nulle part : si toute la chaîne tombe (machine éteinte, Alertmanager arrêté), aucun e-mail ne le dit | Service externe qui prévient quand `Watchdog` n'arrive plus (*dead man's switch*, ex. Healthchecks.io, open source, BSD-3) |
| Les alertes de sécurité **détectent** une attaque sans la **bloquer** | Limiter le débit par client (nginx `limit_req`) ; en cloud, pare-feu applicatif (WAF) devant l'application |
| Règles d'alerte testées à la main (`vmalert-tool`, 07/11), pas à chaque PR | Tests unitaires des règles dans la CI |
| `LogIngestionStopped` jamais déclenchée pour de vrai (il faudrait couper la collecte 15 min) | Exercice planifié sur un environnement de test |
| Pas d'objectif de disponibilité chiffré | SLO (ex. 99,5 %) et alertes sur le budget d'erreur |
| Aucune alerte avant l'expiration d'un certificat (celui d'OpenBao expire le 09/11/2027) | Sonde Blackbox Exporter (métrique `probe_ssl_earliest_cert_expiry`) et alerte 30 jours avant |
