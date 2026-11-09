#!/usr/bin/env bash
# Fichier  : scripts/tests/deploy_test.sh
# Rôle     : tests unitaires de scripts/deploy.sh (bashunit), avec de faux
#            helm, kubectl et openssl (doublures) : aucun vrai cluster
# Utilise  : bashunit 0.52.0, scripts/deploy.sh, scripts/lib/common.sh
# Utilisé par : job script-tests de la CI ; en local : bashunit scripts/tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Avant chaque test : un faux dépôt avec une copie du script et de faux
# outils ; par défaut, tout va bien (namespace « restricted », les 2
# Secrets de la base présents, test de fumée réussi)
function set_up() {
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO"/{scripts/lib,bin,infra/helm/microcrm}
  cp "$SCRIPTS_DIR/deploy.sh" "$FAKE_REPO/scripts/"
  cp "$SCRIPTS_DIR/lib/common.sh" "$FAKE_REPO/scripts/lib/"
  make_kubectl
  make_helm
  # Faux openssl : une valeur aléatoire fixe de 64 caractères
  printf '#!/usr/bin/env bash\nprintf "%%064d\\n" 7\n' \
    >"$FAKE_REPO/bin/openssl"
  chmod +x "$FAKE_REPO/bin/openssl"
  export PSS_LEVEL="restricted" SECRET_EXISTS=1 APP_SECRET_EXISTS=1
  export SMOKE_EXIT=0
}

# Après chaque test : suppression du faux dépôt
function tear_down() {
  rm -rf "$FAKE_REPO"
}

# Faux kubectl : note ses paramètres dans CALLS_LOG et répond selon les
# variables du test ; pour « create secret », note aussi ce qu'il reçoit
# par le tube
make_kubectl() {
  cat >"$FAKE_REPO/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS_LOG"
case "$*" in
  "config current-context") echo "orion" ;;
  *"get namespace"*) [[ -n "$PSS_LEVEL" ]] || exit 1
    [[ "$PSS_LEVEL" == none ]] || echo "$PSS_LEVEL" ;;
  *"get secret microcrm-db-app"*) [[ "$APP_SECRET_EXISTS" == 1 ]] || exit 1 ;;
  *"get secret"*) [[ "$SECRET_EXISTS" == 1 ]] || exit 1 ;;
  *"create secret"*) echo "stdin: $(cat)" >>"$CALLS_LOG" ;;
  *exec*) exit "$SMOKE_EXIT" ;;
esac
STUB
  chmod +x "$FAKE_REPO/bin/kubectl"
}

# Faux helm : note ses paramètres ; « history » affiche la révision 2 ;
# « package » crée une archive vide dans le dossier --destination (dernier
# paramètre) et note ce dossier, pour vérifier son effacement
make_helm() {
  cat >"$FAKE_REPO/bin/helm" <<'STUB'
#!/usr/bin/env bash
echo "helm $*" >>"$CALLS_LOG"
if [[ "$1" == history ]]; then
  printf 'REVISION\tSTATUS\n2\tdeployed\n'
fi
if [[ "$1" == package ]]; then
  [[ "${PACKAGE_EXIT:-0}" == 0 ]] || exit 1
  touch "${*: -1}/microcrm-0.1.0.tgz"
  echo "${*: -1}" >"$CALLS_LOG.package-dir"
fi
# UPGRADE_EXIT=1 simule des pods jamais prêts (Helm a déjà remis la
# version précédente)
[[ "$1" == upgrade ]] && exit "${UPGRADE_EXIT:-0}"
exit 0
STUB
  chmod +x "$FAKE_REPO/bin/helm"
}

# Lance le script copié, faux outils en tête du PATH ; stderr joint à
# stdout ; aucune attente entre les essais du test de fumée
run_deploy() {
  CALLS_LOG="$FAKE_REPO/calls.log" PATH="$FAKE_REPO/bin:$PATH" \
    SMOKE_DELAY=0 "$FAKE_REPO/scripts/deploy.sh" "$@" 2>&1
}

# Journal des appels reçus par les faux outils, pour les vérifier
calls() {
  cat "$FAKE_REPO/calls.log"
}

function test_without_parameter_prints_usage_with_code_2() {
  local output
  output="$(run_deploy)"
  assert_exit_code "2"
  assert_contains "Usage: deploy.sh dev|staging|prod [TAG]" "$output"
}

function test_unknown_environment_is_refused_with_code_2() {
  run_deploy demo >/dev/null
  assert_exit_code "2"
}

function test_invalid_image_tag_is_refused_with_code_2() {
  local output
  output="$(run_deploy dev 'v1.2.3,front.replicas=9')"
  assert_exit_code "2"
  assert_contains "fix: use vX.Y.Z or sha-xxxxxxx" "$output"
}

function test_missing_namespace_stops_with_a_fix() {
  local output
  output="$(PSS_LEVEL="" run_deploy dev)"
  assert_exit_code "1"
  assert_contains "namespace dev not found" "$output"
}

function test_namespace_without_restricted_level_is_refused() {
  local output
  output="$(PSS_LEVEL=none run_deploy dev)"
  assert_exit_code "1"
  assert_contains "pod-security.kubernetes.io/enforce=restricted" "$output"
}

function test_missing_secret_is_created_through_a_pipe() {
  SECRET_EXISTS=0 run_deploy dev >/dev/null
  assert_successful_code
  # La valeur arrive par le tube, jamais dans les paramètres de kubectl
  assert_contains "--from-file=password=/dev/stdin" "$(calls)"
  assert_contains "stdin: $(printf '%064d' 7)" "$(calls)"
  assert_not_contains "from-literal" "$(calls)"
}

function test_existing_secret_is_kept() {
  run_deploy dev >/dev/null
  assert_not_contains "create secret" "$(calls)"
}

# Environnement déjà installé : seul le Secret du compte limité manque ;
# celui du superutilisateur (base existante) est gardé tel quel
function test_missing_app_secret_is_created_and_admin_secret_kept() {
  APP_SECRET_EXISTS=0 run_deploy dev >/dev/null
  assert_successful_code
  assert_contains "create secret generic microcrm-db-app" "$(calls)"
  assert_not_contains "create secret generic microcrm-db " "$(calls)"
}

function test_deploy_lints_then_upgrades_with_environment_values() {
  run_deploy staging >/dev/null
  assert_successful_code
  assert_contains "helm lint --quiet" "$(calls)"
  assert_contains "upgrade --install microcrm" "$(calls)"
  assert_contains "-n staging -f" "$(calls)"
  assert_contains "values-staging.yaml" "$(calls)"
  assert_contains "--rollback-on-failure --wait --timeout 6m" "$(calls)"
}

function test_tag_sets_both_images() {
  run_deploy dev v1.2.3 >/dev/null
  assert_contains "--set front.image.tag=v1.2.3" "$(calls)"
  assert_contains "--set back.image.tag=v1.2.3" "$(calls)"
  # L'image déployée est écrite dans l'historique de Helm
  assert_contains "--description image v1.2.3" "$(calls)"
}

function test_tag_packages_the_chart_with_the_deployed_version() {
  local dir
  run_deploy dev v1.2.3 >/dev/null
  assert_successful_code
  dir="$(cat "$FAKE_REPO/calls.log.package-dir")"
  # Numéro sans le « v » (appVersion), puis installation de l'archive
  assert_contains "helm package $FAKE_REPO/infra/helm/microcrm" "$(calls)"
  assert_contains "--app-version 1.2.3" "$(calls)"
  assert_contains "upgrade --install microcrm $dir/microcrm-0.1.0.tgz" \
    "$(calls)"
  # Dossier temporaire effacé à la sortie
  assert_directory_not_exists "$dir"
}

function test_without_tag_the_chart_folder_is_installed_as_is() {
  local chart="$FAKE_REPO/infra/helm/microcrm"
  run_deploy dev >/dev/null
  assert_not_contains "helm package" "$(calls)"
  assert_contains "upgrade --install microcrm $chart " "$(calls)"
}

function test_failed_packaging_stops_before_upgrade() {
  local output
  output="$(PACKAGE_EXIT=1 run_deploy dev sha-0000000)"
  assert_exit_code "1"
  assert_contains "packaging of the chart failed" "$output"
  assert_not_contains "upgrade --install" "$(calls)"
}

function test_failed_upgrade_stops_without_smoke_test() {
  local output
  output="$(UPGRADE_EXIT=1 run_deploy dev sha-0000000)"
  assert_exit_code "1"
  assert_contains "previous version kept by Helm" "$output"
  assert_not_contains "exec" "$(calls)"
}

function test_failed_smoke_test_rolls_back_and_fails() {
  local output
  output="$(SMOKE_EXIT=1 run_deploy dev)"
  assert_exit_code "1"
  assert_contains "helm rollback microcrm -n dev" "$(calls)"
  assert_contains "failed the smoke test" "$output"
}

function test_rollback_to_a_chosen_revision() {
  run_deploy rollback prod 3 >/dev/null
  assert_successful_code
  assert_contains "helm rollback microcrm 3 -n prod --wait" "$(calls)"
}

function test_rollback_with_invalid_revision_is_refused() {
  run_deploy rollback dev abc >/dev/null
  assert_exit_code "2"
}
