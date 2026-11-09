# Fichier  : infra/terraform/outputs.tf
# Rôle     : valeurs utiles après tofu apply : jetons des comptes
#            deployer (secrets, jamais affichés) et certificat de l'API du
#            cluster (public, mais masqué par le fournisseur avec les
#            données du Secret) ; à ranger dans les environnements GitHub
# Utilise  : rbac.tf
# Utilisé par : l'opérateur (tofu output, voir README)

output "deployer_tokens" {
  description = "Token of each deployer service account, by environment"
  value = {
    for env, s in kubernetes_secret_v1.deployer_token : env => s.data.token
  }
  sensitive = true
}

output "cluster_ca" {
  description = "Certificate of the cluster API, to trust it from the CI"
  value = one(distinct([
    for s in kubernetes_secret_v1.deployer_token : s.data["ca.crt"]
  ]))
  sensitive = true
}
