variable "region" {
  description = "AWS region. us-east-1 keeps CloudFront's ACM certificate in the same region."
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

variable "alert_email" {
  description = "Where budget and cost-anomaly alerts are sent. Set it in terraform.tfvars (not committed)."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must look like an e-mail address."
  }
}

variable "github_owner" {
  description = "GitHub user that owns the capstone repositories (used in the OIDC trust policy)."
  type        = string
  default     = "olagookundavid"
}

variable "github_app_repo" {
  description = "Name of the application repository whose workflows may assume the CI roles."
  type        = string
  default     = "gatepass-app"
}

variable "github_owner_id" {
  description = "Numeric GitHub id of the owner (`gh api users/<owner> --jq .id`). A public fact, not a secret. GitHub puts it into the OIDC subject claim (immutable subject), see github_oidc.tf."
  type        = string
  default     = "63510672"
}

variable "github_app_repo_id" {
  description = "Numeric GitHub id of the application repository (`gh api repos/<owner>/<repo> --jq .id`). A public fact, not a secret. It is part of the OIDC subject claim."
  type        = string
  default     = "1443703488"
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD. Alerts fire at 50% and 80% of actual spend and 100% of forecast."
  type        = number
  default     = 100

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero."
  }
}

variable "anomaly_threshold_usd" {
  description = "Cost Anomaly Detection e-mails when a single anomaly's total impact reaches this many USD."
  type        = number
  default     = 10

  validation {
    condition     = var.anomaly_threshold_usd > 0
    error_message = "anomaly_threshold_usd must be greater than zero."
  }
}
