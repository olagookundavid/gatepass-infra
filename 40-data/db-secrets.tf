# THE TWO DATABASE PASSWORDS used by the orders service, kept in Secrets Manager and never in state.
#
# WHICH USER USES WHAT (PLAN section 7, gatepass-app contracts)
#   catalog_app / catalog_migrator / orders_report    NO password: they sign in with a short-lived IAM
#                                                     token (RDS IAM authentication).
#   orders_app                                         the orders API, worker and relay: password.
#   orders_migrator                                    the schema-migration Job: password.
# The course used one master password for two databases and typed it into values files. Here every
# password is random, differs per role, lives only in Secrets Manager, and the RDS master password is
# owned by RDS itself (45-database, manage_master_user_password) and is used by nobody but the one
# bootstrap Job that creates the roles.
#
# WHY NOT IN STATE. `ephemeral` resources and `secret_string_wo` ("write-only") arguments exist only
# while Terraform runs: the random value is generated, handed to Secrets Manager, and forgotten; it
# is in neither the plan nor the state file. The price: Terraform cannot read the value back or see
# when it changes, so rotation is explicit: raise secret_string_wo_version to write a new password
# (then re-run the database bootstrap so the role gets it). Rotation by Secrets Manager itself with a
# Lambda (alternating users) is a Phase 11 exercise.
#
# The secrets are PERSISTENT (this layer) although the database is rebuilt daily: the bootstrap Job
# re-creates the roles with the SAME passwords each time, so nothing else has to change.
# JSON format {"username": ..., "password": ...} is what the Go service parses (DB_SECRET_ID).
#
# Related files: 45-database (the database), gatepass-gitops platform/data-bootstrap (creates the
# roles), 50-workloads (which service may read which secret: orders_migrator only the migrate Job).

ephemeral "random_password" "orders_app" {
  length  = 40
  special = false
}

ephemeral "random_password" "orders_migrator" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "orders_app" {
  name                    = "gatepass/${var.environment}/app/orders-app-db"
  description             = "Password of the PostgreSQL role orders_app (orders API, worker, relay)"
  kms_key_id              = data.aws_kms_alias.env.target_key_arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "orders_app" {
  secret_id = aws_secretsmanager_secret.orders_app.id
  secret_string_wo = jsonencode({
    username = "orders_app"
    password = ephemeral.random_password.orders_app.result
  })
  secret_string_wo_version = 1
}

resource "aws_secretsmanager_secret" "orders_migrator" {
  name                    = "gatepass/${var.environment}/app/orders-migrator-db"
  description             = "Password of the PostgreSQL role orders_migrator (schema migrations)"
  kms_key_id              = data.aws_kms_alias.env.target_key_arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "orders_migrator" {
  secret_id = aws_secretsmanager_secret.orders_migrator.id
  secret_string_wo = jsonencode({
    username = "orders_migrator"
    password = ephemeral.random_password.orders_migrator.result
  })
  secret_string_wo_version = 1
}
