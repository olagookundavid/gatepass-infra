# Inputs of the network layer. Only values that someone may reasonably want to change are
# variables; everything else is decided in locals.tf or in the resource itself.
#
# Related files: locals.tf turns vpc_cidr and azs into the subnet plan; routing.tf reads
# nat_per_az; flowlogs.tf reads flow_logs_retention_days.

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

variable "vpc_cidr" {
  description = "CIDR of the VPC. Must be a /16: locals.tf cuts it into /24 and /20 subnets. 10.20.0.0/16 avoids the very common 10.0.0.0/16 (a clash breaks peering later) and the default VPC's 172.31.0.0/16."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && can(regex("/16$", var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a /16 prefix."
  }
}

variable "azs" {
  description = "The three availability zones to use, pinned (not 'the first three available') so that a change in the AWS zone list can never re-create subnets."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.azs) == 3 && length(distinct(var.azs)) == 3
    error_message = "azs must list exactly three different availability zones."
  }
}

variable "nat_per_az" {
  description = "false = one NAT gateway for the whole VPC (cheap, dev); true = one per AZ (production: an AZ outage does not cut the other zones' internet access)."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "How long VPC flow logs are kept in CloudWatch Logs. Short on purpose: they cost money to store and are only needed for troubleshooting."
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days must be a retention value CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, ...)."
  }
}
