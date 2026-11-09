# AWS provider.
#
# allowed_account_ids is a safety net: if your CLI points at the wrong account (an old profile,
# another project), `terraform plan` stops immediately instead of creating resources there.
#
# default_tags puts the same five tags on every taggable resource this layer creates (plan
# section 5). Cost Explorer can then group the bill by tag (activate the tags in the Billing
# console under "Cost allocation tags" once, they are not active by default).
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.allowed_account_id]

  default_tags {
    tags = {
      Project     = "gatepass"
      Environment = var.environment
      Owner       = "davidoh"
      ManagedBy   = "terraform"
      CostCenter  = "learning"
    }
  }
}
