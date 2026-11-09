# Fichier  : infra/terraform/openbao.tf
# Rôle     : coffre-fort de secrets OpenBao : namespace, certificat TLS
#            (autorité de certification propre au cluster) et chart Helm
# Utilise  : infra/openbao/values.yaml (réglages du chart)
# Utilisé par : tofu apply (l'Ops) ; initialisation et déverrouillage :
#               infra/openbao/README.md

locals {
  openbao_dir = "${path.module}/../openbao"
  # Noms sous lesquels OpenBao est joint : Service (CI), nom du pod
  # (stockage Raft), localhost (port-forward de l'Ops)
  openbao_dns_names = [
    "openbao",
    "openbao.openbao",
    "openbao.openbao.svc",
    "openbao.openbao.svc.cluster.local",
    "openbao-0.openbao-internal",
    "openbao-0.openbao-internal.openbao.svc.cluster.local",
    "localhost",
  ]
}

# Niveau « restricted », comme l'application
resource "kubernetes_namespace_v1" "openbao" {
  metadata {
    name = "openbao"
    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "app.kubernetes.io/part-of"                  = "openbao"
      "app.kubernetes.io/managed-by"               = "opentofu"
    }
  }
}

# --- Certificat TLS ----------------------------------------------------
# Autorité de certification propre au cluster (aucune autorité publique
# ne signe un nom en .svc) : clés ECDSA P-256 ; clés privées seulement
# dans l'état (hors du dépôt, 600) et dans le Secret
resource "tls_private_key" "openbao_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "openbao_ca" {
  private_key_pem   = tls_private_key.openbao_ca.private_key_pem
  is_ca_certificate = true
  subject {
    common_name  = "Orion OpenBao CA"
    organization = "Orion"
  }
  # 1 an ; tofu plan propose de le renouveler 30 jours avant la fin
  validity_period_hours = 8760
  early_renewal_hours   = 720
  allowed_uses          = ["cert_signing", "crl_signing"]
}

resource "tls_private_key" "openbao" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "openbao" {
  private_key_pem = tls_private_key.openbao.private_key_pem
  subject {
    common_name  = "openbao.openbao.svc"
    organization = "Orion"
  }
  dns_names    = local.openbao_dns_names
  ip_addresses = ["127.0.0.1"]
}

resource "tls_locally_signed_cert" "openbao" {
  cert_request_pem   = tls_cert_request.openbao.cert_request_pem
  ca_private_key_pem = tls_private_key.openbao_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.openbao_ca.cert_pem
  # Même durée ; après un renouvellement, redémarrer le pod (README)
  validity_period_hours = 8760
  early_renewal_hours   = 720
  allowed_uses          = ["digital_signature", "server_auth"]
}

# Lu par le pod (volume en lecture seule, values.yaml)
resource "kubernetes_secret_v1" "openbao_tls" {
  metadata {
    name      = "openbao-tls"
    namespace = kubernetes_namespace_v1.openbao.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of"    = "openbao"
      "app.kubernetes.io/managed-by" = "opentofu"
    }
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_locally_signed_cert.openbao.cert_pem
    "tls.key" = tls_private_key.openbao.private_key_pem
    "ca.crt"  = tls_self_signed_cert.openbao_ca.cert_pem
  }
}

# --- Le coffre-fort ----------------------------------------------------
resource "helm_release" "openbao" {
  name       = "openbao"
  repository = "https://openbao.github.io/openbao-helm"
  chart      = "openbao"
  # Dernière version (06/11/2026, OpenBao 2.7.2) ; montée par une PR
  version   = "0.30.7"
  namespace = kubernetes_namespace_v1.openbao.metadata[0].name

  values = [file("${local.openbao_dir}/values.yaml")]

  # Pas d'attente : un OpenBao neuf, ou redémarré, reste « scellé » (non
  # prêt) tant que l'Ops ne l'a pas déverrouillé avec ses clés
  wait        = false
  max_history = 5

  depends_on = [kubernetes_secret_v1.openbao_tls]
}
