# Fichier  : infra/openbao/config/tests/config.tftest.hcl
# Rôle     : tests unitaires de la configuration d'OpenBao (tofu test),
#            avec un faux fournisseur : aucun coffre nécessaire
# Utilise  : les fichiers .tf du dossier parent
# Utilisé par : job opentofu de la CI ; en local : tofu test

mock_provider "vault" {}

variables {
  openbao_ca_file = "/dev/null"
}

# Chaque rôle exige notre dépôt, la branche main, son environnement et
# l'audience d'OpenBao
run "roles_are_bound_to_repo_branch_and_environment" {
  command = plan

  assert {
    condition = alltrue([
      for env, r in vault_jwt_auth_backend_role.ci :
      r.bound_claims["repository_id"] == "1436771310"
      && r.bound_claims["ref"] == "refs/heads/main"
      && r.bound_subject == "repo:yohanbouchet/orion:environment:${env}"
      && r.bound_audiences == toset(["openbao-orion"])
    ])
    error_message = "Each CI role must be bound to the repository, main and its environment."
  }
  assert {
    condition = (
      vault_jwt_auth_backend_role.ci["production"].bound_claims["job_workflow_ref"]
      == "yohanbouchet/orion/.github/workflows/deploy.yml@refs/heads/main"
    )
    error_message = "Only deploy.yml may get a production token."
  }
}

# Une règle ne donne que le jeton de son environnement
run "policies_only_allow_their_own_credentials" {
  command = plan

  assert {
    condition = alltrue([
      for env, p in vault_policy.ci :
      strcontains(p.policy, "kubernetes/creds/${env}\"")
      && !strcontains(p.policy, "*")
    ])
    error_message = "A CI policy must only allow its own credentials path."
  }
  assert {
    condition = alltrue([
      for r in vault_jwt_auth_backend_role.ci : r.token_no_default_policy
    ])
    error_message = "CI tokens must not get the default policy."
  }
}

# Jetons Kubernetes : namespace unique, compte deployer, 45 min au plus
run "kubernetes_tokens_are_short_and_scoped" {
  command = plan

  assert {
    condition = alltrue([
      for env, r in vault_kubernetes_secret_backend_role.deployer :
      length(r.allowed_kubernetes_namespaces) == 1
      && r.service_account_name == "deployer"
      && r.token_max_ttl <= 2700
    ])
    error_message = "Kubernetes tokens must be scoped to one namespace and last 45 min at most."
  }
  assert {
    condition     = vault_kubernetes_secret_backend_role.deployer["production"].allowed_kubernetes_namespaces[0] == "prod"
    error_message = "The production role must target the prod namespace."
  }
}

# Durée hors bornes refusée
run "too_long_ttl_is_refused" {
  command = plan

  variables {
    environments = {
      dev = { namespace = "dev", workflows = ["deploy.yml"], ttl = 86400 }
    }
  }
  expect_failures = [var.environments]
}
