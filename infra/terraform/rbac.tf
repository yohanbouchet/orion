# Fichier  : infra/terraform/rbac.tf
# Rôle     : un compte de service « deployer » par environnement, avec
#            les seuls droits nécessaires à scripts/deploy.sh (et, en
#            staging, à scripts/zap-scan.sh et load-test.sh) dans SON
#            namespace ; aucun jeton rangé : OpenBao délivre des jetons
#            courts (openbao.tf)
# Utilise  : main.tf (namespaces)
# Utilisé par : jobs de déploiement, de ZAP et de test de charge de la
#               CI (jeton OpenBao) ; openbao.tf ; ticket #64

locals {
  # Comptes deployer réduits à leurs métadonnées (nom, namespace) : boucler
  # sur l'objet complet reprendrait son attribut déprécié
  # default_secret_name (signalé par OpenTofu)
  deployers = {
    for env, account in kubernetes_service_account_v1.deployer :
    env => account.metadata[0]
  }
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
# Helm (Secrets), lecture des pods, test de fumée (exec), Job ZAP en
# staging ; rien d'autre
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
  # Test d'intrusion ZAP (scripts/zap-scan.sh, Job Kubernetes) : staging
  # seulement ; ailleurs, la liste est vide et la règle n'existe pas
  dynamic "rule" {
    for_each = each.key == "staging" ? ["jobs"] : []
    content {
      api_groups = ["batch"]
      resources  = [rule.value]
      verbs      = local.manage
    }
  }
}

resource "kubernetes_role_binding_v1" "deployer" {
  for_each = local.deployers

  metadata {
    name      = "deployer"
    namespace = each.value.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.deployer[each.key].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = each.value.name
    namespace = each.value.namespace
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
  for_each = local.deployers

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
    name      = each.value.name
    namespace = each.value.namespace
  }
}

# Aucun jeton de longue durée (supprimés le 10/11/2026) : la CI reçoit un
# jeton de 15 min du compte, délivré par OpenBao contre le badge OIDC de
# son job (openbao.tf, infra/openbao/config)
