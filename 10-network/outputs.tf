# What the network layer publishes. These are for people and for scripts (the Makefile prints
# them, the walkthrough checks them). 20-cluster does NOT read them: it finds the VPC and the
# private subnets by tag, so the two layers stay loosely coupled and a state file with
# everything in it is never shared between layers.

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "azs" {
  description = "The availability zones in use, in order."
  value       = var.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in zone order."
  value       = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs (nodes and pods), in zone order."
  value       = [for az in var.azs : aws_subnet.private[az].id]
}

output "data_subnet_ids" {
  description = "Isolated data subnet IDs (RDS, ElastiCache), in zone order."
  value       = [for az in var.azs : aws_subnet.data[az].id]
}

output "nat_public_ips" {
  description = "Public IP address(es) of the NAT gateway(s): what the internet sees as the source of all outbound traffic from the private subnets."
  value       = [for az in local.nat_azs : aws_eip.nat[az].public_ip]
}

output "flow_log_group" {
  description = "CloudWatch log group that receives the VPC flow logs."
  value       = aws_cloudwatch_log_group.flow.name
}
