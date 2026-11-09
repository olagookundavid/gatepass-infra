# WHO MAY TALK TO THE DATABASE AND THE CACHE: security groups.
#
# A security group is a stateful firewall attached to a network interface. These two are the whole
# network boundary of the data tier, and they are narrow on purpose:
#   database   TCP 5432 only from (a) the cluster security group = the pods, (b) the report
#              Lambda's group. Nothing else in the VPC, nothing from the internet (the subnets have
#              no route out or in anyway; this is the second lock).
#   cache      TCP 6379 only from the cluster security group.
# A pod that belongs to a service without database access still reaches the NETWORK port; what stops
# it is the database login (IAM token or password) and the Kubernetes NetworkPolicy (Phase 6 style
# default deny, opened per service in gatepass-gitops platform/network-policies). Three layers,
# each assuming the one before can fail.
#
# These groups have NO outbound rules: a database server never starts a connection.
#
# Related files: rds.tf and cache.tf (attach them), report.tf (the Lambda's group), data.tf.

resource "aws_security_group" "database" {
  name        = "${local.name_prefix}-database"
  description = "PostgreSQL: reachable from the cluster pods and the report Lambda only"
  vpc_id      = data.aws_vpc.main.id
}

resource "aws_security_group" "cache" {
  name        = "${local.name_prefix}-cache"
  description = "Valkey cache: reachable from the cluster pods only"
  vpc_id      = data.aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "database_from_pods" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from the pods"
}

resource "aws_vpc_security_group_ingress_rule" "database_from_report_lambda" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.report_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from the nightly report Lambda"
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_pods" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Valkey from the pods"
}
