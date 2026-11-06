# Everything this layer needs to KNOW about the outside, found by lookup instead of by sharing
# another layer's state file.
#
# WHY LOOKUPS AND NOT terraform_remote_state (what the course did). Reading another layer's
# state gives this layer read access to EVERYTHING in that state file, including any secret
# values, and ties the two layers together through the state's internal layout. A lookup by
# tag asks AWS for exactly the objects we need. The contract is the tag: 10-network sets
# Name = <name_prefix> on the VPC and Tier = private on the subnets (10-network/subnets.tf);
# 00-bootstrap sets the alias alias/<name_prefix> on the key.
#
# If a lookup finds zero or more than one match, Terraform stops with an error rather than
# guessing, which is what we want (for example when 10-network has not been applied yet).
#
# Related files: locals (below) feed names into iam.tf and cluster.tf; cluster.tf uses the
# subnets and the key; iam.tf uses the key ARN for the cluster role's policy.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # Same convention as every layer. The cluster is named exactly name_prefix, and 10-network
  # puts that name into the karpenter.sh/discovery tag of the private subnets.
  name_prefix  = "gatepass-${var.environment}"
  cluster_name = local.name_prefix

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

data "aws_vpc" "main" {
  tags = {
    Name = local.name_prefix
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }

  tags = {
    Tier = "private"
  }
}

# The environment key from 00-bootstrap: used for Kubernetes Secrets (envelope encryption) and
# for the control-plane log group.
data "aws_kms_alias" "env" {
  name = "alias/${local.name_prefix}"
}
