# Fichier  : infra/openbao/config/providers.tf
# Rôle     : connexion à OpenBao : par kubectl port-forward (poste de
#            l'Ops), en HTTPS vérifié avec le certificat de son autorité
# Utilise  : variables.tf ; jeton lu dans la variable d'environnement
#            VAULT_TOKEN (jamais écrit dans un fichier)
# Utilisé par : tofu plan / apply (ce dossier)

provider "vault" {
  address      = var.openbao_addr
  ca_cert_file = var.openbao_ca_file
  # Le fournisseur travaille avec un jeton enfant de 20 min, créé à
  # partir de celui de l'Ops, puis révoqué : jamais le jeton lui-même
  skip_child_token = false
}
