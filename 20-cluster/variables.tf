# Inputs of the cluster layer. The three without a default (allowed_account_id,
# api_allowed_cidrs, admin_principal_arn) are personal values: they go in terraform.tfvars,
# which is git-ignored (the repository is public).
#
# Related files: cluster.tf uses kubernetes_version and api_allowed_cidrs; access.tf uses
# admin_principal_arn; nodes.tf uses the system_* variables; addons.tf uses addon_versions.

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

variable "kubernetes_version" {
  description = "Kubernetes version of the control plane. Keep it inside AWS standard support (past it, extra per-hour charges apply). Start on 1.36; the Phase 11 upgrade drill moves to 1.37."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.36."
  }
}

variable "api_allowed_cidrs" {
  description = "Public IP ranges allowed to reach the Kubernetes API endpoint (your own address as x.x.x.x/32). Never 0.0.0.0/0. Look yours up with: curl -s https://checkip.amazonaws.com"
  type        = list(string)

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "api_allowed_cidrs must be a non-empty list of valid CIDRs and must not contain 0.0.0.0/0."
  }
}

variable "admin_principal_arn" {
  description = "IAM user or role that gets cluster-admin through an EKS access entry (access.tf), for example arn:aws:iam::<account-id>:user/<your-iam-user>."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/.+$", var.admin_principal_arn))
    error_message = "admin_principal_arn must be the ARN of an IAM user or role."
  }
}

variable "log_retention_days" {
  description = "Retention of the control-plane log group, in days. Short on purpose (cost); production keeps 30-90."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a retention value CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, ...)."
  }
}

variable "system_instance_types" {
  description = "EC2 instance types of the system node group (on-demand). m7i-flex.large (2 vCPU, 8 GiB, up to 29 pods) is one of the eight types the account's Free plan allows (aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true); t3.medium is rejected with 'not eligible for Free Tier'. After upgrading the account to a paid plan any type works."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "system_nodes" {
  description = "Size of the system node group. The account's On-Demand vCPU quota is 16 in total; 2 x m7i-flex.large use 4 of them, which leaves the rest for Karpenter's nodes."
  type = object({
    min     = number
    desired = number
    max     = number
  })
  default = {
    min     = 2
    desired = 2
    max     = 3
  }

  validation {
    condition     = var.system_nodes.min >= 1 && var.system_nodes.min <= var.system_nodes.desired && var.system_nodes.desired <= var.system_nodes.max
    error_message = "system_nodes must satisfy 1 <= min <= desired <= max."
  }
}

variable "system_node_disk_gb" {
  description = "Root volume size of each system node in GiB (gp3, encrypted)."
  type        = number
  default     = 30
}

variable "addon_versions" {
  description = "Pinned versions of the managed add-ons (the AWS default for Kubernetes 1.36 on 2026-11-03). Upgrade them on purpose, together with the cluster. List what exists with: aws eks describe-addon-versions --addon-name <name> --kubernetes-version 1.36"
  type        = map(string)
  default = {
    "vpc-cni"                = "v1.22.4-eksbuild.10"
    "kube-proxy"             = "v1.36.0-eksbuild.58"
    "coredns"                = "v1.14.7-eksbuild.22"
    "eks-pod-identity-agent" = "v1.4.1-eksbuild.3"
  }
}
