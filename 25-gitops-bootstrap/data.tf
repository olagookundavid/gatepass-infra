# What this layer needs to KNOW about the outside, found by lookup (same reasoning as
# 20-cluster/data.tf: no terraform_remote_state, the contract is the name).
#
# 20-cluster names the cluster exactly gatepass-<environment>; this layer asks AWS for it by
# that name. If the cluster does not exist (it was torn down tonight), the lookup fails with
# "not found" instead of Terraform guessing.
#
# Related files: providers.tf builds the kubernetes and helm connections from this lookup.

locals {
  name_prefix  = "gatepass-${var.environment}"
  cluster_name = local.name_prefix
}

data "aws_eks_cluster" "main" {
  name = local.cluster_name
}
