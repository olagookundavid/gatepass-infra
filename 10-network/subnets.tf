# The nine subnets: three tiers x three availability zones. A subnet lives in exactly one zone,
# so three zones means the platform survives the loss of one.
#
# WHY THREE TIERS (the CIDR plan is in locals.tf)
#   public   holds only what must be reachable from the internet: the load balancers and the NAT
#            gateway. Nothing we run (no node, no pod, no database) is placed here.
#   private  nodes and pods. They can reach the internet (through NAT) but the internet cannot
#            start a connection to them, so a security-group mistake cannot expose them.
#   data     RDS and ElastiCache (Phase 7). Their route table has no internet route at all.
#
# THE TAGS ARE PART OF THE CONTRACT with other layers and with Kubernetes controllers:
#   Tier                              how 20-cluster finds the private subnets (tag lookup,
#                                     not remote state: loose coupling between layers)
#   kubernetes.io/role/elb            the AWS Load Balancer Controller (Phase 3) puts
#                                     internet-facing ALBs in subnets with this tag
#   kubernetes.io/role/internal-elb   ... and internal load balancers in subnets with this one
#   karpenter.sh/discovery            Karpenter (Phase 3) launches nodes only into subnets with
#                                     this tag = the cluster name (set on the private tier only)
# The tags live HERE, in the layer that owns the subnets. (The course added them from the
# cluster layer with aws_ec2_tag, which makes two layers fight over one resource.)
#
# map_public_ip_on_launch is false everywhere: a resource that needs a public address (the NAT
# gateway) gets an Elastic IP explicitly (routing.tf); nothing receives one by accident.

resource "aws_subnet" "public" {
  for_each = local.az_index

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = local.public_cidrs[each.key]
  map_public_ip_on_launch = false

  tags = {
    Name                     = "${local.name_prefix}-public-${each.key}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each = local.az_index

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = local.private_cidrs[each.key]
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${local.name_prefix}-private-${each.key}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = local.cluster_name
  }
}

resource "aws_subnet" "data" {
  for_each = local.az_index

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = local.data_cidrs[each.key]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-data-${each.key}"
    Tier = "data"
  }
}
