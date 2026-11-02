# Fichier  : infra/terraform/variables.tf
# Rôle     : réglages du socle du cluster, avec leurs valeurs par défaut
# Utilise  : rien
# Utilisé par : providers.tf, main.tf, rbac.tf ; tests/

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
