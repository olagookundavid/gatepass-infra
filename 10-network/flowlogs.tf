# VPC Flow Logs: a record of every network connection that was allowed or rejected.
#
# WHY. When "pod A cannot reach database B", or when you ask "what was this node talking to?",
# the flow log is the evidence: source, destination, port, accepted or rejected. Without it you
# are guessing. It is also a security record (what did a compromised pod connect to?).
#
# COST AND SIZE CONTROLS (this is where flow logs get expensive if left alone):
#   * short retention (var.flow_logs_retention_days, default 7 days) on a log group WE create,
#     because the automatic one would keep logs forever;
#   * max_aggregation_interval 600 seconds instead of 60: fewer, larger records;
#   * CloudWatch Logs ingestion is about $0.50 per GB; at this traffic that is cents per day.
# Production often sends them to S3 instead (cheaper at scale, queryable with Athena).
#
# ENCRYPTION. The log group uses the environment KMS key from 00-bootstrap (found by its alias;
# the key policy there has the statement that lets CloudWatch Logs use it).
#
# Related files: vpc.tf (the VPC being logged). The role below can write ONLY to this one log
# group. The log group is deleted together with the layer, so `make down` leaves nothing behind.

data "aws_kms_alias" "env" {
  name = "alias/${local.name_prefix}"
}

resource "aws_cloudwatch_log_group" "flow" {
  name              = "/aws/vpc/${local.name_prefix}/flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = data.aws_kms_alias.env.target_key_arn
}

# The role the flow-log SERVICE assumes to write into the log group. The condition
# (aws:SourceAccount) stops another account's flow log from using it (the "confused deputy").
data "aws_iam_policy_document" "flow_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "flow_write" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow.arn}:*"]
  }
}

resource "aws_iam_role" "flow" {
  name               = "${local.name_prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_trust.json
}

resource "aws_iam_role_policy" "flow" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow.id
  policy = data.aws_iam_policy_document.flow_write.json
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow.arn
  iam_role_arn             = aws_iam_role.flow.arn
  max_aggregation_interval = 600

  tags = {
    Name = local.name_prefix
  }
}
