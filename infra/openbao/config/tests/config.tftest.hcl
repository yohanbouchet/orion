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
      && r.bound_subject == "repo:yohanbouchet@184980551/orion@1436771310:environment:${env}"
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

# SonarQube : lecture du seul jeton d'analyse, environnement sonarqube,
# workflow ci.yml de notre dépôt, main ou une PR
run "sonarqube_role_reads_only_its_token" {
  command = plan

  assert {
    condition = (
      vault_jwt_auth_backend_role.ci_sonarqube.bound_subject
      == "repo:yohanbouchet@184980551/orion@1436771310:environment:sonarqube"
      && vault_jwt_auth_backend_role.ci_sonarqube.bound_claims["repository_id"] == "1436771310"
      && vault_jwt_auth_backend_role.ci_sonarqube.bound_claims["job_workflow_ref"]
      == "yohanbouchet/orion/.github/workflows/ci.yml@*"
    )
    error_message = "The SonarQube role must be bound to the repository, its environment and ci.yml."
  }
  assert {
    condition = (
      strcontains(vault_policy.ci_sonarqube.policy, "kv/data/ci/sonarqube\"")
      && strcontains(vault_policy.ci_sonarqube.policy, "[\"read\"]")
    )
    error_message = "The SonarQube policy must only read its token."
  }
}

# Sauvegarde : lecture de l'instantané seulement ; jeton orphelin,
# périodique (7 jours), jamais avec la règle root
run "backup_token_only_reads_the_snapshot" {
  command = plan

  assert {
    condition = (
      strcontains(vault_policy.openbao_backup.policy, "\"sys/storage/raft/snapshot\"")
      && strcontains(vault_policy.openbao_backup.policy, "[\"read\"]")
      && length(regexall("path ", vault_policy.openbao_backup.policy)) == 1
    )
    error_message = "The backup policy must only read the Raft snapshot."
  }
  assert {
    condition = (
      vault_token_auth_backend_role.openbao_backup.allowed_policies == toset(["openbao-backup"])
      && contains(tolist(vault_token_auth_backend_role.openbao_backup.disallowed_policies), "root")
      && vault_token_auth_backend_role.openbao_backup.orphan
      && vault_token_auth_backend_role.openbao_backup.token_period == 604800
    )
    error_message = "The backup token must be an orphan 7-day periodic token limited to openbao-backup."
  }
}

# Une durée de jeton de sauvegarde au-delà de 31 jours est refusée
run "backup_token_period_is_bounded" {
  command = plan

  variables {
    backup_token_period = 31536000
  }
  expect_failures = [var.backup_token_period]
}
