# Fichier  : infra/openbao/config/main.tf
# Rôle     : identité de la CI : un job GitHub présente son badge OIDC
#            (jeton signé par GitHub) et reçoit un jeton Kubernetes court
#            du compte deployer de SON environnement ; plus aucun jeton
#            longue durée rangé dans GitHub
# Utilise  : variables.tf ; droits donnés à OpenBao dans
#            infra/terraform/rbac.tf (créer des jetons des deployer)
# Utilisé par : .github/actions/kube-access (connexion et jeton)

locals {
  # Badges acceptés : émis par GitHub Actions, pour OpenBao seulement
  # (audience propre : un badge demandé pour un autre service est refusé)
  github_issuer   = "https://token.actions.githubusercontent.com"
  github_audience = "openbao-orion"
  # Début du nom (sub) d'un job, format « immuable » : propriétaire et
  # dépôt suivis de leurs numéros, qui ne changent jamais (un dépôt
  # recréé sous le même nom n'a pas le même numéro)
  github_owner     = split("/", var.github_repository)[0]
  github_repo_name = split("/", var.github_repository)[1]
  github_sub_prefix = format(
    "repo:%s@%s/%s@%s", local.github_owner, var.github_owner_id,
    local.github_repo_name, var.github_repository_id
  )
}

# --- 1. Vérifier le badge de GitHub ------------------------------------
# Méthode « jwt » : OpenBao télécharge les clés publiques de GitHub et
# vérifie la signature, l'émetteur et la date de chaque badge
resource "vault_jwt_auth_backend" "github" {
  path               = "jwt"
  description        = "GitHub Actions OIDC tokens"
  oidc_discovery_url = local.github_issuer
  bound_issuer       = local.github_issuer
}

# Un rôle par environnement : le badge doit venir de NOTRE dépôt (par son
# identifiant), de la branche main, d'un job de cet environnement GitHub
# (approbation comprise pour production) et d'un workflow autorisé
resource "vault_jwt_auth_backend_role" "ci" {
  for_each = var.environments

  backend         = vault_jwt_auth_backend.github.path
  role_name       = "ci-${each.key}"
  role_type       = "jwt"
  bound_audiences = [local.github_audience]
  # sub = repo:<propriétaire>@<n°>/<dépôt>@<n°>:environment:<env> pour
  # un job lié à un environnement GitHub (refusé le 10/11 avec l'ancien
  # format repo:<propriétaire>/<dépôt> : « invalid subject (sub) claim »)
  bound_subject = "${local.github_sub_prefix}:environment:${each.key}"
  bound_claims = {
    repository_id = var.github_repository_id
    ref           = "refs/heads/main"
    # Plusieurs valeurs : séparées par une virgule (une suffit)
    job_workflow_ref = join(",", [
      for w in each.value.workflows :
      "${var.github_repository}/.github/workflows/${w}@refs/heads/main"
    ])
  }
  user_claim = "sub"
  # Jeton OpenBao : seulement la règle de cet environnement, aucune
  # règle par défaut ; durée du job au plus
  token_policies          = [vault_policy.ci[each.key].name]
  token_no_default_policy = true
  token_ttl               = each.value.ttl
  token_max_ttl           = each.value.ttl
}

# Règle d'un environnement : demander un jeton de SON deployer, rien
# d'autre (ni lecture de la configuration, ni autre environnement)
resource "vault_policy" "ci" {
  for_each = var.environments

  name   = "ci-${each.key}"
  policy = <<-EOT
    path "${vault_kubernetes_secret_backend.k8s.path}/creds/${each.key}" {
      capabilities = ["update"]
    }
  EOT
}

# --- 2. Délivrer un jeton Kubernetes court -----------------------------
# Moteur « kubernetes » : OpenBao demande à Kubernetes un jeton du compte
# deployer (API TokenRequest), qui expire seul ; OpenBao s'identifie avec
# le compte de service de son propre pod (dans le cluster)
resource "vault_kubernetes_secret_backend" "k8s" {
  path                      = "kubernetes"
  description               = "Short-lived tokens of the deployer accounts"
  kubernetes_host           = "https://kubernetes.default.svc"
  default_lease_ttl_seconds = 900
  max_lease_ttl_seconds     = 2700
}

resource "vault_kubernetes_secret_backend_role" "deployer" {
  for_each = var.environments

  backend                       = vault_kubernetes_secret_backend.k8s.path
  name                          = each.key
  allowed_kubernetes_namespaces = [each.value.namespace]
  # Compte existant (créé par infra/terraform/rbac.tf) : ses droits ne
  # changent pas, seule la durée du jeton change
  service_account_name = "deployer"
  token_default_ttl    = each.value.ttl
  token_max_ttl        = each.value.ttl
}
