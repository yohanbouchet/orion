# Fichier  : infra/openbao/config/sonarqube.tf
# Rôle     : jeton d'analyse SonarQube rangé dans OpenBao (et plus dans
#            GitHub) : le job sonarqube le lit au vu de son badge OIDC ;
#            SonarQube ne sait pas créer de jetons courts : le jeton reste
#            de longue durée, mais chaque lecture est tracée (audit)
# Utilise  : main.tf (méthode jwt, préfixe du nom des jobs)
# Utilisé par : job sonarqube de .github/workflows/ci.yml (action
#               .github/actions/openbao-secret)
# La VALEUR du jeton n'est jamais dans OpenTofu (elle finirait dans
# l'état) : l'Ops l'écrit dans OpenBao (README, « Jeton SonarQube »)

# Coffre à secrets statiques (moteur kv, version 2 : historique des
# versions, une valeur effacée par erreur se récupère)
resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv"
  description = "Static CI secrets (values written by the Ops, not by OpenTofu)"
  options = {
    version = "2"
  }
}

# Lecture du seul jeton SonarQube
resource "vault_policy" "ci_sonarqube" {
  name   = "ci-sonarqube"
  policy = <<-EOT
    path "${vault_mount.kv.path}/data/ci/sonarqube" {
      capabilities = ["read"]
    }
  EOT
}

# Le job sonarqube tourne sur main ET sur les PR du dépôt (analyse du
# code proposé) : conditions par motif (glob) pour la branche et le
# workflow ; environnement GitHub sonarqube obligatoire (nom du job) ;
# les PR venant d'un fork et Dependabot ne lancent pas ce job (ci.yml)
resource "vault_jwt_auth_backend_role" "ci_sonarqube" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "ci-sonarqube"
  role_type         = "jwt"
  bound_audiences   = [local.github_audience]
  bound_subject     = "${local.github_sub_prefix}:environment:sonarqube"
  bound_claims_type = "glob"
  bound_claims = {
    repository_id    = var.github_repository_id
    ref              = "refs/heads/main,refs/pull/*/merge"
    job_workflow_ref = "${var.github_repository}/.github/workflows/ci.yml@*"
  }
  user_claim              = "sub"
  token_policies          = [vault_policy.ci_sonarqube.name]
  token_no_default_policy = true
  # Le jeton OpenBao ne sert qu'à une lecture, au début du job
  token_ttl     = 300
  token_max_ttl = 300
}
