# THE NIGHTLY SALES REPORT: a Go Lambda that runs inside the VPC, reads the orders database with a
# read-only IAM identity and writes yesterday's sales as a CSV file into the reports bucket. An
# EventBridge Scheduler schedule starts it every night at 00:05 UTC.
#
# WHY IT IS HERE AND NOT IN 40-data. It must reach the database, so it lives in the private subnets
# of the VPC and is created and destroyed together with the database (this layer), unlike the
# hold-expirer that needs no VPC and stays up between sessions.
#
# WHAT IT NEEDS (the contract of lambda-nightly-report)
#   network   private subnets; its own security group that may open 5432 to the database group and
#             443 to S3 only (through the S3 gateway endpoint of 10-network, whose address list is
#             `aws_prefix_list.s3`); no NAT is involved. Without a route to S3 the upload times out.
#   identity  `rds-db:connect` as the database user `orders_report` (read-only, IAM authentication),
#             `s3:PutObject` under reports/, the key for the bucket's encryption, and the managed
#             policy that lets a Lambda manage the network interfaces it needs in a VPC.
#   code      the zip built by `make lambda-zip`, uploaded to the artifacts bucket (dev shortcut).
#   schedule  cron(5 0 * * ? *) in UTC, no flexible window, a small retry (the function is idempotent:
#             it overwrites that day's file). A backfill: invoke it by hand with {"date":"YYYY-MM-DD"}.
# Concurrency is not reserved (the account quota is 10). Cost: a few cents a month.
#
# THE DATABASE USER orders_report is created by the bootstrap Job (gatepass-gitops
# platform/data-bootstrap). Until it has run, the function fails to sign in; the first scheduled run
# is after midnight anyway.
#
# Related files: network.tf (database rules reference the Lambda's group), rds.tf (host and resource
# id), 40-data (the bucket and key), alarms below.

locals {
  report_name = "${local.name_prefix}-nightly-report"
  report_zip  = "${var.lambda_dist_dir}/lambda-nightly-report.zip"
}

resource "aws_security_group" "report_lambda" {
  name        = local.report_name
  description = "Nightly report Lambda: PostgreSQL out, S3 out, nothing in"
  vpc_id      = data.aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "report_to_database" {
  security_group_id            = aws_security_group.report_lambda.id
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL"
}

resource "aws_vpc_security_group_egress_rule" "report_to_s3" {
  security_group_id = aws_security_group.report_lambda.id
  prefix_list_id    = data.aws_prefix_list.s3.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "S3 through the gateway endpoint"
}

resource "aws_s3_object" "report" {
  bucket = data.aws_s3_bucket.artifacts.id
  key    = "lambda/nightly-report/${filemd5(local.report_zip)}.zip"
  source = local.report_zip
  etag   = filemd5(local.report_zip)
}

resource "aws_cloudwatch_log_group" "report" {
  name              = "/aws/lambda/${local.report_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = data.aws_kms_alias.env.target_key_arn
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "report" {
  name               = local.report_name
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# Create, describe and delete the network interfaces of a function inside a VPC (AWS-managed).
resource "aws_iam_role_policy_attachment" "report_vpc" {
  role       = aws_iam_role.report.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "report" {
  statement {
    sid       = "ConnectAsTheReadOnlyDatabaseUser"
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = ["arn:${local.partition}:rds-db:${var.region}:${local.account_id}:dbuser:${aws_db_instance.this.resource_id}/orders_report"]
  }

  statement {
    sid       = "WriteTheReports"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${data.aws_s3_bucket.reports.arn}/reports/*"]
  }

  statement {
    sid       = "UseTheKeyOfTheBucket"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [data.aws_kms_alias.env.target_key_arn]
  }

  statement {
    sid       = "WriteItsOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.report.arn}:*"]
  }
}

resource "aws_iam_role_policy" "report" {
  name   = "nightly-report"
  role   = aws_iam_role.report.id
  policy = data.aws_iam_policy_document.report.json
}

resource "aws_lambda_function" "report" {
  function_name = local.report_name
  role          = aws_iam_role.report.arn

  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"
  memory_size   = 256
  timeout       = 60

  s3_bucket        = aws_s3_object.report.bucket
  s3_key           = aws_s3_object.report.key
  source_code_hash = filebase64sha256(local.report_zip)

  vpc_config {
    subnet_ids         = data.aws_subnets.private.ids
    security_group_ids = [aws_security_group.report_lambda.id]
  }

  environment {
    variables = {
      DB_HOST        = aws_db_instance.this.address
      DB_PORT        = "5432"
      DB_NAME        = "orders"
      DB_USER        = "orders_report"
      REPORTS_BUCKET = data.aws_s3_bucket.reports.bucket
      LOG_LEVEL      = "info"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.report.name
  }

  depends_on = [aws_iam_role_policy.report, aws_iam_role_policy_attachment.report_vpc]
}

# The Scheduler assumes this role to invoke the function.
data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "report_scheduler" {
  name               = "${local.report_name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

resource "aws_iam_role_policy" "report_scheduler" {
  name = "invoke-nightly-report"
  role = aws_iam_role.report_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeTheReport"
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [aws_lambda_function.report.arn, "${aws_lambda_function.report.arn}:*"]
    }]
  })
}

resource "aws_scheduler_schedule" "report" {
  name        = local.report_name
  group_name  = "default"
  description = "Every night at 00:05 UTC: write yesterday's sales CSV"

  schedule_expression          = "cron(5 0 * * ? *)"
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.report.arn
    role_arn = aws_iam_role.report_scheduler.arn
    input    = "{}"

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "report_errors" {
  alarm_name          = "${local.report_name}-errors"
  alarm_description   = "The nightly report Lambda failed (is the orders_report database user created? is S3 reachable?)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.report.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.aws_sns_topic.alerts.arn]
}

data "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}
