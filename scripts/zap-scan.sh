#!/usr/bin/env bash
# Fichier  : scripts/zap-scan.sh
# Rôle     : test d'intrusion de MicroCRM avec ZAP (OWASP), lancé comme Job
#            Kubernetes dans staging, à côté de l'application : « baseline »
#            (passif, à chaque déploiement) ou « full » (actif, à la
#            demande) ; écrit le rapport (Markdown) et échoue si une règle
#            FAIL de infra/zap/rules.tsv est touchée
# Utilise  : scripts/lib/common.sh ; kubectl ; infra/zap/rules.tsv ;
#            image orion/zap (infra/zap/Dockerfile), chargée dans Minikube
# Utilisé par : workflow .github/workflows/zap.yml ; l'opérateur ;
#               ticket #64
# Usage    : scripts/zap-scan.sh baseline|full
# Paramètres : REPORT_DIR = dossier du rapport (défaut ./zap-report) ;
#              NAMESPACE = cible (défaut staging, seul autorisé par le
#              pare-feu du chart)

# Arrêt à la première erreur, variable inconnue, erreur dans un tube
set -Eeuo pipefail

# Dossiers calculés depuis l'emplacement du script : lançable de partout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_NAME="zap-scan.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Image ZAP du projet (infra/zap/Dockerfile : ZAP 2.17.0 corrigé, règles
# bêta vérifiées), construite et chargée dans Minikube, jamais téléchargée
ZAP_IMAGE="orion/zap:2.17.0-hardened"
RULES_FILE="$ROOT_DIR/infra/zap/rules.tsv"
NAMESPACE="${NAMESPACE:-staging}"
REPORT_DIR="${REPORT_DIR:-./zap-report}"
# Adresse du front vue depuis le namespace (nom du Service du chart)
TARGET="http://microcrm-front:8080"
# Ligne qui sépare, dans le journal du pod, la sortie de ZAP et le rapport
MARKER="=== ZAP REPORT ==="

# Mauvais usage : rappel de la syntaxe, code 2
usage() {
  echo "Usage: $SCRIPT_NAME baseline|full" >&2
  exit 2
}

# Commande ZAP et durée maximale (secondes) selon le mode ; options de
# ZAP (-z) : -silent, aucun téléchargement de modules au démarrage
# (seulement ceux de l'image figée ; le pare-feu bloque Internet) ;
# -Xmx1g, mémoire Java fixée (sinon ZAP prend 1/4 de la RAM de la machine
# et dépasse la limite du conteneur) ; -I : les alertes WARN ne font pas
# échouer, seules les règles FAIL bloquent
set_mode() {
  case "$1" in
    baseline)
      SCAN="zap-baseline.py"
      OPTIONS="-z '-silent -Xmx1g'"
      DEADLINE=900
      ;;
    full)
      # Actif : 2 min d'exploration, 10 min d'attaque au plus, un seul
      # fil d'attaque (moins de navigateurs ouverts, moins de mémoire)
      SCAN="zap-full-scan.py"
      OPTIONS="-m 2 -z '-silent -Xmx1g"
      OPTIONS+=" -config ascan.maxScanDurationInMins=10"
      OPTIONS+=" -config ascan.threadPerHost=1'"
      DEADLINE=2400
      ;;
    *) usage ;;
  esac
}

# Règles (WARN, FAIL, IGNORE par alerte) dans une ConfigMap, montée dans
# le pod ; « apply » la crée ou la remplace
apply_rules() {
  kubectl -n "$NAMESPACE" create configmap zap-rules \
    --from-file=rules.tsv="$RULES_FILE" --dry-run=client -o yaml |
    kubectl -n "$NAMESPACE" apply -f - >/dev/null
}

# Job ZAP : un seul essai, arrêté par Kubernetes après DEADLINE, effacé
# une heure après la fin ; règles « restricted » du namespace respectées
# (non-root, aucun privilège) ; le rapport est écrit dans le journal
apply_job() {
  kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: zap
  labels:
    app.kubernetes.io/name: zap
    app.kubernetes.io/part-of: microcrm
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $DEADLINE
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: zap
        app.kubernetes.io/part-of: microcrm
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: zap
          image: $ZAP_IMAGE
          imagePullPolicy: Never
          command: ["sh", "-c"]
          args:
            - >-
              $SCAN -t $TARGET $OPTIONS -c rules.tsv -I -w report.md;
              rc=\$?; echo "$MARKER"; cat /zap/wrk/report.md; exit \$rc
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          # Scan actif : 3,6 Gio au plus fort, surtout les navigateurs Firefox
          # de la règle « XSS DOM » (mesuré le 03/11/2026) ; marge à 4 Gio
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 4Gi
          volumeMounts:
            - name: wrk
              mountPath: /zap/wrk
            - name: rules
              mountPath: /zap/wrk/rules.tsv
              subPath: rules.tsv
      volumes:
        - name: wrk
          emptyDir: {}
        - name: rules
          configMap:
            name: zap-rules
EOF
}

# Attend la fin du Job ; renvoie 0 s'il a réussi, 1 s'il a échoué
# (règle FAIL touchée, erreur de ZAP ou durée dépassée)
wait_job() {
  local state end=$((SECONDS + DEADLINE + 60))
  while ((SECONDS < end)); do
    state="$(kubectl -n "$NAMESPACE" get job zap \
      -o jsonpath='{.status.succeeded}/{.status.failed}')"
    case "$state" in
      1/*) return 0 ;;
      */1) return 1 ;;
    esac
    sleep 10
  done
  die "ZAP did not finish in time; fix: kubectl -n $NAMESPACE describe job zap"
}

# Journal complet du pod, puis rapport seul (tout ce qui suit MARKER)
save_report() {
  mkdir -p "$REPORT_DIR"
  kubectl -n "$NAMESPACE" logs job/zap >"$REPORT_DIR/zap-output.txt" ||
    die "cannot read the ZAP log; fix: kubectl -n $NAMESPACE get pods"
  sed "1,/^$MARKER\$/d" "$REPORT_DIR/zap-output.txt" >"$REPORT_DIR/report.md"
  log INFO "report: $REPORT_DIR/report.md"
}

main() {
  [[ $# -eq 1 ]] || usage
  set_mode "$1"
  require_cmd kubectl
  [[ -f "$RULES_FILE" ]] || die "rules file not found: $RULES_FILE"
  log INFO "ZAP $1 scan of $TARGET in $NAMESPACE"
  # Le Job précédent (même nom) est remplacé
  kubectl -n "$NAMESPACE" delete job zap --ignore-not-found >/dev/null
  apply_rules
  apply_job
  local result=0
  wait_job || result=$?
  save_report
  ((result == 0)) ||
    die "ZAP found alerts set to FAIL in infra/zap/rules.tsv;" \
      "fix: read $REPORT_DIR/report.md"
  log INFO "no FAIL alert"
}

main "$@"
