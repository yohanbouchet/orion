# Fichier  : infra/terraform/tests/cluster.tftest.hcl
# Rôle     : tests unitaires du socle (terraform test), avec un faux
#            fournisseur Kubernetes : aucun cluster nécessaire
# Utilise  : les fichiers .tf du dossier parent
# Utilisé par : job terraform de la CI ; en local : terraform test

# Faux fournisseur : les ressources sont « planifiées » sans cluster
mock_provider "kubernetes" {}

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
}

run "unknown_environment_is_refused" {
  command = plan

  variables {
    environments = ["dev", "demo"]
  }
  expect_failures = [var.environments]
}
