# Routing: which subnet can reach what. A route table is the only thing that makes a subnet
# "public" or "private": a subnet is public if its table sends 0.0.0.0/0 to the internet
# gateway, private if it sends it to a NAT gateway, and isolated if there is no such route.
#
#   public tables   0.0.0.0/0 -> internet gateway        (one table, shared by the 3 subnets)
#   private tables  0.0.0.0/0 -> NAT gateway             (one table PER ZONE, see below)
#   data table      no default route                     (one table, shared by the 3 subnets)
#
# NAT GATEWAY = outbound-only internet access for private subnets (image pulls from ECR and
# Docker Hub, calls to AWS APIs, GitHub). It sits in a public subnet and has an Elastic IP.
# It costs about $0.045 per hour (~$1.1 a day) plus $0.045 per GB, which is why the nightly
# teardown matters. With var.nat_per_az = false there is ONE NAT (in the first zone) for all
# three private subnets: cheap, but if that zone fails the other two lose internet access, and
# traffic from the other zones crosses zones (extra data charges). Production uses one per
# zone. The private tables are already one per zone, so switching is only the variable.
#
# Related files: subnets.tf (the subnets), vpc.tf (the internet gateway), endpoints.tf (adds
# S3 and DynamoDB routes to the private and data tables so that traffic skips the NAT).

# ---- public ---------------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ---- NAT ------------------------------------------------------------------------------------
resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-${each.key}"
  }

  # An Elastic IP can only be attached to a VPC that has an internet gateway.
  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = {
    Name = "${local.name_prefix}-${each.key}"
  }

  depends_on = [aws_internet_gateway.main]
}

# ---- private --------------------------------------------------------------------------------
resource "aws_route_table" "private" {
  for_each = local.az_index

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[local.nat_for_az[each.key]].id
  }

  tags = {
    Name = "${local.name_prefix}-private-${each.key}"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ---- data (isolated) ------------------------------------------------------------------------
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  # No route blocks: only the implicit VPC-local route. A database in these subnets can talk to
  # the nodes in the same VPC and to the gateway endpoints, and to nothing else.

  tags = {
    Name = "${local.name_prefix}-data"
  }
}

resource "aws_route_table_association" "data" {
  for_each = aws_subnet.data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}
