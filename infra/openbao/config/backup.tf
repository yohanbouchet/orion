# Fichier  : infra/openbao/config/backup.tf
# Rôle     : droit de sauvegarde du coffre, et rien d'autre : la tâche
#            planifiée du poste Ops prend chaque jour un instantané Raft
#            (scripts/backup-openbao.sh) avec un jeton qui ne peut que ça
# Utilise  : moteur de jetons intégré à OpenBao (auth/token)
# Utilisé par : scripts/backup-openbao.sh ; rôle Ansible backup (tâche
#               planifiée) ; recommandation 26 du rapport
# Le JETON n'est jamais créé par OpenTofu (sa valeur finirait dans
# l'état) : l'Ops le fabrique à partir du rôle ci-dessous (README
# d'OpenBao, « Sauvegarde planifiée »)

# Lecture de l'instantané seulement : ni lecture des secrets, ni
# restauration, ni changement de configuration ; l'instantané reste
# chiffré par le coffre (illisible sans les clés de déverrouillage)
resource "vault_policy" "openbao_backup" {
  name   = "openbao-backup"
  policy = <<-EOT
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
  EOT
}

# Modèle du jeton de sauvegarde : règle openbao-backup seule, plus la
# règle « default » (le jeton peut se prolonger lui-même) ; orphelin
# (il ne disparaît pas si le jeton racine est révoqué) ; périodique :
# chaque sauvegarde le prolonge de 7 jours, il expire seul après 7 jours
# sans sauvegarde (poste éteint longtemps, tâche arrêtée)
resource "vault_token_auth_backend_role" "openbao_backup" {
  role_name               = "openbao-backup"
  allowed_policies        = [vault_policy.openbao_backup.name]
  disallowed_policies     = ["root"]
  orphan                  = true
  renewable               = true
  token_period            = var.backup_token_period
  token_no_default_policy = false
  token_type              = "service"
}
