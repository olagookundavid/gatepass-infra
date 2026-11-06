# The Karpenter INTERRUPTION QUEUE: how AWS tells Karpenter "this node is about to go away".
#
# Five kinds of AWS events are routed by EventBridge rules into one SQS queue that Karpenter
# polls:
#   Spot interruption warning        2 minutes' notice that a Spot node will be reclaimed
#   Rebalance recommendation         early hint that a Spot node is at higher risk
#   Instance state change            a node was stopped or terminated outside Karpenter
#   AWS Health event                 scheduled maintenance that will affect a node
#   Capacity reservation interruption a reservation-backed node is being taken back
# On a message Karpenter cordons and drains the node (so pods leave gracefully) and starts a
# replacement before the node disappears. Without the queue the node vanishes and the pods
# are rescheduled only after Kubernetes notices, a minute or more later. With only On-Demand
# nodes it still matters for Health and state-change events; with Spot it is essential.
#
# The queue and rules are the ones from the upstream template for Karpenter v1.15.1 (the same
# source as the policies in policies/), translated to Terraform. The queue is named exactly
# like the cluster because the Karpenter chart is told that name in gatepass-gitops
# (settings.interruptionQueue).
#
# Messages live 5 minutes (300 s): an interruption notice older than that is useless.
#
# Related files: karpenter-iam.tf (the controller may only read THIS queue),
# gatepass-gitops/platform/karpenter/values.yaml.

resource "aws_sqs_queue" "karpenter" {
  name                      = "${local.name_prefix}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "karpenter_queue" {
  # EventBridge (and SQS itself) may put messages in the queue.
  statement {
    sid       = "EC2InterruptionPolicy"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }

  # Refuse plain HTTP to the queue, whoever asks.
  statement {
    sid       = "DenyHTTP"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.karpenter.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.url
  policy    = data.aws_iam_policy_document.karpenter_queue.json
}

locals {
  karpenter_events = {
    scheduled-change = {
      source      = "aws.health"
      detail_type = "AWS Health Event"
    }
    spot-interruption = {
      source      = "aws.ec2"
      detail_type = "EC2 Spot Instance Interruption Warning"
    }
    rebalance = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance Rebalance Recommendation"
    }
    instance-state-change = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance State-change Notification"
    }
    capacity-reservation-interruption = {
      source      = "aws.ec2"
      detail_type = "EC2 Capacity Reservation Instance Interruption Warning"
    }
  }
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each = local.karpenter_events

  name        = "${local.name_prefix}-karpenter-${each.key}"
  description = "Karpenter interruption queue: ${each.value.detail_type}"

  event_pattern = jsonencode({
    source        = [each.value.source]
    "detail-type" = [each.value.detail_type]
  })
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each = local.karpenter_events

  rule = aws_cloudwatch_event_rule.karpenter[each.key].name
  arn  = aws_sqs_queue.karpenter.arn
}
