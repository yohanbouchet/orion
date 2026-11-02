# Fichier  : infra/terraform/rbac.tf
# Rôle     : un compte de service « deployer » par environnement, avec
#            les seuls droits nécessaires à scripts/deploy.sh dans SON
#            namespace, et son jeton (rangé ensuite dans l'environnement
#            GitHub correspondant)
# Utilise  : main.tf (namespaces)
# Utilisé par : jobs de déploiement de la CI (jeton) ; outputs.tf ;
#               ticket #64

locals {
  # Droits complets sur un type d'objet du chart
  manage = ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Lecture seule
  read = ["get", "list", "watch"]
}

resource "kubernetes_service_account_v1" "deployer" {
  for_each = kubernetes_namespace_v1.env

  metadata {
    name      = "deployer"
    namespace = each.value.metadata[0].name
  }
  # Ce compte ne sert qu'à la CI : aucun pod ne reçoit son jeton
  automount_service_account_token = false
}

# Droits limités au namespace : objets créés par le chart, historique
# Helm (Secrets), lecture des pods, test de fumée (exec) ; rien d'autre
resource "kubernetes_role_v1" "deployer" {
  for_each = kubernetes_namespace_v1.env

  metadata {
    name      = "deployer"
    namespace = each.value.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets", "services"]
    verbs      = local.manage
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "events", "persistentvolumeclaims"]
    verbs      = local.read
  }
  # Test de fumée de deploy.sh (kubectl exec dans le pod du front)
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets"]
    verbs      = local.manage
  }
  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = local.read
  }
  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = local.manage
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies"]
    verbs      = local.manage
  }
}

resource "kubernetes_role_binding_v1" "deployer" {
  for_each = kubernetes_service_account_v1.deployer

  metadata {
    name      = "deployer"
    namespace = each.value.metadata[0].namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.deployer[each.key].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = each.value.metadata[0].name
    namespace = each.value.metadata[0].namespace
  }
}

# deploy.sh lit le niveau de sécurité de SON namespace : objet de tout le
# cluster, donc un droit à part, limité à ce seul namespace
resource "kubernetes_cluster_role_v1" "namespace_reader" {
  for_each = kubernetes_namespace_v1.env

  metadata {
    name = "microcrm-deployer-${each.key}-namespace"
  }
  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    resource_names = [each.key]
    verbs          = ["get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "namespace_reader" {
  for_each = kubernetes_service_account_v1.deployer

  metadata {
    name = "microcrm-deployer-${each.key}-namespace"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.namespace_reader[each.key].id
  }
  subject {
    kind      = "ServiceAccount"
    name      = each.value.metadata[0].name
    namespace = each.value.metadata[0].namespace
  }
}

# Jeton de longue durée du compte (limite connue : rotation manuelle ;
# cible : fédération OIDC GitHub → cluster, jetons de quelques minutes)
resource "kubernetes_secret_v1" "deployer_token" {
  for_each = kubernetes_service_account_v1.deployer

  metadata {
    name      = "deployer-token"
    namespace = each.value.metadata[0].namespace
    annotations = {
      "kubernetes.io/service-account.name" = each.value.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}
