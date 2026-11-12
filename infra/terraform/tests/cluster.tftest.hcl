# Fichier  : infra/terraform/tests/cluster.tftest.hcl
# Rôle     : tests unitaires du socle, de la supervision et d'OpenBao
#            (tofu test), avec de faux fournisseurs Kubernetes, Helm et
#            TLS : aucun cluster nécessaire
# Utilise  : les fichiers .tf du dossier parent
# Utilisé par : job opentofu de la CI ; en local : tofu test

# Faux fournisseurs : les ressources sont « planifiées » sans cluster
mock_provider "kubernetes" {}

# Certificat du cluster : OpenTofu remplit les attributs calculés d'une
# table vide ; certificat fictif, lu par outputs.tf
override_data {
  target = data.kubernetes_config_map_v1.cluster_ca
  values = {
    data = {
      "ca.crt" = "test-ca"
    }
  }
}
mock_provider "helm" {}
# Certificats fictifs (aucune clé réelle créée pendant les tests)
mock_provider "tls" {}

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
  assert {
    condition = alltrue([
      for ns in concat(values(kubernetes_namespace_v1.env), [
        kubernetes_namespace_v1.monitoring, kubernetes_namespace_v1.openbao,
        kubernetes_namespace_v1.headlamp,
      ]) :
      ns.metadata[0].labels["pod-security.kubernetes.io/enforce-version"]
      == "v1.37"
    ])
    error_message = "The Pod Security version must be pinned on every namespace."
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

# Une version de règles non figée est refusée
run "unpinned_pod_security_is_refused" {
  command = plan

  variables {
    pod_security_version = "latest"
  }
  expect_failures = [var.pod_security_version]
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
  assert {
    condition = (
      kubernetes_namespace_v1.monitoring_collector.metadata[0].labels["pod-security.kubernetes.io/warn-version"]
      == var.pod_security_version
    )
    error_message = "The collector warning must use the pinned Pod Security version."
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
    condition     = length(kubernetes_config_map_v1.dashboard) == 4
    error_message = "Four dashboards are expected."
  }
}

run "non_gmail_alert_address_is_refused" {
  command = plan

  variables {
    ops_email = "ops@example.org"
  }
  expect_failures = [var.ops_email]
}

# OpenBao : namespace restricted, chart figé, et les réglages de
# sécurité de values.yaml ne disparaissent pas par erreur
run "openbao_is_locked_down" {
  command = plan

  assert {
    condition = (
      kubernetes_namespace_v1.openbao.metadata[0].labels["pod-security.kubernetes.io/enforce"]
      == "restricted"
    )
    error_message = "The openbao namespace must enforce restricted."
  }
  assert {
    condition     = helm_release.openbao.version == "0.30.7"
    error_message = "The OpenBao chart version must be pinned."
  }
  assert {
    condition = (
      yamldecode(helm_release.openbao.values[0]).global.tlsDisable == false
      && yamldecode(helm_release.openbao.values[0]).injector.enabled == false
      && yamldecode(helm_release.openbao.values[0]).server.networkPolicy.enabled == true
      && yamldecode(helm_release.openbao.values[0]).server.statefulSet.securityContext.container.readOnlyRootFilesystem == true
    )
    error_message = "OpenBao must keep TLS, no injector, a network policy and a read-only root filesystem."
  }
  assert {
    condition = strcontains(
      yamldecode(helm_release.openbao.values[0]).server.standalone.config,
      "audit \"file\" \"stdout\""
    )
    error_message = "OpenBao must declare its audit device in the configuration."
  }
  assert {
    condition = alltrue([
      for r in kubernetes_role_v1.openbao_token_issuer :
      length(r.rule) == 1
      && toset(r.rule[0].resources) == toset(["serviceaccounts/token"])
      && toset(r.rule[0].resource_names) == toset(["deployer"])
      && toset(r.rule[0].verbs) == toset(["create"])
    ])
    error_message = "OpenBao may only create tokens of the deployer accounts."
  }
  assert {
    condition     = tls_private_key.openbao_ca.algorithm == "ECDSA"
    error_message = "The OpenBao CA key must be ECDSA."
  }
}

# Headlamp : lecture seule (rôle « view »), jamais cluster-admin, chart
# figé, conteneur en lecture seule, aucune entrée réseau
run "headlamp_is_read_only" {
  command = plan

  assert {
    condition = (
      kubernetes_namespace_v1.headlamp.metadata[0].labels["pod-security.kubernetes.io/enforce"]
      == "restricted"
      && helm_release.headlamp.version == "0.46.0"
    )
    error_message = "Headlamp must run in a restricted namespace with a pinned chart."
  }
  assert {
    condition = (
      kubernetes_cluster_role_binding_v1.headlamp_viewer.role_ref[0].name == "view"
      && yamldecode(helm_release.headlamp.values[0]).clusterRoleBinding.create == false
    )
    error_message = "Headlamp must stay read-only: view role, never cluster-admin."
  }
  assert {
    condition = (
      yamldecode(helm_release.headlamp.values[0]).securityContext.readOnlyRootFilesystem == true
      && yamldecode(helm_release.headlamp.values[0]).securityContext.allowPrivilegeEscalation == false
      && length(kubernetes_network_policy_v1.headlamp_deny_ingress.spec[0].ingress) == 0
    )
    error_message = "Headlamp must keep a read-only root filesystem and refuse all ingress."
  }
}
