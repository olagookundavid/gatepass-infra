# THE MESSAGING BACKBONE: three work queues (each with a dead-letter queue) and the EventBridge bus
# that fans business events out to them.
#
# THE FLOW (gatepass-app contracts, PLAN section 3). Services do not call each other for
# "something happened": they publish an EVENT on the bus, and rules route it to the queues of the
# services that care. A queue decouples producer and consumer in time (the consumer can be down or
# slow and the messages wait), absorbs bursts, and gives retries for free.
#
#   catalog      EventPublished                          -> reservations-inventory   (create counters)
#   orders       PaymentFailed, OrderCancelled           -> reservations-inventory   (give tickets back)
#   orders       OrderPaid, PaymentFailed, OrderCancelled-> notifications            (mail the user)
#   orders       OrderPlaced                             -> (archive only, no queue)
#   orders-payments is NOT fed by the bus: orders-api and the relay send to it directly (simulated
#   payments), so it has a queue policy-free default.
#
# WHAT EVERY QUEUE HAS
#   a dead-letter queue (DLQ)  after 5 failed receives a message moves there instead of looping
#                              forever; an alarm (alarms.tf) fires when one is not empty. A DLQ is
#                              where a poison message waits for a human.
#   visibility timeout 90 s    the time one consumer holds a message before it becomes visible
#                              again; the services need at least 60 s (contracts).
#   encryption with our key    SQS-KMS; for the queues that EventBridge writes into, the key policy
#                              (00-bootstrap/kms.tf) lets events.amazonaws.com use the key.
#   14-day retention on DLQs   long enough to investigate over a weekend.
#
# THE ARCHIVE keeps every event of the bus for 7 days so a bug fix can REPLAY them (a replay
# re-sends archived events to the bus); the aws console / CLI does the replay (Phase 11 drill).
#
# EVENT DELIVERY FAILURES (the rule target cannot reach the queue) go to a separate queue,
# `eventbridge-delivery-failures`, instead of being dropped.
#
# Related files: alarms.tf (DLQ alarms), lambda.tf (its own failure queue), config.tf (queue URLs),
# 50-workloads (who may send / receive on which queue).

locals {
  # name => whether EventBridge writes into it
  queues = {
    "reservations-inventory" = { from_bus = true }
    "notifications"          = { from_bus = true }
    "orders-payments"        = { from_bus = false }
  }

  # The three rules. detail-type values are exactly the event names in the contracts.
  rules = {
    "catalog-event-published" = {
      source      = ["gatepass.catalog"]
      detail_type = ["EventPublished"]
      queue       = "reservations-inventory"
    }
    "orders-release-inventory" = {
      source      = ["gatepass.orders"]
      detail_type = ["PaymentFailed", "OrderCancelled"]
      queue       = "reservations-inventory"
    }
    "orders-notify" = {
      source      = ["gatepass.orders"]
      detail_type = ["OrderPaid", "PaymentFailed", "OrderCancelled"]
      queue       = "notifications"
    }
  }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.queues

  name                      = "${local.name_prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = data.aws_kms_alias.env.target_key_id
}

resource "aws_sqs_queue" "main" {
  for_each = local.queues

  name                       = "${local.name_prefix}-${each.key}"
  visibility_timeout_seconds = 90
  kms_master_key_id          = data.aws_kms_alias.env.target_key_id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  })
}

# A DLQ accepts messages only from its own main queue.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = local.queues

  queue_url = aws_sqs_queue.dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main[each.key].arn]
  })
}

# Undeliverable events (see the header).
resource "aws_sqs_queue" "delivery_failures" {
  name                      = "${local.name_prefix}-eventbridge-delivery-failures"
  message_retention_seconds = 1209600
  kms_master_key_id         = data.aws_kms_alias.env.target_key_id
}

resource "aws_cloudwatch_event_bus" "this" {
  name = local.name_prefix
}

resource "aws_cloudwatch_event_archive" "this" {
  name             = "${local.name_prefix}-all-events"
  event_source_arn = aws_cloudwatch_event_bus.this.arn
  retention_days   = 7
  description      = "Every event of the Gatepass bus, kept for replay."
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.rules

  name           = "${local.name_prefix}-${each.key}"
  event_bus_name = aws_cloudwatch_event_bus.this.name

  event_pattern = jsonencode({
    source        = each.value.source
    "detail-type" = each.value.detail_type
  })
}

resource "aws_cloudwatch_event_target" "queue" {
  for_each = local.rules

  rule           = aws_cloudwatch_event_rule.this[each.key].name
  event_bus_name = aws_cloudwatch_event_bus.this.name
  target_id      = "queue"
  arn            = aws_sqs_queue.main[each.value.queue].arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }

  dead_letter_config {
    arn = aws_sqs_queue.delivery_failures.arn
  }
}

# Who may write into a queue: EventBridge, but only on behalf of the rules that target it.
data "aws_iam_policy_document" "queue_from_rules" {
  for_each = { for q, v in local.queues : q => v if v.from_bus }

  statement {
    sid       = "AllowTheRulesOfTheBus"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for r, v in local.rules : aws_cloudwatch_event_rule.this[r].arn if v.queue == each.key]
    }
  }
}

resource "aws_sqs_queue_policy" "from_rules" {
  for_each = data.aws_iam_policy_document.queue_from_rules

  queue_url = aws_sqs_queue.main[each.key].id
  policy    = each.value.json
}

data "aws_iam_policy_document" "delivery_failures" {
  statement {
    sid       = "AllowTheTargetsToReportFailures"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.delivery_failures.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for r in aws_cloudwatch_event_rule.this : r.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "delivery_failures" {
  queue_url = aws_sqs_queue.delivery_failures.id
  policy    = data.aws_iam_policy_document.delivery_failures.json
}
