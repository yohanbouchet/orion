# Fichier  : infra/terraform/outputs.tf
# Rôle     : valeurs utiles après tofu apply : jetons des comptes
#            deployer (secrets, jamais affichés) et certificat de l'API du
#            cluster (public, mais masqué par le fournisseur avec les
#            données du Secret) ; à ranger dans les environnements GitHub ;
#            certificat public de l'autorité d'OpenBao
# Utilise  : rbac.tf, openbao.tf
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

# Certificat PUBLIC de l'autorité d'OpenBao : à donner aux clients
# (runners de la CI, poste de l'Ops) pour qu'ils vérifient le serveur
output "openbao_ca_cert" {
  description = "Public certificate of the OpenBao CA (clients trust it)"
  value       = tls_self_signed_cert.openbao_ca.cert_pem
}
