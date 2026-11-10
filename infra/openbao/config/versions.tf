# Fichier  : infra/openbao/config/versions.tf
# Rôle     : versions exigées d'OpenTofu et du fournisseur Vault (parle
#            aussi à OpenBao, qui garde la même API) ; état local, hors
#            du dépôt, séparé de celui du socle
# Utilise  : rien
# Utilisé par : tofu init (ce dossier) ; job opentofu de la CI

terraform {
  required_version = ">= 1.13.0, < 2.0.0"

  required_providers {
    # 5.13 = dernière version (14/10/2026), vérifiée le 10/11/2026 sur
    # registry.opentofu.org ; licence MPL-2.0 ; montée par une PR
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13.0"
    }
  }

  # État à part (~/.local/state/orion-openbao) : un plan du socle
  # (infra/terraform) n'a pas besoin du coffre ouvert ; chemin donné à
  # tofu init (-backend-config)
  backend "local" {}
}
