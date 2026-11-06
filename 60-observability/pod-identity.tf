# Two IAM roles for the observability workloads, each meant for ONE Kubernetes service account
# (EKS Pod Identity; how it works: 30-platform-aws/pod-identity.tf).
#
# THE ROLES LIVE HERE, THE ASSOCIATIONS DO NOT. This layer is persistent (like 00-bootstrap): the
# metrics workspace, the alert history and the log group must survive `make down`, so the layer
# must not need a cluster to exist. A Pod Identity association needs the cluster, so the two
# associations are in 30-platform-aws/observability.tf (ephemeral), which finds these roles by name.
#
#   otel-collector   the OpenTelemetry collectors WRITE telemetry: traces to X-Ray, metrics to the
#                    Prometheus workspace, logs to CloudWatch Logs. One service account is shared
#                    by the three collectors (gateway, agent, metrics), so they all get the same
#                    write-only role.
#   grafana          Grafana READS: metrics from the workspace, logs and metrics from CloudWatch,
#                    traces from X-Ray. It can write nothing.
#
# Write and read are two roles on purpose: a compromised dashboard cannot inject fake telemetry,
# and a compromised collector cannot read other people's logs.
#
# The names MUST equal what the Helm values in gatepass-gitops create
# (platform/otel-*/values.yaml and platform/grafana/values.yaml): namespace `observability`,
# service accounts `otel-collector` and `grafana`.
#
# Related files: amp.tf, logs.tf, xray.tf (the resources these roles may touch), alerts.tf.

locals {
  workloads = {
    otel-collector = {
      namespace       = var.otel_namespace
      service_account = "otel-collector"
    }
    grafana = {
      namespace       = var.otel_namespace
      service_account = "grafana"
    }
  }
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workload" {
  for_each = local.workloads

  name               = "${local.name_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

# ---- Collector: write-only ----------------------------------------------------------------
data "aws_iam_policy_document" "collector" {
  statement {
    sid    = "WriteMetricsToThisWorkspaceOnly"
    effect = "Allow"
    actions = [
      "aps:RemoteWrite",
    ]
    resources = [aws_prometheus_workspace.main.arn]
  }

  statement {
    sid    = "WriteLogsToTheApplicationLogGroupOnly"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.application.arn,
      "${aws_cloudwatch_log_group.application.arn}:*",
    ]
  }

  # X-Ray's write API does not support resource-level permissions (AWS documents "*" for these).
  statement {
    sid    = "WriteTraces"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:GetSamplingStatisticSummaries",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "collector" {
  name   = "write-telemetry"
  role   = aws_iam_role.workload["otel-collector"].id
  policy = data.aws_iam_policy_document.collector.json
}

# ---- Grafana: read-only -------------------------------------------------------------------
data "aws_iam_policy_document" "grafana" {
  statement {
    sid    = "QueryThisWorkspace"
    effect = "Allow"
    actions = [
      "aps:QueryMetrics",
      "aps:GetSeries",
      "aps:GetLabels",
      "aps:GetMetricMetadata",
    ]
    resources = [aws_prometheus_workspace.main.arn]
  }

  # The CloudWatch data source lists log groups and metrics before it can query them; those list
  # calls are not resource-scoped. The log READS are limited to the application log group.
  statement {
    sid    = "ReadCloudWatchMetricsAndListLogGroups"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:DescribeAlarms",
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "QueryTheApplicationLogGroup"
    effect = "Allow"
    actions = [
      "logs:StartQuery",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
    ]
    resources = [
      aws_cloudwatch_log_group.application.arn,
      "${aws_cloudwatch_log_group.application.arn}:*",
    ]
  }

  # GetQueryResults and StopQuery act on a query id, not on a log group.
  statement {
    sid    = "ReadLogQueryResults"
    effect = "Allow"
    actions = [
      "logs:GetQueryResults",
      "logs:StopQuery",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadTraces"
    effect = "Allow"
    actions = [
      "xray:GetTraceSummaries",
      "xray:BatchGetTraces",
      "xray:GetServiceGraph",
      "xray:GetTimeSeriesServiceStatistics",
      "xray:GetInsightSummaries",
      "xray:GetGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "grafana" {
  name   = "read-telemetry"
  role   = aws_iam_role.workload["grafana"].id
  policy = data.aws_iam_policy_document.grafana.json
}
