# Fichier  : infra/terraform/main.tf
# Rôle     : un namespace par environnement, au niveau de sécurité Pod
#            Security « restricted » (un pod root ou privilégié y est
#            refusé)
# Utilise  : variables.tf (environments)
# Utilisé par : rbac.tf ; scripts/deploy.sh (vérifie le niveau) ; ticket
#               #64

resource "kubernetes_namespace_v1" "env" {
  for_each = var.environments

  metadata {
    name = each.key
    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = var.pod_security_version
      "app.kubernetes.io/part-of"                  = "microcrm"
      "app.kubernetes.io/managed-by"               = "opentofu"
    }
  }
}
