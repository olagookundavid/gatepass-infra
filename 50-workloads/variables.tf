# Inputs of the workload-identity layer (rebuilt every day, with the cluster).
# allowed_account_id and domain are personal values (terraform.tfvars, git-ignored).

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

variable "domain" {
  description = "The delegated subdomain (the SES identity of the notifications worker is the domain)."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+[.]){2,}[a-z]{2,}$", var.domain))
    error_message = "domain must look like gatepass.example.com (lower case, no trailing dot, a subdomain)."
  }
}

variable "ses_sandbox_recipient" {
  description = "The verified e-mail address that receives all Gatepass mail while SES is in the sandbox (same value as in 40-data). In the sandbox SES also checks ses:SendEmail against the RECIPIENT identity, so the notifications worker needs it. Empty once SES production access is granted."
  type        = string
  default     = ""
}
