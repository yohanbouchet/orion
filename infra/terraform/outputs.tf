# Fichier  : infra/terraform/outputs.tf
# Rôle     : valeurs PUBLIQUES utiles après tofu apply : certificat de
#            l'API du cluster et certificat de l'autorité d'OpenBao, à
#            ranger dans les variables de dépôt GitHub (KUBE_CA,
#            OPENBAO_CA) ; plus aucun jeton (OpenBao les délivre)
# Utilise  : openbao.tf ; ConfigMap kube-root-ca.crt (publiée par
#            Kubernetes dans chaque namespace)
# Utilisé par : l'opérateur (tofu output, voir README)

# Certificat public de l'autorité du cluster, lu dans la ConfigMap que
# Kubernetes publie dans chaque namespace
data "kubernetes_config_map_v1" "cluster_ca" {
  metadata {
    name      = "kube-root-ca.crt"
    namespace = kubernetes_namespace_v1.env["dev"].metadata[0].name
  }
}

output "cluster_ca" {
  description = "Public certificate of the cluster API (CI trusts it)"
  value       = data.kubernetes_config_map_v1.cluster_ca.data["ca.crt"]
}

# Certificat PUBLIC de l'autorité d'OpenBao : à donner aux clients
# (runners de la CI, poste de l'Ops) pour qu'ils vérifient le serveur
output "openbao_ca_cert" {
  description = "Public certificate of the OpenBao CA (clients trust it)"
  value       = tls_self_signed_cert.openbao_ca.cert_pem
}
