#!/usr/bin/env bash
# Fichier  : scripts/load-test.sh
# Rôle     : test de charge de MicroCRM avec k6, lancé comme Job Kubernetes
#            dans staging, à côté de l'application ; 6 profils (fumée,
#            charge moyenne, stress, pic, point de rupture, endurance) ;
#            écrit le résumé de k6 et échoue si un seuil est dépassé ;
#            mesures envoyées à VictoriaMetrics (tableaux de bord Grafana)
# Utilise  : scripts/lib/common.sh ; kubectl ; infra/k6/microcrm.js ;
#            image grafana/k6 2.3.0 (figée par empreinte)
# Utilisé par : workflow .github/workflows/load-test.yml ; l'opérateur ;
#               ticket #92
# Usage    : scripts/load-test.sh smoke|average|stress|spike|breakpoint|soak
# Paramètres : REPORT_DIR = dossier du résumé (défaut ./load-report) ;
#              NAMESPACE = cible (défaut staging ; prod refusée) ;
#              PUSH_METRICS = 1 (défaut) envoie les mesures à
#              VictoriaMetrics, 0 ne les envoie pas

# Arrêt à la première erreur, variable inconnue, erreur dans un tube
set -Eeuo pipefail

# Dossiers calculés depuis l'emplacement du script : lançable de partout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_NAME="load-test.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Image officielle de k6, figée par empreinte (une étiquette peut être
# déplacée, une empreinte non) ; utilisateur 12345 de l'image
K6_IMAGE="grafana/k6:2.3.0@sha256:2dd4756ec6e14e62778916e1eb850108e4b499304c02df56760fa0bdb0fba0b8"
K6_SCRIPT="$ROOT_DIR/infra/k6/microcrm.js"
NAMESPACE="${NAMESPACE:-staging}"
REPORT_DIR="${REPORT_DIR:-./load-report}"
PUSH_METRICS="${PUSH_METRICS:-1}"
# Adresse du front vue depuis le namespace (nom du Service du chart)
TARGET="http://microcrm-front:8080"
# Réception des mesures par VictoriaMetrics (protocole remote write)
METRICS_URL="http://vmsingle-vm.monitoring.svc:8428/api/v1/write"

# Mauvais usage : rappel de la syntaxe, code 2
usage() {
  echo "Usage: $SCRIPT_NAME smoke|average|stress|spike|breakpoint|soak" >&2
  exit 2
}

# Durée maximale du Job (secondes) selon le profil : durée du profil
# (infra/k6/microcrm.js) + marge pour télécharger l'image et démarrer
set_deadline() {
  case "$1" in
    smoke) DEADLINE=300 ;;
    average | stress) DEADLINE=600 ;;
    spike) DEADLINE=300 ;;
    breakpoint) DEADLINE=900 ;;
    soak) DEADLINE=2400 ;;
    *) usage ;;
  esac
}

# Sortie de k6 : vers VictoriaMetrics, ou aucune
set_output() {
  case "$PUSH_METRICS" in
    1) OUTPUT="-o experimental-prometheus-rw" ;;
    0) OUTPUT="" ;;
    *) die "PUSH_METRICS must be 0 or 1" ;;
  esac
}

# Script k6 dans une ConfigMap, montée dans le pod ; « apply » la crée ou
# la remplace
apply_script() {
  kubectl -n "$NAMESPACE" create configmap k6-script \
    --from-file=microcrm.js="$K6_SCRIPT" --dry-run=client -o yaml |
    kubectl -n "$NAMESPACE" apply -f - >/dev/null
}

# Job k6 : un seul essai, arrêté par Kubernetes après DEADLINE, effacé une
# heure après la fin ; règles « restricted » du namespace respectées
# (non-root, aucun privilège, disque en lecture seule) ; seuls le front et
# VictoriaMetrics sont joignables (pare-feu du chart, networkPolicy.allowK6)
apply_job() {
  kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: k6
  labels:
    app.kubernetes.io/name: k6
    app.kubernetes.io/part-of: microcrm
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $DEADLINE
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: k6
        app.kubernetes.io/part-of: microcrm
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 12345
        runAsGroup: 12345
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: k6
          image: $K6_IMAGE
          imagePullPolicy: IfNotPresent
          args: ["run", "--no-color", $(job_args)]
          env:
            - name: TEST_TYPE
              value: "$TEST_TYPE"
            - name: BASE_URL
              value: "$TARGET"
            - name: K6_PROMETHEUS_RW_SERVER_URL
              value: "$METRICS_URL"
            # Percentiles envoyés pour les durées (sinon : moyenne seule)
            - name: K6_PROMETHEUS_RW_TREND_STATS
              value: "p(95),p(99),avg,max"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          # 300 VUs au plus (point de rupture) : quelques centaines de Mio
          resources:
            requests:
              cpu: 250m
              memory: 128Mi
            limits:
              memory: 1Gi
          volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: script
          configMap:
            name: k6-script
        - name: tmp
          emptyDir: {}
EOF
}

# Paramètres de « k6 run » au format de la liste YAML (args)
job_args() {
  local args=""
  [[ -n "$OUTPUT" ]] && args='"-o", "experimental-prometheus-rw", '
  echo "${args}\"/scripts/microcrm.js\""
}

# Attend la fin du Job ; renvoie 0 s'il a réussi, 1 s'il a échoué (seuil
# dépassé, erreur de k6 ou durée dépassée)
wait_job() {
  local state end=$((SECONDS + DEADLINE + 60))
  while ((SECONDS < end)); do
    state="$(kubectl -n "$NAMESPACE" get job k6 \
      -o jsonpath='{.status.succeeded}/{.status.failed}')"
    case "$state" in
      1/*) return 0 ;;
      */1) return 1 ;;
    esac
    sleep 10
  done
  die "k6 did not finish in time; fix: kubectl -n $NAMESPACE describe job k6"
}

# Journal du pod (résumé de fin de test de k6) gardé dans REPORT_DIR
save_report() {
  mkdir -p "$REPORT_DIR"
  kubectl -n "$NAMESPACE" logs job/k6 >"$REPORT_DIR/summary.txt" ||
    die "cannot read the k6 log; fix: kubectl -n $NAMESPACE get pods"
  log INFO "summary: $REPORT_DIR/summary.txt"
}

main() {
  [[ $# -eq 1 ]] || usage
  TEST_TYPE="$1"
  set_deadline "$TEST_TYPE"
  set_output
  # Jamais de charge sur la prod : elle sert de vrais utilisateurs
  [[ "$NAMESPACE" != "prod" ]] || die "load tests are not allowed in prod"
  require_cmd kubectl
  [[ -f "$K6_SCRIPT" ]] || die "k6 script not found: $K6_SCRIPT"
  log INFO "k6 $TEST_TYPE test of $TARGET in $NAMESPACE"
  # Le Job précédent (même nom) est remplacé
  kubectl -n "$NAMESPACE" delete job k6 --ignore-not-found >/dev/null
  apply_script
  apply_job
  local result=0
  wait_job || result=$?
  save_report
  if ((result != 0)); then
    # Point de rupture : dépasser les seuils est le but (capacité trouvée)
    if [[ "$TEST_TYPE" == "breakpoint" ]]; then
      log INFO "breaking point reached: read $REPORT_DIR/summary.txt"
      return 0
    fi
    die "k6 thresholds crossed; fix: read $REPORT_DIR/summary.txt"
  fi
  log INFO "all thresholds passed"
}

main "$@"
