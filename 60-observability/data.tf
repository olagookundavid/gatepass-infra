# What this layer needs to KNOW about the outside, found by lookup (same reasoning as
# 20-cluster/data.tf: a lookup by name asks AWS for exactly one object and does not give this
# layer access to another layer's state file).
#
# This layer does NOT look up the cluster: it is persistent and must apply when no cluster exists.
#
# Related files: every other .tf file in this layer uses these locals and lookups.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "gatepass-${var.environment}"

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# The environment key created in 00-bootstrap; the log groups are encrypted with it.
data "aws_kms_alias" "env" {
  name = "alias/${local.name_prefix}"
}
