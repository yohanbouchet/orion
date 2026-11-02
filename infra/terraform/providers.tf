# Fichier  : infra/terraform/providers.tf
# Rôle     : connexion au cluster Minikube (fichier kubeconfig de
#            l'opérateur, contexte orion)
# Utilise  : variables.tf
# Utilisé par : toutes les ressources de ce dossier

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}
