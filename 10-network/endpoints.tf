# VPC gateway endpoints for S3 and DynamoDB: a private path to two AWS services, FREE.
#
# WHY. Without them, a pod that reads from S3 or DynamoDB sends that traffic through the NAT
# gateway, which bills $0.045 per GB, and over the public internet. A gateway endpoint adds a
# route to the route table that sends the traffic straight to the service inside the AWS
# network: no NAT, no data charge, and it never leaves AWS. Image layers from ECR are stored in
# S3, so this also makes image pulls cheaper.
#
# These two are the only "gateway" type endpoints that exist. Everything else (ECR API, STS,
# Secrets Manager, CloudWatch Logs, SQS) would need an "interface" endpoint: a network
# interface per zone that costs about $0.01 per hour EACH ($0.22 a day per service in three
# zones), which is more than the NAT traffic it would save at our volume. We decide that in
# Phase 3/7 with real numbers (plan "Beyond the course": interface endpoints vs NAT cost).
#
# They are attached to the private and data route tables, not the public one. The default
# endpoint policy allows everything; production writes a policy that only allows our buckets
# (and the AWS-owned buckets ECR and the nodes need).
#
# Related files: routing.tf (the route tables these routes are added to).

locals {
  endpoint_route_table_ids = concat(
    [for rt in aws_route_table.private : rt.id],
    [aws_route_table.data.id],
  )
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.endpoint_route_table_ids

  tags = {
    Name = "${local.name_prefix}-s3"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.endpoint_route_table_ids

  tags = {
    Name = "${local.name_prefix}-dynamodb"
  }
}
