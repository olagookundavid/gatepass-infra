data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # Naming convention (docs/CONVENTIONS.md): gatepass-<env>-<thing>
  name_prefix = "gatepass-${var.environment}"

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}
