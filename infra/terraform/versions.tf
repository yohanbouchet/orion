# Fichier  : infra/terraform/versions.tf
# Rôle     : versions exigées d'OpenTofu et des fournisseurs Kubernetes,
#            Helm et TLS ; dossier d'état choisi au lancement (hors du dépôt)
# Utilise  : rien
# Utilisé par : tofu init (ce dossier) ; job opentofu de la CI

# Fichiers écrits dans le langage de Terraform (HCL), exécutés par
# OpenTofu, son successeur open source (licence MPL-2.0, fondation Linux),
# depuis le 09/11/2026 ; le bloc s'appelle toujours « terraform »
terraform {
  # Branche 1.13, la plus récente (1.13.9 du 05/11/2026)
  required_version = ">= 1.13.0, < 2.0.0"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # 3.4.x seulement : une 3.5 peut changer les ressources (la 3.4 a
      # migré kubernetes_role_v1) ; montée de version par une PR
      version = "~> 3.4.0"
    }
    # Installe la pile de supervision (chart Helm) ; 3.3 = dernière
    # version, vérifiée le 04/11/2026 ; montée de version par une PR
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3.0"
    }
    # Certificat TLS d'OpenBao (autorité propre au cluster) ; 4.4 =
    # dernière version, vérifiée le 09/11/2026 sur registry.opentofu.org
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4.0"
    }
  }

  # État local, rangé HORS du dépôt : il contient en clair les jetons des
  # comptes deployer et l'adresse des alertes ; chemin donné à
  # tofu init (-backend-config)
  backend "local" {}
}
