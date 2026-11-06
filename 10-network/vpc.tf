# The VPC itself: our own private network, plus the lock-down of AWS's "default" objects.
#
# WHY A NEW VPC. Every account already has a "default VPC" (172.31.0.0/16) whose subnets are
# all public and open by default. We do not use it: it is not in code and anything launched
# into it by mistake is reachable from the internet. Everything in Gatepass lives in this VPC.
#
# HOW IT RELATES TO THE OTHER FILES
#   * subnets.tf cuts this VPC into subnets; routing.tf decides which of them reach the internet.
#   * The internet gateway below is the VPC's door to the internet. Only the public route table
#     (routing.tf) points at it, so only public subnets can be reached from outside.
#   * 20-cluster finds this VPC again by its Name tag (== local.name_prefix); it does not read
#     this layer's state file.
#
# DNS settings: both must be on. enable_dns_support lets instances resolve names (including
# the cluster's private endpoint name); enable_dns_hostnames gives them DNS names, which EKS
# and the private-endpoint feature require.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.name_prefix
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = local.name_prefix
  }
}

# FAIL CLOSED. AWS creates a default security group and a main route table for every VPC, and
# anything that is not given an explicit one silently falls back to them. Taking ownership of
# them with NO rules means a forgotten association or a resource launched without a security
# group has no network access at all, instead of the default group's "everything inside the VPC
# can talk to everything" or a route to the internet. (Production baseline; the course left
# both untouched.)
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

  # No ingress and no egress blocks = no rules.
  tags = {
    Name = "${local.name_prefix}-default-unused"
  }
}

resource "aws_default_route_table" "main" {
  default_route_table_id = aws_vpc.main.default_route_table_id

  # The VPC-local route is implicit and always present. route = [] says "nothing else".
  route = []

  tags = {
    Name = "${local.name_prefix}-main-unused"
  }
}
