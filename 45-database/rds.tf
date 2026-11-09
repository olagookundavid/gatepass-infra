# THE RELATIONAL DATABASE: Amazon RDS for PostgreSQL, one instance holding two databases (catalog
# and orders), rebuilt every day.
#
# WHAT IT HOLDS. `catalog` (venues, events, ticket types) and `orders` (orders, payments, the outbox
# of events to publish). Two databases on one small instance keep the cost down; each service has its
# own roles and cannot see the other database (the roles are created by the bootstrap Job,
# gatepass-gitops platform/data-bootstrap, from the SQL in gatepass-app/HANDOFF.md).
#
# HOW SERVICES SIGN IN
#   catalog_app, catalog_migrator, orders_report   IAM database authentication: the pod asks AWS for
#       a signed token valid for 15 minutes and uses it as the password. There is NO password to
#       store, rotate or leak; permission is the IAM action rds-db:connect on one database user
#       (50-workloads). This needs `iam_database_authentication_enabled`.
#   orders_app, orders_migrator   a password from Secrets Manager (40-data/db-secrets.tf), to show
#       the other pattern and to compare the two.
#   gatepass_admin (the master user)   its password is created and held by RDS in Secrets Manager
#       (`manage_master_user_password`): Terraform never sees it, and it is used only by the
#       bootstrap Job that creates the roles.
# Clients connect with TLS and verify the server name (the RDS root certificate bundle is inside the
# Go binaries). `rds.force_ssl = 1` makes the SERVER refuse any connection that is not encrypted.
#
# SIZE AND COST. db.t4g.micro, 20 GiB gp3, single zone: about $0.016 an hour plus storage, one of the
# two things that make `make down` worth doing every evening. Multi-AZ (a standby in another zone,
# automatic failover) doubles it and is what production uses.
#
# DEV SHORTCUTS (decision log): skip_final_snapshot (no snapshot when the instance is destroyed),
# deletion_protection off, backups kept 1 day, no Performance Insights, no log export (an exported
# log group would be created without retention). Production keeps final snapshots, protection,
# 7-35 days of backups and Multi-AZ.
#
# THE HOST NAME changes at every rebuild (it contains a random id). Services get it from the secret
# `database-config` (config.tf), never from Git.
#
# Related files: network.tf (who can reach it), config.tf (publishes the address and the resource id
# that the rds-db:connect ARNs need), 50-workloads (those ARNs), 40-data/db-secrets.tf (the two
# passwords).

resource "aws_db_subnet_group" "this" {
  name        = local.name_prefix
  description = "Data-tier subnets (no route to the internet) in three zones"
  subnet_ids  = data.aws_subnets.data.ids
}

resource "aws_db_parameter_group" "this" {
  name        = "${local.name_prefix}-postgres${var.postgres_major_version}"
  family      = "postgres${var.postgres_major_version}"
  description = "Gatepass: refuse unencrypted connections"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_db_instance" "this" {
  identifier     = local.name_prefix
  engine         = "postgres"
  engine_version = var.postgres_major_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = data.aws_kms_alias.env.target_key_arn

  username                      = "gatepass_admin"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = data.aws_kms_alias.env.target_key_arn

  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.database.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  apply_immediately          = true

  deletion_protection = false
  skip_final_snapshot = true
}
