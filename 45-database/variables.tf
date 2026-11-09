# Inputs of the database layer (rebuilt every day). allowed_account_id is a personal value
# (terraform.tfvars, git-ignored, because the repository is public).
#
# Related files: rds.tf and cache.tf use the sizing variables, report.tf uses lambda_dist_dir.

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

variable "db_instance_class" {
  description = "RDS instance class. db.t4g.micro (2 vCPU burstable Graviton, 1 GiB) is enough for the capstone and the cheapest class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  description = "Size of the database volume (gp3). 20 GiB is the smallest gp3 size."
  type        = number
  default     = 20
}

variable "postgres_major_version" {
  description = "PostgreSQL major version. RDS picks the newest minor release on creation and applies later minor releases itself (auto_minor_version_upgrade). 17 is in standard support for years."
  type        = string
  default     = "17"
}

variable "cache_max_storage_gb" {
  description = "Upper limit of data the serverless cache may hold (it also caps the cost)."
  type        = number
  default     = 1
}

variable "cache_max_ecpu_per_second" {
  description = "Upper limit of compute (ElastiCache Processing Units per second) the serverless cache may use (it caps the cost)."
  type        = number
  default     = 2000
}

variable "lambda_dist_dir" {
  description = "Directory with the Lambda zips built by `make lambda-zip` in gatepass-app (dist/). A dev shortcut, see 40-data/lambda.tf."
  type        = string
  default     = "../../gatepass-app/dist"
}

variable "log_retention_days" {
  description = "Retention of the Lambda log group."
  type        = number
  default     = 14
}
