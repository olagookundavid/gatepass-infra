# THE HOLD-EXPIRER: a small Go Lambda that gives a ticket hold's tickets back, plus the EventBridge
# Scheduler group that triggers it and the stream trigger that backs it up.
#
# THE PROBLEM. A customer holds 2 tickets for 10 minutes. If they do not buy, the 2 tickets must go
# back into inventory at about minute 10, not "some time later". DynamoDB's TTL cannot do that (it
# deletes within minutes to days), so the reservations service creates, for every hold, a ONE-TIME
# schedule in EventBridge Scheduler that fires at the hold's expiry time and invokes this Lambda
# with {"holdId": ...}. The schedule deletes itself after it runs.
#
# THE SAFETY NET. If a schedule is lost or the invocation fails for good, the hold item is later
# removed by TTL; that deletion appears in the table's STREAM and the same Lambda, through an event
# source mapping, releases the tickets from there. Two independent triggers, one idempotent
# function (releasing twice is harmless: a release marker item records that it happened).
#
# THE PIECES
#   schedule group gatepass-holds   the container the service creates its schedules in; the service
#                                   may create/delete only schedules named hold-* in this group.
#   scheduler role                  what Scheduler assumes to invoke the function (trust:
#                                   scheduler.amazonaws.com, only for this account). The reservations
#                                   service needs iam:PassRole on THIS role (50-workloads).
#   function                        provided.al2023 on arm64 (Graviton: cheaper), the binary is
#                                   named `bootstrap`; 128 MB; 15 s; no VPC (DynamoDB is public).
#   execution role                  exactly: three item actions on the table, the stream reads, send
#                                   to the failure queue, use the key, write its own log group.
#   event source mapping            reads the stream (new records only), batches of 10, reports which
#                                   records of a batch failed (ReportBatchItemFailures), retries 3
#                                   times, then sends the failed record's location to a queue
#                                   (stream-failures) so one bad record cannot block the shard.
#                                   The filter passes only deletions made by DynamoDB itself (TTL).
#   log group                       created here so it has retention and encryption (a function that
#                                   creates its own group gets none).
#
# THE CODE. Terraform uploads the zip that `make lambda-zip` built in gatepass-app (var.lambda_dist_dir)
# to the artifacts bucket under a name that contains its checksum, and the function points at that
# object. Dev shortcut: the pipeline should build and upload it (decision log).
# NOTE: Lambda concurrency quota in this account is 10, so no reserved concurrency is set.
#
# Related files: dynamodb.tf (table and stream), messaging.tf (the failure queue lives here),
# alarms.tf (errors), 50-workloads (reservations may pass the scheduler role and create schedules).

resource "aws_scheduler_schedule_group" "holds" {
  name = "gatepass-holds"
}

resource "aws_sqs_queue" "stream_failures" {
  name                      = "${local.name_prefix}-hold-expirer-stream-failures"
  message_retention_seconds = 1209600
  kms_master_key_id         = data.aws_kms_alias.env.target_key_id
}

locals {
  expirer_zip  = "${var.lambda_dist_dir}/lambda-hold-expirer.zip"
  expirer_name = "${local.name_prefix}-hold-expirer"
}

resource "aws_s3_object" "hold_expirer" {
  bucket = data.aws_s3_bucket.artifacts.id
  key    = "lambda/hold-expirer/${filemd5(local.expirer_zip)}.zip"
  source = local.expirer_zip
  # source_hash, NOT etag: a zip this size is uploaded in parts, and S3 then reports a multipart ETag
  # ("<hash>-2") that never equals the file's MD5, so an etag argument would show a change forever.
  source_hash = filemd5(local.expirer_zip)
}

resource "aws_cloudwatch_log_group" "hold_expirer" {
  name              = "/aws/lambda/${local.expirer_name}"
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

resource "aws_iam_role" "hold_expirer" {
  name               = local.expirer_name
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "hold_expirer" {
  statement {
    sid       = "TableItems"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.reservations.arn]
  }

  statement {
    sid       = "ReadTheStream"
    effect    = "Allow"
    actions   = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator"]
    resources = ["${aws_dynamodb_table.reservations.arn}/stream/*"]
  }

  statement {
    sid       = "ListStreams"
    effect    = "Allow"
    actions   = ["dynamodb:ListStreams"]
    resources = ["*"]
  }

  statement {
    sid       = "ReportFailedBatches"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.stream_failures.arn]
  }

  statement {
    sid       = "UseTheKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [data.aws_kms_alias.env.target_key_arn]
  }

  statement {
    sid       = "WriteItsOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.hold_expirer.arn}:*"]
  }
}

resource "aws_iam_role_policy" "hold_expirer" {
  name   = "hold-expirer"
  role   = aws_iam_role.hold_expirer.id
  policy = data.aws_iam_policy_document.hold_expirer.json
}

resource "aws_lambda_function" "hold_expirer" {
  function_name = local.expirer_name
  role          = aws_iam_role.hold_expirer.arn

  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"
  memory_size   = 128
  timeout       = 15

  s3_bucket        = aws_s3_object.hold_expirer.bucket
  s3_key           = aws_s3_object.hold_expirer.key
  source_code_hash = filebase64sha256(local.expirer_zip)

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.reservations.name
      LOG_LEVEL  = "info"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.hold_expirer.name
  }

  depends_on = [aws_iam_role_policy.hold_expirer]
}

resource "aws_lambda_event_source_mapping" "hold_expirer_stream" {
  function_name     = aws_lambda_function.hold_expirer.arn
  event_source_arn  = aws_dynamodb_table.reservations.stream_arn
  starting_position = "LATEST"

  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  maximum_retry_attempts             = 3
  maximum_record_age_in_seconds      = 3600
  bisect_batch_on_function_error     = true
  function_response_types            = ["ReportBatchItemFailures"]

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.stream_failures.arn
    }
  }

  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName    = ["REMOVE"]
        userIdentity = { type = ["Service"], principalId = ["dynamodb.amazonaws.com"] }
      })
    }
  }
}

# EventBridge Scheduler assumes this role to invoke the function.
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

resource "aws_iam_role" "scheduler_invoke" {
  name               = "${local.name_prefix}-scheduler-invoke"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler_invoke" {
  statement {
    sid       = "InvokeTheHoldExpirer"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.hold_expirer.arn, "${aws_lambda_function.hold_expirer.arn}:*"]
  }
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name   = "invoke-hold-expirer"
  role   = aws_iam_role.scheduler_invoke.id
  policy = data.aws_iam_policy_document.scheduler_invoke.json
}
