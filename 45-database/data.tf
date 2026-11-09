# Lookups: this layer lives inside the VPC of 10-network and next to the cluster of 20-cluster, found
# by NAME and TAG (never by reading another layer's state). It is applied AFTER the cluster (it
# needs the cluster's security group) and destroyed BEFORE it.
#
# Related files: network.tf (security groups), rds.tf and cache.tf (use the subnets), config.tf.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix  = "gatepass-${var.environment}"
  cluster_name = local.name_prefix
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
}

data "aws_vpc" "main" {
  tags = {
    Name = local.name_prefix
  }
}

# The data tier: subnets with no route to the internet at all (10-network), three zones.
data "aws_subnets" "data" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = {
    Tier = "data"
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

# Pods run on nodes that carry the cluster security group, so "allowed from the cluster security
# group" means "allowed from the pods" (no security groups per pod in this design).
data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

data "aws_kms_alias" "env" {
  name = "alias/${local.name_prefix}"
}

# The S3 gateway endpoint's address list (for the Lambda's outbound rule) and the buckets of 40-data.
data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}

data "aws_s3_bucket" "artifacts" {
  bucket = "${local.name_prefix}-artifacts-${local.account_id}-${var.region}"
}

data "aws_s3_bucket" "reports" {
  bucket = "${local.name_prefix}-reports-${local.account_id}-${var.region}"
}
