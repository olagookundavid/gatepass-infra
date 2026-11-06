# THE THREE SECRETS ARGO CD NEEDS, moved from AWS Secrets Manager into Kubernetes WITHOUT the
# values ever touching the Terraform state.
#
# The problem. A normal `kubernetes_secret_v1 { data = {...} }` writes the secret into the state
# file in clear text, and the state would then be one more place a secret leaks from. Two
# Terraform features avoid that:
#   * an EPHEMERAL resource (`ephemeral "aws_secretsmanager_secret_version"`) reads the secret
#     while Terraform runs and forgets it: it is never written to the plan or the state;
#   * a WRITE-ONLY argument (`data_wo`) sends a value to the provider on create/update and
#     does not store it in the state. Terraform cannot see whether it changed, so the number
#     `data_wo_revision` tells it: raise it to push a new value (after rotating the secret).
# `data` and `data_wo` cannot be combined on one Secret, so every key of these Secrets goes in `data_wo`.
#
# WHERE THE VALUES COME FROM. You put them into Secrets Manager by hand, once (walkthrough 03,
# step B), because the people who hold them (GitHub, Slack) hand them to a human. The three
# secrets live OUTSIDE this layer on purpose: this layer is destroyed every evening, secrets
# must not be. Phase 3 (External Secrets Operator) and Phase 7 move their management into
# Terraform and the cluster; until then this file is the bridge.
#
#   <prefix>/gitops-deploy-key   the private half of a read-only GitHub deploy key (repo credential)
#   <prefix>/github-oauth        JSON {"clientId": "...", "clientSecret": "..."} of the GitHub OAuth app (SSO)
#   <prefix>/slack-webhook-url   the Slack incoming-webhook URL (notifications)
#
# HOW ARGO CD FINDS EACH ONE
#   repository secret      any Secret in the argocd namespace labelled
#                          argocd.argoproj.io/secret-type=repository is a repository
#                          definition; the URL tells which repo it is for.
#   argocd-dex-github      Argo CD's config may refer to "$<secret>:<key>" instead of a literal,
#                          for any Secret labelled app.kubernetes.io/part-of=argocd. The Dex
#                          connector in the (Git-held) values uses it: no secret in Git.
#   argocd-notifications-secret
#                          fixed name read by the notifications controller; "$slack-webhook-url"
#                          in the notifier config means "the key slack-webhook-url of it". The
#                          chart is told NOT to create its own (argocd-bootstrap-values.yaml).
#
# Related files: namespace.tf (where they go), argocd.tf (starts after them),
# argocd-bootstrap-values.yaml (notifications.secret.create = false).

ephemeral "aws_secretsmanager_secret_version" "deploy_key" {
  secret_id = "${var.secrets_prefix}/gitops-deploy-key"
}

ephemeral "aws_secretsmanager_secret_version" "github_oauth" {
  secret_id = "${var.secrets_prefix}/github-oauth"
}

ephemeral "aws_secretsmanager_secret_version" "slack_webhook" {
  secret_id = "${var.secrets_prefix}/slack-webhook-url"
}

locals {
  github_oauth = jsondecode(ephemeral.aws_secretsmanager_secret_version.github_oauth.secret_string)
}

resource "kubernetes_secret_v1" "gitops_repo" {
  metadata {
    name      = "gatepass-gitops-repo"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name

    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  # `data` and `data_wo` cannot be used on the same Secret (the provider rejects it,
  # "data_wo conflicts with data", found 2026-11-06), so the non-secret type and url ride in
  # data_wo too. They are not secret; they just are not in the state either.
  data_wo = {
    type          = "git"
    url           = var.gitops_repo_url
    sshPrivateKey = ephemeral.aws_secretsmanager_secret_version.deploy_key.secret_string
  }
  data_wo_revision = 1
}

resource "kubernetes_secret_v1" "dex_github" {
  metadata {
    name      = "argocd-dex-github"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name

    labels = {
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data_wo = {
    "dex.github.clientID"     = local.github_oauth["clientId"]
    "dex.github.clientSecret" = local.github_oauth["clientSecret"]
  }
  data_wo_revision = 1
}

resource "kubernetes_secret_v1" "notifications" {
  metadata {
    name      = "argocd-notifications-secret"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  data_wo = {
    "slack-webhook-url" = ephemeral.aws_secretsmanager_secret_version.slack_webhook.secret_string
  }
  data_wo_revision = 1
}
