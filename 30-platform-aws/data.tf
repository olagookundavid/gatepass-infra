# Everything this layer needs to KNOW about the outside, found by lookup (same reasoning as
# 20-cluster/data.tf: a lookup by name asks AWS for exactly one object and does not give this
# layer access to another layer's state file).
#
# The contract is the cluster NAME: 20-cluster names the cluster exactly name_prefix. If the
# cluster does not exist (make down, or 20-cluster not applied yet) this layer fails at plan
# time with "no matching EKS Cluster", which is the right behaviour: Pod Identity associations
# and the node access entry cannot exist without a cluster.
#
# Related files: every other .tf file in this layer uses these locals.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix  = "gatepass-${var.environment}"
  cluster_name = local.name_prefix

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

data "aws_eks_cluster" "main" {
  name = local.cluster_name
}
