# Fichier  : infra/openbao/config/variables.tf
# Rôle     : réglages de la configuration d'OpenBao : adresse, dépôt
#            GitHub autorisé, environnements et durée des accès
# Utilise  : rien
# Utilisé par : providers.tf, main.tf

variable "openbao_addr" {
  description = "OpenBao address, through kubectl port-forward"
  type        = string
  default     = "https://127.0.0.1:8200"
}

variable "openbao_ca_file" {
  description = "PEM file of the OpenBao CA (tofu output openbao_ca_cert)"
  type        = string
}

# Dépôt GitHub dont les jobs peuvent se présenter ; l'identifiant
# numérique ne change pas si un dépôt est renommé ou recréé sous le même
# nom (usurpation impossible)
variable "github_repository" {
  description = "GitHub repository allowed to authenticate (owner/name)"
  type        = string
  default     = "yohanbouchet/orion"
}

variable "github_repository_id" {
  description = "Numeric id of that repository"
  type        = string
  default     = "1436771310"
}

# Identifiant numérique du propriétaire : il figure dans le nom (sub) du
# job, format « immuable » de GitHub (réglage du dépôt, lu par l'API
# actions/oidc/customization/sub le 10/11/2026)
variable "github_owner_id" {
  description = "Numeric id of the repository owner"
  type        = string
  default     = "184980551"
}

# Un rôle par environnement GitHub : namespace visé, workflows autorisés
# et durée du jeton Kubernetes (au moins 10 min, minimum de Kubernetes ;
# au plus la durée maximale du job qui l'utilise)
variable "environments" {
  description = "GitHub environment => namespace, workflows and token TTL"
  type = map(object({
    namespace = string
    workflows = list(string)
    ttl       = number
  }))
  default = {
    dev = {
      namespace = "dev"
      workflows = ["deploy.yml"]
      ttl       = 900
    }
    staging = {
      namespace = "staging"
      workflows = ["deploy.yml", "zap.yml", "load-test.yml"]
      ttl       = 2700
    }
    production = {
      namespace = "prod"
      workflows = ["deploy.yml"]
      ttl       = 900
    }
  }

  validation {
    condition = alltrue([
      for e in values(var.environments) : e.ttl >= 600 && e.ttl <= 2700
    ])
    error_message = "Token TTL must be between 600 and 2700 seconds."
  }
}

# Durée de vie du jeton de sauvegarde sans sauvegarde (secondes) : assez
# pour un week-end prolongé poste éteint, pas plus de 31 jours
variable "backup_token_period" {
  description = "Backup token period in seconds (renewed by each backup)"
  type        = number
  default     = 604800
  validation {
    condition     = var.backup_token_period >= 86400 && var.backup_token_period <= 2678400
    error_message = "The backup token period must be between 1 and 31 days."
  }
}
