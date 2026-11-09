{{/*
Fichier  : infra/helm/microcrm/templates/_helpers.tpl
Rôle     : morceaux réutilisés par tous les modèles (étiquettes, sélecteurs,
           étiquette d'image, durcissement des conteneurs) : écrits une
           seule fois, donc toujours identiques
Utilisé par : les autres fichiers de templates/ ; ticket #64
*/}}

{{/*
Étiquettes standard de Kubernetes, posées sur tous les objets.
Version : celle du composant ; par défaut l'appVersion du chart, que
scripts/deploy.sh fixe à la version déployée (helm package
--app-version) ; la base passe sa propre version (« version »), pour ne
pas redémarrer à chaque version de l'application
Usage : include "microcrm.labels" (dict "root" $ "component" "back")
*/}}
{{- define "microcrm.labels" -}}
{{- $version := .version | default .root.Chart.AppVersion -}}
{{ include "microcrm.selectorLabels" . }}
app.kubernetes.io/part-of: microcrm
app.kubernetes.io/version: {{ $version | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
{{- end }}

{{/*
Étiquettes qui désignent les pods d'un composant (Service, NetworkPolicy,
HPA) : elles ne changent jamais, sinon Kubernetes refuse la mise à jour
*/}}
{{- define "microcrm.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{/*
Nom d'un objet : <release>-<composant>, ex. microcrm-back
*/}}
{{- define "microcrm.name" -}}
{{ printf "%s-%s" .root.Release.Name .component }}
{{- end }}

{{/*
Image complète : dépôt + étiquette ; sans étiquette, v<appVersion>
Usage : include "microcrm.image" (dict "root" $ "image" .Values.back.image)
*/}}
{{- define "microcrm.image" -}}
{{- $tag := default (printf "v%s" .root.Chart.AppVersion) .image.tag }}
{{- printf "%s:%s" .image.repository $tag }}
{{- end }}

{{/*
Durcissement commun à tous les conteneurs (Pod Security « restricted ») :
pas d'élévation de droits, aucune capacité Linux, disque système en
lecture seule (les dossiers inscriptibles sont des volumes emptyDir)
*/}}
{{- define "microcrm.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{/*
Durcissement commun aux pods ; le numéro d'utilisateur est celui de l'image
Usage : include "microcrm.podSecurityContext" 101
*/}}
{{- define "microcrm.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ . }}
runAsGroup: {{ . }}
fsGroup: {{ . }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
Sortie autorisée vers le DNS du cluster (kube-dns), pour trouver les
Services par leur nom
*/}}
{{- define "microcrm.dnsEgress" -}}
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
  ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
{{- end }}
