# Supervision : métriques, journaux, alertes, tableaux de bord

La pile **VictoriaMetrics + VictoriaLogs + Grafana** surveille MicroCRM
dans ses trois environnements, ainsi que la machine qui héberge le
cluster. Elle est installée par Terraform
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
  kubelet ; node_exporter de la machine (Ansible, 192.168.58.1:9100)
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
| [`values.yaml.tftpl`](values.yaml.tftpl) | réglages de la pile ; modèle Terraform : l'adresse e-mail des alertes y est insérée à l'installation, **jamais écrite dans le dépôt** |
| [`extras.yaml`](extras.yaml) | cibles lues (API, machine), **nos alertes**, pare-feu réseau des 2 namespaces |
| [`dashboards/`](dashboards/) | les 3 tableaux de bord (JSON), chargés dans Grafana par des ConfigMaps (Terraform) |

## Ce qui est surveillé

| Source | Comment | Ce qu'on en tire |
|---|---|---|
| API MicroCRM | Spring Boot Actuator + Micrometer, **port de gestion 8081** (jamais exposé par le Service public, ticket #84) | requêtes, codes HTTP, temps de réponse (histogramme), mémoire Java |
| Kubernetes | kube-state-metrics, kubelet (cAdvisor) | pods prêts, redémarrages, CPU et mémoire par pod, autoscaling |
| Machine hôte | node_exporter installé par Ansible | disque, mémoire ; heure de la dernière sauvegarde (écrite par `scripts/backup.sh`) |
| Journaux | vlagent lit les fichiers des conteneurs | erreurs, réponses 4xx du front ; **sauf** `kube-system` et les jobs de la CI (`arc-*`) |

## Alertes

Évaluées toutes les 20 s par vmalert, envoyées par e-mail (Gmail) par
Alertmanager, regroupées par alerte et par namespace, rappelées toutes
les 4 h tant qu'elles durent.

| Alerte | Condition | Gravité |
|---|---|---|
| <a id="microcrmproddown"></a>`MicrocrmProdDown` | aucun pod prêt pour le back ou le front de la prod pendant 2 min | critique |
| <a id="microcrmhigherrorrate"></a>`MicrocrmHighErrorRate` | plus de 5 % de réponses 5xx en prod pendant 5 min | critique |
| <a id="microcrmslowresponses"></a>`MicrocrmSlowResponses` | p95 au-dessus de 500 ms pendant 10 min (sous charge k6, le 03/11 : p95 = 401 ms) | avertissement |
| <a id="hostdiskalmostfull"></a>`HostDiskAlmostFull` | disque de la machine rempli à plus de 85 % | avertissement |
| <a id="backuptooold"></a>`BackupTooOld` | dernière sauvegarde réussie de la prod il y a plus de 26 h, ou jamais | critique |
| <a id="podrestartloop"></a>`PodRestartLoop` | un conteneur redémarre plus de 3 fois en 30 min | avertissement |
| `Watchdog` | toujours active : prouve que la chaîne d'alerte fonctionne ; jamais envoyée | — |

**Compter des événements : deux fonctions, selon la source** (testé le
05/11 avec 5 réponses 404 en prod) :

- compteurs de **Spring Boot** (erreurs de l'API) : `increase`. Le
  compteur d'un code (404, 500…) n'existe qu'à partir de sa 1re
  réponse, déjà à 1 ou plus ; `rate` et `increase_prometheus` ne
  mesurent qu'une variation entre deux relevés et affichaient 0 ;
  `increase` (VictoriaMetrics) compte aussi cette 1re valeur : 5 ;
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
- `PodRestartLoop` : `kubectl -n <ns> logs <pod> --previous`.

## Tableaux de bord

| Tableau de bord | Question à laquelle il répond |
|---|---|
| **Orion - Availability** | MicroCRM est-il debout, dans chaque environnement ? Pods prêts, API lue, redémarrages, disque et mémoire de la machine, âge de la dernière sauvegarde, alertes en cours |
| **Orion - Performance** | Les 4 signaux d'or : trafic, temps de réponse (p50/p95/p99), erreurs, saturation (CPU, mémoire, mémoire Java, autoscaling) |
| **Orion - Security** | Réponses 4xx/5xx, requêtes refusées (401/403), redémarrages du collecteur, 4xx du front lues dans les journaux, journaux d'erreurs |

Un sélecteur d'environnement (`prod`, `staging`, `dev`) en haut de
chaque tableau.

Un panneau sans donnée affiche ce que cela veut dire (`no traffic`,
`no firing alert`) : « No data » reste réservé aux cas anormaux
(collecte en panne, requête fausse). Seule exception, **Error logs** :
un panneau de journaux ne sait pas afficher de message personnalisé,
donc « No data » y signifie « aucune erreur sur la période » (vérifié
en prod le 07/11/2026 : 0 ligne, même sans tenir compte de la casse).

## Utilisation

Installation et mise à jour : par Terraform
([README](../terraform/README.md#supervision)). Accès à Grafana, depuis
le poste Ops seulement :

```shell
# Mot de passe admin, généré par le chart (affiché dans TON terminal)
kubectl -n monitoring get secret vm-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
# Tunnel, puis http://localhost:3000 (onglet PORTS de VS Code)
kubectl -n monitoring port-forward svc/vm-grafana 3000:80
```

Désinstaller (essai, ou `terraform destroy`) : supprimer **d'abord** le
collecteur, pendant que l'opérateur VictoriaMetrics tourne encore ;
sinon son verrou de suppression (*finalizer*) n'est jamais levé et la
désinstallation attend sans fin (vu le 04/11) :

```shell
kubectl delete vlagent vm -n monitoring-collector
```

Tester l'envoi d'un e-mail (alerte de test, résolue après 5 min ;
testé le 05/11 : e-mails « FIRING » puis « RESOLVED » reçus) :

```shell
kubectl -n monitoring port-forward svc/vmalertmanager-vm 9093:9093 &
curl -s -X POST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestEmail","severity":"warning"},"annotations":{"summary":"Test from the Ops host"}}]'
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
  dans le dépôt ni dans l'état Terraform. L'adresse des alertes, elle,
  est dans l'état Terraform et dans la release Helm (en clair, hors du
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
| Pas d'objectif de disponibilité chiffré | SLO (ex. 99,5 %) et alertes sur le budget d'erreur |
