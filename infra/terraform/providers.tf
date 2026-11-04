# Fichier  : infra/terraform/providers.tf
# Rôle     : connexion au cluster Minikube (fichier kubeconfig de
#            l'opérateur, contexte orion), pour Kubernetes et pour Helm
# Utilise  : variables.tf
# Utilisé par : toutes les ressources de ce dossier

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

# Même connexion pour Helm (attribut « kubernetes » : la syntaxe 3.x)
provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}
