# Lookups of everything the roles point at, found BY NAME (the layers 40-data and 45-database are
# applied independently; this layer reads no other layer's state). It is applied after both and after
# the cluster, and destroyed before them: the database ARN contains an id that changes at every
# rebuild, which is why these roles are rebuilt too.
#
# Related files: roles.tf (who gets a role), policies.tf (what each role may do).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix  = "gatepass-${var.environment}"
  cluster_name = local.name_prefix
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition

  # Short forms used in the ARNs below.
  arn_prefix = "arn:${local.partition}"
}

data "aws_kms_alias" "env" {
  name = "alias/${local.name_prefix}"
}

# --- 40-data
data "aws_dynamodb_table" "reservations" {
  name = "${local.name_prefix}-reservations"
}

data "aws_dynamodb_table" "notifications" {
  name = "${local.name_prefix}-notifications"
}

data "aws_sqs_queue" "inventory" {
  name = "${local.name_prefix}-reservations-inventory"
}

data "aws_sqs_queue" "notifications" {
  name = "${local.name_prefix}-notifications"
}

data "aws_sqs_queue" "payments" {
  name = "${local.name_prefix}-orders-payments"
}

data "aws_cloudwatch_event_bus" "this" {
  name = local.name_prefix
}

data "aws_s3_bucket" "images" {
  bucket = "${local.name_prefix}-images-${local.account_id}-${var.region}"
}

data "aws_s3_bucket" "tickets" {
  bucket = "${local.name_prefix}-tickets-${local.account_id}-${var.region}"
}

data "aws_cognito_user_pools" "this" {
  name = "${local.name_prefix}-users"
}

data "aws_secretsmanager_secret" "orders_app" {
  name = "gatepass/${var.environment}/app/orders-app-db"
}

data "aws_secretsmanager_secret" "orders_migrator" {
  name = "gatepass/${var.environment}/app/orders-migrator-db"
}

data "aws_iam_role" "scheduler_invoke" {
  name = "${local.name_prefix}-scheduler-invoke"
}

# --- 45-database
data "aws_db_instance" "this" {
  db_instance_identifier = local.name_prefix
}

# The secret that RDS itself keeps for the master user (manage_master_user_password). Its name is
# generated (rds!db-<uuid>), so it is found through the instance.
data "aws_secretsmanager_secret" "rds_master" {
  arn = data.aws_db_instance.this.master_user_secret[0].secret_arn
}
