# Fichier  : infra/terraform/headlamp.tf
# Rôle     : Headlamp, interface web de Kubernetes en LECTURE SEULE pour
#            l'Ops : namespace « restricted », compte headlamp-viewer
#            (rôle « view » : tout voir sauf les Secrets, rien modifier),
#            pare-feu qui refuse toute entrée, chart officiel
# Utilise  : infra/headlamp/values.yaml (réglages du chart)
# Utilisé par : tofu apply (l'Ops) ; utilisation : infra/headlamp/README.md

resource "kubernetes_namespace_v1" "headlamp" {
  metadata {
    name = "headlamp"
    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = var.pod_security_version
      "app.kubernetes.io/part-of"                  = "headlamp"
      "app.kubernetes.io/managed-by"               = "opentofu"
    }
  }
}

# Compte avec lequel l'Ops se connecte : un jeton court est créé à la
# demande (kubectl create token, 1 h) ; aucun jeton permanent
resource "kubernetes_service_account_v1" "headlamp_viewer" {
  metadata {
    name      = "headlamp-viewer"
    namespace = kubernetes_namespace_v1.headlamp.metadata[0].name
  }
  automount_service_account_token = false
}

# Rôle « view » fourni par Kubernetes : lecture de presque tout (pods,
# journaux, déploiements…), jamais des Secrets, aucune modification
resource "kubernetes_cluster_role_binding_v1" "headlamp_viewer" {
  metadata {
    name = "headlamp-viewer"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.headlamp_viewer.metadata[0].name
    namespace = kubernetes_namespace_v1.headlamp.metadata[0].name
  }
}

# Aucune entrée réseau depuis les autres pods : l'Ops passe par un tunnel
# (kubectl port-forward), qui ne traverse pas le réseau des pods
resource "kubernetes_network_policy_v1" "headlamp_deny_ingress" {
  metadata {
    name      = "deny-all-ingress"
    namespace = kubernetes_namespace_v1.headlamp.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "helm_release" "headlamp" {
  name       = "headlamp"
  repository = "https://kubernetes-sigs.github.io/headlamp/"
  chart      = "headlamp"
  # Dernière version (16/10/2026, Headlamp 0.46.0) ; montée par une PR
  version   = "0.46.0"
  namespace = kubernetes_namespace_v1.headlamp.metadata[0].name

  values      = [file("${path.module}/../headlamp/values.yaml")]
  max_history = 5
}
