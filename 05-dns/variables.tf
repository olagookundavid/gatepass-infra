# Inputs of the DNS layer. allowed_account_id and domain are personal values (terraform.tfvars,
# git-ignored, because the repository is public and does not publish the domain).
#
# Related files: zone.tf and certificate.tf use domain; certificate.tf uses delegation_confirmed.

variable "region" {
  description = "AWS region. Must stay us-east-1: CloudFront only accepts certificates from this region (Phase 7) and the load balancer is in the same region."
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
  description = "The delegated subdomain that Route 53 serves, for example gatepass.example.com. Lower case, no trailing dot, at least three labels (so it is a SUBdomain of a domain that lives elsewhere, Cloudflare in our case)."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+[.]){2,}[a-z]{2,}$", var.domain))
    error_message = "domain must look like gatepass.example.com (lower case, no trailing dot, a subdomain)."
  }
}

variable "delegation_confirmed" {
  description = "false: create the zone, request the certificate and write its validation records. true: also wait for the certificate to be issued, which only works after the NS records for the subdomain exist in the parent zone (Cloudflare)."
  type        = bool
  default     = false
}
