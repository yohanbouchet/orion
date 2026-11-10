# Fichier  : infra/openbao/config/outputs.tf
# Rôle     : valeurs à reporter dans la CI (publiques)
# Utilise  : main.tf
# Utilisé par : l'Ops (tofu output)

output "github_audience" {
  description = "Audience the CI must request for its OIDC token"
  value       = local.github_audience
}

output "ci_roles" {
  description = "OpenBao role of each GitHub environment"
  value = merge(
    { for env, r in vault_jwt_auth_backend_role.ci : env => r.role_name },
    { sonarqube = vault_jwt_auth_backend_role.ci_sonarqube.role_name }
  )
}
