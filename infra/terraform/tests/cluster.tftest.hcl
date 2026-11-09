# Fichier  : infra/terraform/tests/cluster.tftest.hcl
# Rôle     : tests unitaires du socle et de la supervision (tofu test),
#            avec de faux fournisseurs Kubernetes et Helm : aucun cluster
#            nécessaire
# Utilise  : les fichiers .tf du dossier parent
# Utilisé par : job opentofu de la CI ; en local : tofu test

# Faux fournisseurs : les ressources sont « planifiées » sans cluster
mock_provider "kubernetes" {
  # Secrets des jetons : OpenTofu remplit les attributs calculés d'une
  # table vide ; jeton et certificat fictifs, lus par outputs.tf
  mock_resource "kubernetes_secret_v1" {
    defaults = {
      data = {
        token    = "test-token"
        "ca.crt" = "test-ca"
      }
    }
  }
}
mock_provider "helm" {}

# Adresse fictive pour les tests (la vraie n'est jamais dans le dépôt)
variables {
  ops_email = "ops.test@gmail.com"
}

run "three_restricted_namespaces" {
  command = plan

  assert {
    condition     = length(kubernetes_namespace_v1.env) == 3
    error_message = "One namespace per environment is expected."
  }
  assert {
    condition = alltrue([
      for ns in kubernetes_namespace_v1.env :
      ns.metadata[0].labels["pod-security.kubernetes.io/enforce"]
      == "restricted"
    ])
    error_message = "Every namespace must enforce Pod Security restricted."
  }
}

run "deployer_rights_stay_in_their_namespace" {
  command = plan

  assert {
    condition = alltrue([
      for sa in kubernetes_service_account_v1.deployer :
      sa.automount_service_account_token == false
    ])
    error_message = "No pod may receive a deployer token."
  }
  # Aucun joker « * » : chaque droit est nommé
  assert {
    condition = alltrue(flatten([
      for role in kubernetes_role_v1.deployer : [
        for rule in role.rule :
        !contains(setunion(rule.verbs, rule.resources), "*")
      ]
    ]))
    error_message = "Roles must not use wildcards."
  }
  # Droit sur tout le cluster : lecture de SON namespace seulement
  assert {
    condition = alltrue([
      for env, cr in kubernetes_cluster_role_v1.namespace_reader :
      cr.rule[0].resource_names == tolist([env])
      && cr.rule[0].verbs == tolist(["get"])
    ])
    error_message = "A deployer may only read its own namespace."
  }
  # Jobs (test d'intrusion ZAP) : seulement le deployer de staging
  assert {
    condition = alltrue([
      for env, role in kubernetes_role_v1.deployer :
      anytrue([for rule in role.rule : contains(rule.resources, "jobs")])
      == (env == "staging")
    ])
    error_message = "Only the staging deployer may manage jobs (ZAP)."
  }
}

run "unknown_environment_is_refused" {
  command = plan

  variables {
    environments = ["dev", "demo"]
  }
  expect_failures = [var.environments]
}

# Supervision : seul le namespace du collecteur assouplit la sécurité, et
# il avertit de tout écart à « restricted »
run "monitoring_namespaces_security" {
  command = plan

  assert {
    condition = (
      kubernetes_namespace_v1.monitoring.metadata[0].labels["pod-security.kubernetes.io/enforce"]
      == "restricted"
    )
    error_message = "The monitoring namespace must enforce restricted."
  }
  assert {
    condition = (
      kubernetes_namespace_v1.monitoring_collector.metadata[0].labels["pod-security.kubernetes.io/warn"]
      == "restricted"
    )
    error_message = "The collector namespace must warn about restricted."
  }
}

# Chart figé à une version précise ; un tableau de bord par fichier JSON
run "monitoring_stack_is_pinned" {
  command = plan

  assert {
    condition     = helm_release.monitoring.version == "0.97.1"
    error_message = "The monitoring chart version must be pinned."
  }
  assert {
    condition     = length(kubernetes_config_map_v1.dashboard) == 3
    error_message = "Three dashboards are expected."
  }
}

run "non_gmail_alert_address_is_refused" {
  command = plan

  variables {
    ops_email = "ops@example.org"
  }
  expect_failures = [var.ops_email]
}
