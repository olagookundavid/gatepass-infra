# WHAT EACH ROLE MAY DO: the table of PLAN section 7, as code.
#
# Every statement names EXACT resources (a table ARN, a queue ARN, a bucket prefix, one database
# user) and only the actions the service's contract (gatepass-app/contracts/<binary>.yaml) lists. The
# reasoning behind "exact": if a pod is compromised, the attacker can do what its role allows and
# nothing else, so the role should not be able to do more than the code needs.
#
# THE KEY STATEMENTS. Tables, queues, buckets and secrets are encrypted with OUR key, not AWS's
# default. When a role uses such a resource, AWS also checks that the role may use the KEY. Each
# resource kind gets one key statement, limited with `kms:ViaService` so that the permission works
# only when the call comes through that service (a stolen role cannot use the key directly to
# decrypt arbitrary data):
#   dynamodb   Decrypt, Encrypt, GenerateDataKey, DescribeKey
#   sqs-send   GenerateDataKey, Decrypt        (a producer encrypts the message)
#   sqs-recv   Decrypt                         (a consumer decrypts it)
#   s3-write   GenerateDataKey, Decrypt        s3-read   Decrypt
#   secrets    Decrypt
#
# HOW TO READ A STATEMENT: sid (a label), actions, resources, via (the service for kms:ViaService,
# empty for none) and passed_to (the service for iam:PassedToService on iam:PassRole, empty for
# none).
#
# NOT HERE: the KEDA operator's sqs:GetQueueAttributes (Phase 9, 30-platform-aws) and the Scheduler
# and Lambda roles (40-data and 45-database own those, next to the functions).
#
# Related files: roles.tf (the roles, one per key of `statements`), data.tf (the ARNs), the contracts.

locals {
  key = data.aws_kms_alias.env.target_key_arn

  # ARNs built from names (the resources are looked up by name in data.tf).
  rds_user = {
    catalog_app      = "${local.arn_prefix}:rds-db:${var.region}:${local.account_id}:dbuser:${data.aws_db_instance.this.resource_id}/catalog_app"
    catalog_migrator = "${local.arn_prefix}:rds-db:${var.region}:${local.account_id}:dbuser:${data.aws_db_instance.this.resource_id}/catalog_migrator"
  }
  cache_arn      = "${local.arn_prefix}:elasticache:${var.region}:${local.account_id}:serverlesscache:${local.name_prefix}"
  cache_user_arn = { for u in ["catalog", "reservations"] : u => "${local.arn_prefix}:elasticache:${var.region}:${local.account_id}:user:${local.name_prefix}-${u}" }

  # The data source returns the FULL ARN of the secret, including the random 6-character suffix that
  # Secrets Manager appends, so the permission names exactly this one secret.
  orders_app_secret      = data.aws_secretsmanager_secret.orders_app.arn
  orders_migrator_secret = data.aws_secretsmanager_secret.orders_migrator.arn

  ses_identity   = "${local.arn_prefix}:ses:${var.region}:${local.account_id}:identity/${var.domain}"
  ses_config_set = "${local.arn_prefix}:ses:${var.region}:${local.account_id}:configuration-set/${local.name_prefix}"

  # Reusable statements.
  kms_ddb      = { sid = "KeyForDynamoDB", actions = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"], resources = [local.key], via = "dynamodb", passed_to = "" }
  kms_sqs_send = { sid = "KeyForSqsSend", actions = ["kms:GenerateDataKey", "kms:Decrypt"], resources = [local.key], via = "sqs", passed_to = "" }
  kms_sqs_recv = { sid = "KeyForSqsReceive", actions = ["kms:Decrypt"], resources = [local.key], via = "sqs", passed_to = "" }
  kms_s3_write = { sid = "KeyForS3Write", actions = ["kms:GenerateDataKey", "kms:Decrypt"], resources = [local.key], via = "s3", passed_to = "" }
  kms_s3_read  = { sid = "KeyForS3Read", actions = ["kms:Decrypt"], resources = [local.key], via = "s3", passed_to = "" }
  kms_secrets  = { sid = "KeyForSecrets", actions = ["kms:Decrypt"], resources = [local.key], via = "secretsmanager", passed_to = "" }

  reservations_table_items = {
    sid       = "ReservationsTableItems"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
    resources = [data.aws_dynamodb_table.reservations.arn, "${data.aws_dynamodb_table.reservations.arn}/index/GSI1"]
    via       = ""
    passed_to = ""
  }

  statements = {
    # catalog-api: PostgreSQL as catalog_app (IAM auth), its cache user, image uploads (presign only:
    # signing makes no call, but the SIGNATURE only works if the role may PutObject), events.
    catalog = [
      { sid = "ConnectAsCatalogApp", actions = ["rds-db:connect"], resources = [local.rds_user.catalog_app], via = "", passed_to = "" },
      { sid = "ConnectToTheCacheAsCatalog", actions = ["elasticache:Connect"], resources = [local.cache_arn, local.cache_user_arn.catalog], via = "", passed_to = "" },
      { sid = "PresignEventImages", actions = ["s3:PutObject"], resources = ["${data.aws_s3_bucket.images.arn}/images/events/*"], via = "", passed_to = "" },
      { sid = "PublishEvents", actions = ["events:PutEvents"], resources = [data.aws_cloudwatch_event_bus.this.arn], via = "", passed_to = "" },
    ]

    # `catalog-api migrate`: the schema owner, only while the Job runs.
    catalog-migrate = [
      { sid = "ConnectAsCatalogMigrator", actions = ["rds-db:connect"], resources = [local.rds_user.catalog_migrator], via = "", passed_to = "" },
    ]

    # reservations-api (HTTP): the table and its index, per-hold schedules (and the right to hand the
    # scheduler role to the service), the rate limiter's cache user.
    reservations = [
      local.reservations_table_items,
      local.kms_ddb,
      { sid = "ManageHoldSchedules", actions = ["scheduler:CreateSchedule", "scheduler:DeleteSchedule"], resources = ["${local.arn_prefix}:scheduler:${var.region}:${local.account_id}:schedule/gatepass-holds/hold-*"], via = "", passed_to = "" },
      { sid = "PassTheSchedulerRole", actions = ["iam:PassRole"], resources = [data.aws_iam_role.scheduler_invoke.arn], via = "", passed_to = "scheduler.amazonaws.com" },
      { sid = "ConnectToTheCacheAsReservations", actions = ["elasticache:Connect"], resources = [local.cache_arn, local.cache_user_arn.reservations], via = "", passed_to = "" },
    ]

    # reservations-api with only the queue consumer switched on: the same table, plus the inventory
    # queue. (It does not need the scheduler or the cache.)
    reservations-consumer = [
      local.reservations_table_items,
      local.kms_ddb,
      { sid = "ConsumeInventoryQueue", actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], resources = [data.aws_sqs_queue.inventory.arn], via = "", passed_to = "" },
      local.kms_sqs_recv,
    ]

    # orders-api: the password secret of orders_app, and the payments queue to enqueue payments.
    orders = [
      { sid = "ReadOrdersAppSecret", actions = ["secretsmanager:GetSecretValue"], resources = [local.orders_app_secret], via = "", passed_to = "" },
      local.kms_secrets,
      { sid = "EnqueuePayments", actions = ["sqs:SendMessage"], resources = [data.aws_sqs_queue.payments.arn], via = "", passed_to = "" },
      local.kms_sqs_send,
    ]

    # `orders-api migrate`: the migrator's secret and nothing else.
    orders-migrate = [
      { sid = "ReadOrdersMigratorSecret", actions = ["secretsmanager:GetSecretValue"], resources = [local.orders_migrator_secret], via = "", passed_to = "" },
      local.kms_secrets,
    ]

    # orders-worker: the app secret and the payments queue (receive side).
    orders-worker = [
      { sid = "ReadOrdersAppSecret", actions = ["secretsmanager:GetSecretValue"], resources = [local.orders_app_secret], via = "", passed_to = "" },
      local.kms_secrets,
      { sid = "ConsumePayments", actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], resources = [data.aws_sqs_queue.payments.arn], via = "", passed_to = "" },
      local.kms_sqs_recv,
    ]

    # orders-outbox-relay: the app secret, the bus to publish on, and the payments queue for the
    # payment reconciler.
    orders-outbox-relay = [
      { sid = "ReadOrdersAppSecret", actions = ["secretsmanager:GetSecretValue"], resources = [local.orders_app_secret], via = "", passed_to = "" },
      local.kms_secrets,
      { sid = "PublishEvents", actions = ["events:PutEvents"], resources = [data.aws_cloudwatch_event_bus.this.arn], via = "", passed_to = "" },
      { sid = "EnqueuePayments", actions = ["sqs:SendMessage"], resources = [data.aws_sqs_queue.payments.arn], via = "", passed_to = "" },
      local.kms_sqs_send,
    ]

    # The database bootstrap Job: the master password and nothing else.
    data-bootstrap = [
      { sid = "ReadTheMasterSecret", actions = ["secretsmanager:GetSecretValue"], resources = [data.aws_secretsmanager_secret.rds_master.arn], via = "", passed_to = "" },
      local.kms_secrets,
    ]

    # notifications-api: read the notification log, hand out ticket download links (presign).
    notifications = [
      { sid = "NotificationsTableItems", actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query"], resources = [data.aws_dynamodb_table.notifications.arn], via = "", passed_to = "" },
      local.kms_ddb,
      { sid = "PresignTicketDownloads", actions = ["s3:GetObject"], resources = ["${data.aws_s3_bucket.tickets.arn}/tickets/*"], via = "", passed_to = "" },
      local.kms_s3_read,
    ]

    # notifications-worker: the queue, the table, ticket files, the user's e-mail from Cognito, SES.
    notifications-worker = [
      { sid = "ConsumeNotifications", actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], resources = [data.aws_sqs_queue.notifications.arn], via = "", passed_to = "" },
      local.kms_sqs_recv,
      { sid = "NotificationsTableItems", actions = ["dynamodb:GetItem", "dynamodb:PutItem"], resources = [data.aws_dynamodb_table.notifications.arn], via = "", passed_to = "" },
      local.kms_ddb,
      { sid = "TicketFiles", actions = ["s3:PutObject", "s3:GetObject"], resources = ["${data.aws_s3_bucket.tickets.arn}/tickets/*"], via = "", passed_to = "" },
      local.kms_s3_write,
      { sid = "LookUpUserEmail", actions = ["cognito-idp:AdminGetUser"], resources = tolist(data.aws_cognito_user_pools.this.arns), via = "", passed_to = "" },
      { sid = "SendEmail", actions = ["ses:SendEmail"], resources = [local.ses_identity, local.ses_config_set], via = "", passed_to = "" },
    ]
  }
}

data "aws_iam_policy_document" "workload" {
  for_each = local.statements

  dynamic "statement" {
    for_each = each.value

    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = statement.value.via != "" ? [statement.value.via] : []

        content {
          test     = "StringEquals"
          variable = "kms:ViaService"
          values   = ["${condition.value}.${var.region}.amazonaws.com"]
        }
      }

      dynamic "condition" {
        for_each = statement.value.passed_to != "" ? [statement.value.passed_to] : []

        content {
          test     = "StringEquals"
          variable = "iam:PassedToService"
          values   = [condition.value]
        }
      }
    }
  }
}
