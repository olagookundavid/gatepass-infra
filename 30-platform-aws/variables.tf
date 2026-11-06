# Inputs of the platform AWS layer. Only allowed_account_id has no default (a personal value:
# terraform.tfvars, git-ignored, because the repository is public).
#
# Related files: external-secrets.tf uses eso_secret_prefix; ebs-csi.tf uses
# ebs_csi_addon_version; waf.tf uses waf_rate_limit.

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

variable "eso_secret_prefix" {
  description = "Secrets Manager name prefix the External Secrets Operator may read (everything under <prefix>/). The Argo CD secrets live under gatepass/<env>/argocd and are deliberately NOT inside this prefix."
  type        = string
  default     = "gatepass/dev/app"

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]+$", var.eso_secret_prefix)) && !endswith(var.eso_secret_prefix, "/")
    error_message = "eso_secret_prefix must be a Secrets Manager name prefix without a trailing slash."
  }
}

variable "ebs_csi_addon_version" {
  description = "Pinned version of the aws-ebs-csi-driver managed add-on (the AWS default for Kubernetes 1.36 on 2026-11-05). List what exists with: aws eks describe-addon-versions --addon-name aws-ebs-csi-driver --kubernetes-version 1.36"
  type        = string
  default     = "v1.67.2-eksbuild.1"
}

variable "waf_rate_limit" {
  description = "Requests allowed per client IP in any 5-minute window before the WAF blocks that IP (AWS minimum is 10). 1000 is generous for a dev environment and low enough to see the rule work with a simple loop."
  type        = number
  default     = 1000

  validation {
    condition     = var.waf_rate_limit >= 10 && var.waf_rate_limit <= 20000000
    error_message = "waf_rate_limit must be between 10 and 20000000."
  }
}
