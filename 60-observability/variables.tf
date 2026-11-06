# Inputs of the observability layer. allowed_account_id and alert_email are personal values
# (terraform.tfvars, git-ignored, because the repository is public).
#
# Related files: logs.tf uses the retention variables, alerts.tf uses alert_email, xray.tf uses
# trace_sampling_rate.

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

variable "alert_email" {
  description = "E-mail address subscribed to the alerts topic. AWS sends a confirmation message that must be clicked once per subscription."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must look like an e-mail address."
  }
}

variable "application_log_retention_days" {
  description = "Retention of the application log group (days). Must be a value CloudWatch accepts."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.application_log_retention_days)
    error_message = "application_log_retention_days must be a retention value CloudWatch supports (for example 7, 14, 30, 90)."
  }
}

variable "trace_sampling_rate" {
  description = "Fraction of requests X-Ray records beyond the reservoir (0 to 1). Dev records everything; production samples (5% is typical)."
  type        = number
  default     = 1

  validation {
    condition     = var.trace_sampling_rate >= 0 && var.trace_sampling_rate <= 1
    error_message = "trace_sampling_rate must be between 0 and 1."
  }
}

variable "otel_namespace" {
  description = "Kubernetes namespace of the collectors and Grafana (gatepass-gitops creates it)."
  type        = string
  default     = "observability"
}
