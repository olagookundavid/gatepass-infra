# WHO MAY DO WHAT INSIDE ARGO CD: the argocd-rbac-cm ConfigMap.
#
# Argo CD has its own permission system, separate from Kubernetes RBAC and from AWS IAM:
# "may this person sync application X?". The rules live in this ConfigMap.
#
#   policy.default = ""        a person who logs in but matches no rule can do NOTHING (not even
#                              read). Argo CD's chart default is read-only for everyone, which
#                              is wrong for an SSO that lets any GitHub user reach the login.
#   scopes = [email]           Argo CD reads the user's e-mail claim (from Dex/GitHub) and
#                              matches it against the rules below.
#   g, <email>, role:admin     "the person with this e-mail is an administrator". `g` is a
#                              group-membership line; role:admin is built into Argo CD.
#
# WHY HERE AND NOT IN THE VALUES IN GIT. The e-mail is personal: the gitops repository is
# public. So the chart is told not to create this ConfigMap (rbac.create = false in
# argocd-bootstrap-values.yaml and in the Git values), and Terraform owns it with the address
# from terraform.tfvars. In a team, rules refer to GitHub teams (groups) and live in Git.
#
# The local `admin` user is disabled in the config (argocd-cm); this is the only way in besides
# kubectl (and `argocd --core`, which talks straight to the Kubernetes API with your access
# entry and needs no Argo CD login).
#
# Related files: argocd-bootstrap-values.yaml (rbac.create = false), variables.tf (admin_email).

resource "kubernetes_config_map_v1" "rbac" {
  metadata {
    name      = "argocd-rbac-cm"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name

    labels = {
      "app.kubernetes.io/name"    = "argocd-rbac-cm"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data = {
    "policy.default" = ""
    "scopes"         = "[email]"
    "policy.csv"     = "g, ${var.admin_email}, role:admin\n"
  }
}
