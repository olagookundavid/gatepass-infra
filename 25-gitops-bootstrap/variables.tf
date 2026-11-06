# Inputs of the GitOps bootstrap layer. The two without a default (allowed_account_id and
# admin_email) are personal values: they go in terraform.tfvars, which is git-ignored (the
# repository is public).
#
# Related files: argocd.tf uses the chart versions; secrets.tf uses secrets_prefix and
# gitops_repo_url; rbac.tf uses admin_email; root.tf uses gitops_repo_url and gitops_revision.

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name; part of every resource name (gatepass-<env>-...)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "allowed_account_id" {
  description = "The only AWS account this layer may be applied to (checked by the provider)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.allowed_account_id))
    error_message = "allowed_account_id must be a 12-digit account id."
  }
}

variable "argocd_chart_version" {
  description = "Version of the argo-cd Helm chart (chart 10.11.6 installs Argo CD v3.5.6). Upgrade on purpose, through a PR, never by leaving it unset."
  type        = string
  default     = "10.11.6"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.argocd_chart_version))
    error_message = "argocd_chart_version must look like 10.11.6."
  }
}

variable "argocd_apps_chart_version" {
  description = "Version of the argocd-apps Helm chart (it renders the bootstrap AppProject and the root Application)."
  type        = string
  default     = "2.0.7"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.argocd_apps_chart_version))
    error_message = "argocd_apps_chart_version must look like 2.0.7."
  }
}

variable "gitops_repo_url" {
  description = "SSH URL of the repository Argo CD syncs. SSH, because Argo CD authenticates with a read-only deploy key."
  type        = string
  default     = "git@github.com:olagookundavid/gatepass-gitops.git"

  validation {
    condition     = can(regex("^git@github\\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\.git$", var.gitops_repo_url))
    error_message = "gitops_repo_url must look like git@github.com:<owner>/<repo>.git."
  }
}

variable "gitops_revision" {
  description = "Branch (or tag) of the gitops repository the root application follows."
  type        = string
  default     = "main"
}

variable "secrets_prefix" {
  description = "Prefix of the three Secrets Manager secrets this layer reads (created by hand, see the walkthrough): <prefix>/gitops-deploy-key, <prefix>/github-oauth (JSON with clientId and clientSecret), <prefix>/slack-webhook-url."
  type        = string
  default     = "gatepass/dev/argocd"
}

variable "admin_email" {
  description = "The primary, verified e-mail of your GitHub account. Argo CD maps the identity GitHub reports (through Dex) to the admin role by this address (rbac.tf)."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.admin_email))
    error_message = "admin_email must be an e-mail address."
  }
}
