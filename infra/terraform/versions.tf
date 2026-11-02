# Fichier  : infra/terraform/versions.tf
# Rôle     : versions exigées de Terraform et du fournisseur Kubernetes ;
#            dossier d'état choisi au lancement (hors du dépôt)
# Utilise  : rien
# Utilisé par : terraform init (ce dossier) ; job terraform de la CI

terraform {
  # Branche 1.17 maintenue (vérifiée sur endoflife.date le 02/11/2026)
  required_version = ">= 1.17.0, < 2.0.0"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # 3.4.x seulement : une 3.5 peut changer les ressources (la 3.4 a
      # migré kubernetes_role_v1) ; montée de version par une PR
      version = "~> 3.4.0"
    }
  }

  # État local, rangé HORS du dépôt : il contient les jetons des comptes
  # deployer ; chemin donné à terraform init (-backend-config)
  backend "local" {}
}
