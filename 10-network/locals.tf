# Facts computed once: names, and THE ADDRESS PLAN (which CIDR each subnet gets).
#
# The plan, for the default 10.20.0.0/16 (every tier has one subnet per availability zone):
#
#   tier      size  third octet           purpose
#   public    /24   10.20.0-2.0           load balancers (ALB) and the NAT gateway only
#   private   /20   10.20.16, .32, .48    nodes AND pods (4,096 addresses per zone)
#   data      /24   10.20.100-102.0       RDS and ElastiCache later; NO route to the internet
#
# Why the private tier is large: with the VPC CNI every pod gets a real VPC address, so
# a busy node can use dozens. Public subnets hold only a few load balancer interfaces, so /24
# is plenty. Leaving gaps between the tiers keeps room for a fourth tier without renumbering.
#
# Related files: subnets.tf creates the subnets from these lists; the cluster layer finds them
# again by the tags set there (it does not read this layer's state).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # Naming convention: gatepass-<env>-<thing>. The EKS cluster is named exactly name_prefix
  # (20-cluster/locals.tf), and the private subnets carry that name in the Karpenter
  # discovery tag, so the two layers agree without sharing state.
  name_prefix  = "gatepass-${var.environment}"
  cluster_name = local.name_prefix

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # { "us-east-1a" = 0, "us-east-1b" = 1, ... }. Resources are keyed by zone NAME, not by
  # list position, so reordering var.azs does not make Terraform replace everything.
  az_index = { for i, az in var.azs : az => i }

  public_cidrs  = { for az, i in local.az_index : az => cidrsubnet(var.vpc_cidr, 8, i) }
  private_cidrs = { for az, i in local.az_index : az => cidrsubnet(var.vpc_cidr, 4, i + 1) }
  data_cidrs    = { for az, i in local.az_index : az => cidrsubnet(var.vpc_cidr, 8, i + 100) }

  # The zones that get a NAT gateway: all three, or only the first.
  nat_azs = var.nat_per_az ? var.azs : [var.azs[0]]
  # Which NAT serves the private subnet of each zone (its own, or the single shared one).
  nat_for_az = { for az in var.azs : az => var.nat_per_az ? az : var.azs[0] }
}
