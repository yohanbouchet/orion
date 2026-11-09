# Fichier  : infra/terraform/monitoring.tf
# Rôle     : supervision du cluster : 2 namespaces, la pile
#            VictoriaMetrics + VictoriaLogs + Grafana (chart Helm) et nos
#            tableaux de bord
# Utilise  : variables.tf (ops_email) ; infra/monitoring/ (réglages,
#            alertes, pare-feu, tableaux de bord)
# Utilisé par : tofu apply (l'Ops) ; ticket #83

locals {
  monitoring_dir = "${path.module}/../monitoring"
}

# Métriques, journaux, alertes, Grafana : niveau « restricted », comme
# l'application
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "app.kubernetes.io/part-of"                  = "monitoring"
      "app.kubernetes.io/managed-by"               = "opentofu"
    }
  }
}

# Collecteur de journaux SEUL : il lit les fichiers de l'hôte
# (/var/log/pods), refusé ailleurs ; « privileged » l'autorise sans
# rien donner : le pod lui-même est verrouillé (values.yaml.tftpl)
resource "kubernetes_namespace_v1" "monitoring_collector" {
  metadata {
    name = "monitoring-collector"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      # Avertit de tout écart à « restricted » (message dans kubectl, Helm)
      "pod-security.kubernetes.io/warn"         = "restricted"
      "pod-security.kubernetes.io/warn-version" = "latest"
      "app.kubernetes.io/part-of"               = "monitoring"
      "app.kubernetes.io/managed-by"            = "opentofu"
    }
  }
}

# La pile, à une version figée du chart ; l'adresse e-mail des alertes
# est insérée ici, jamais écrite dans le dépôt
resource "helm_release" "monitoring" {
  name       = "vm"
  repository = "https://victoriametrics.github.io/helm-charts/"
  chart      = "victoria-metrics-k8s-stack"
  version    = "0.97.1"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [
    templatefile("${local.monitoring_dir}/values.yaml.tftpl", {
      ops_email = var.ops_email
    }),
    file("${local.monitoring_dir}/extras.yaml"),
  ]

  # Attend que les pods du chart soient prêts ; en cas d'échec d'une
  # mise à jour, retire ce qu'elle a créé
  wait            = true
  timeout         = 600
  cleanup_on_fail = true
  max_history     = 5

  # Le collecteur s'installe dans son propre namespace
  depends_on = [kubernetes_namespace_v1.monitoring_collector]
}

# Nos tableaux de bord : un ConfigMap par fichier JSON, chargé par
# Grafana (étiquette grafana_dashboard=1, lue par son sidecar)
resource "kubernetes_config_map_v1" "dashboard" {
  for_each = fileset("${local.monitoring_dir}/dashboards", "*.json")

  metadata {
    name      = "dashboard-${trimsuffix(each.key, ".json")}"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels = {
      grafana_dashboard              = "1"
      "app.kubernetes.io/part-of"    = "monitoring"
      "app.kubernetes.io/managed-by" = "opentofu"
    }
  }
  data = {
    (each.key) = file("${local.monitoring_dir}/dashboards/${each.key}")
  }
}
