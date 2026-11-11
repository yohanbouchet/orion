# Fichier  : infra/terraform/variables.tf
# Rôle     : réglages du socle du cluster, avec leurs valeurs par défaut
# Utilise  : rien
# Utilisé par : providers.tf, main.tf, rbac.tf, monitoring.tf, openbao.tf ;
#               tests/

variable "kubeconfig_path" {
  description = "Path of the kubeconfig file used to reach the cluster"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubeconfig context of the Minikube cluster"
  type        = string
  default     = "orion"
}

# Version des règles Pod Security appliquées aux namespaces : figée,
# comme toute version du dépôt (« latest » changerait le règlement à la
# prochaine montée de Kubernetes, sans PR) ; à monter avec le cluster,
# avec infra/arc/namespace.yaml et infra/sonarqube/namespace.yaml
variable "pod_security_version" {
  description = "Pinned version of the Pod Security Standards (vX.Y)"
  type        = string
  default     = "v1.37"

  validation {
    condition     = can(regex("^v1\\.[0-9]+$", var.pod_security_version))
    error_message = "The Pod Security version must be pinned (v1.N), never latest."
  }
}

variable "environments" {
  description = "Environments of MicroCRM, one namespace each"
  type        = set(string)
  default     = ["dev", "staging", "prod"]

  # Mêmes noms que scripts/deploy.sh et les values du chart
  validation {
    condition = alltrue([
      for env in var.environments : contains(["dev", "staging", "prod"], env)
    ])
    error_message = "Environments must be dev, staging or prod."
  }
}

# Donnée personnelle : jamais dans le dépôt ; fournie par un fichier
# rangé hors du dépôt (voir README) ; masquée dans le plan, mais écrite
# en clair dans l'état (lui aussi hors du dépôt)
variable "ops_email" {
  description = "Mailbox that receives the alerts (Gmail account)"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@ ]+@gmail\\.com$", var.ops_email))
    error_message = "The alert mailbox must be a Gmail address."
  }
}
