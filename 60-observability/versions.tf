# Version constraints (plan rule 5: pin everything, upgrade on purpose through a PR).
#
# required_version "~> 1.16.0" means "1.16.x only": a new Terraform minor version is a
# deliberate change, not something that happens when a teammate updates their laptop.
#
# The provider is constrained to one minor series; the exact version that was tested is
# recorded in .terraform.lock.hcl, which IS committed (it also stores package checksums, so
# a tampered provider build is rejected).
terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71.0"
    }
  }
}
