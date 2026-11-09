# Inputs of the persistent data layer. allowed_account_id, domain and the e-mail address are personal
# values (terraform.tfvars, git-ignored, because the repository is public).
#
# Related files: every other .tf file of the layer reads these.

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
  description = "The delegated subdomain served by the Route 53 zone of 05-dns (for example gatepass.example.com). The CDN, the e-mail identity and the Cognito callbacks are built from it. Personal value (terraform.tfvars)."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+[.]){2,}[a-z]{2,}$", var.domain))
    error_message = "domain must look like gatepass.example.com (lower case, no trailing dot, a subdomain)."
  }
}

variable "ses_sandbox_recipient" {
  description = "An e-mail address that receives all Gatepass mail while the SES account is in the sandbox (EMAIL_RECIPIENT_OVERRIDE). It is registered as an SES identity; AWS sends it a verification mail that must be clicked once."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.ses_sandbox_recipient))
    error_message = "ses_sandbox_recipient must look like an e-mail address."
  }
}

variable "lambda_dist_dir" {
  description = "Directory with the Lambda zips built by `make lambda-zip` in gatepass-app (dist/). Terraform uploads the zip of hold-expirer to the artifacts bucket. A dev shortcut: production builds, signs and uploads the zip in the release pipeline and Terraform only references the object."
  type        = string
  default     = "../../gatepass-app/dist"
}

variable "log_retention_days" {
  description = "Retention of the Lambda log group (a log group without retention is never deleted and keeps costing)."
  type        = number
  default     = 14
}

variable "hold_ttl_minutes" {
  description = "The advertised length of a ticket hold. Documented here for the walkthrough; the service reads HOLD_TTL itself (default 10m)."
  type        = number
  default     = 10
}
