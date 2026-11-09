# THE LAYER'S ADDRESS BOOK, published for the services: one Secrets Manager secret with every value
# the services need that comes from this layer.
#
# WHY NOT IN THE VALUES FILES IN GIT. The plan said "endpoints and ARNs reach Git as values". They
# contain the AWS account id (queue URLs, role ARNs), and the repositories are public. So the same
# pattern as the observability endpoints applies: Terraform writes the values to Secrets Manager, and
# each service's ExternalSecret (gatepass-gitops charts/gatepass-service) copies the keys it needs
# into environment variables, for example
#     {secretKey: TABLE_NAME, key: gatepass/dev/app/data-config, property: reservations_table}
# External Secrets may read only the prefix gatepass/dev/app/ (30-platform-aws/external-secrets.tf).
# Nothing here is secret (names and addresses), but it is not published either.
#
# The values that change when the database is rebuilt (host names) are in a second secret written by
# 45-database (database-config), so this one stays stable between sessions.
#
# Related files: every .tf file of the layer (the values), outputs.tf (the same keys for humans),
# 50-workloads (the roles that match these resources).

locals {
  config = {
    region                    = var.region
    reservations_table        = aws_dynamodb_table.reservations.name
    notifications_table       = aws_dynamodb_table.notifications.name
    inventory_queue_url       = aws_sqs_queue.main["reservations-inventory"].url
    notifications_queue_url   = aws_sqs_queue.main["notifications"].url
    payments_queue_url        = aws_sqs_queue.main["orders-payments"].url
    event_bus_name            = aws_cloudwatch_event_bus.this.name
    images_bucket             = aws_s3_bucket.this["images"].bucket
    tickets_bucket            = aws_s3_bucket.this["tickets"].bucket
    reports_bucket            = aws_s3_bucket.this["reports"].bucket
    cdn_base_url              = "https://cdn.${var.domain}"
    cognito_user_pool_id      = aws_cognito_user_pool.this.id
    cognito_client_id         = aws_cognito_user_pool_client.app.id
    cognito_issuer            = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
    scheduler_group_name      = aws_scheduler_schedule_group.holds.name
    scheduler_role_arn        = aws_iam_role.scheduler_invoke.arn
    expirer_lambda_arn        = aws_lambda_function.hold_expirer.arn
    ses_from_address          = "noreply@${var.domain}"
    ses_configuration_set     = aws_sesv2_configuration_set.this.configuration_set_name
    ses_recipient_override    = var.ses_sandbox_recipient
    orders_app_secret_id      = aws_secretsmanager_secret.orders_app.name
    orders_migrator_secret_id = aws_secretsmanager_secret.orders_migrator.name
  }
}

resource "aws_secretsmanager_secret" "config" {
  name                    = "gatepass/${var.environment}/app/data-config"
  description             = "Names, URLs and ARNs of the persistent data layer (40-data), read by External Secrets"
  kms_key_id              = data.aws_kms_alias.env.target_key_arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "config" {
  secret_id     = aws_secretsmanager_secret.config.id
  secret_string = jsonencode(local.config)
}
