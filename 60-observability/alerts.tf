# ALERTING: Prometheus rules decide WHEN something is wrong, the AMP alert manager decides WHO is
# told, an SNS topic carries the message to an e-mail address.
#
#   rules (rules/*.yaml)  --evaluated every minute inside the workspace-->  firing alert
#   alert manager definition  groups alerts and routes them  -->  SNS topic gatepass-dev-alerts
#   SNS topic  -->  e-mail subscription (the address must CONFIRM once: AWS mails a link)
#
# WHY the alarms are rules and not CloudWatch alarms. The services emit RED metrics (rate, errors,
# duration) through OpenTelemetry into this workspace, so "5xx ratio above 5% for 5 minutes" is one
# line of PromQL per service, with no load balancer id in it. A CloudWatch alarm on the ALB needs
# the ALB's generated name suffix as a dimension; the ALB is created and destroyed by the load
# balancer controller, so a Terraform alarm on it would break at every rebuild. CloudWatch
# alarms that do not depend on such ids are in logs.tf.
#
# WHAT IS ALERTED (rules/platform.yaml, rules/services.yaml): deployments with unavailable
# replicas, crash loops, pods pending too long, nodes not ready or under pressure, Argo CD
# applications Degraded or out of sync, 5xx ratio and p95 latency above the SLO per service.
# There is NO "no metrics at all" alert on purpose: the cluster is down most of the time (`make
# down`), so it would e-mail all day. Production adds a heartbeat ("Watchdog" alert that always
# fires) to an external dead-man's switch that alerts when the heartbeat STOPS.
#
# SNS and encryption. The topic is NOT encrypted with a customer key: CloudWatch alarms and the
# AMP alert manager would each need a statement in that key's policy. Dev shortcut, decision log;
# production encrypts it and adds the two principals to the key policy.
#
# Related files: amp.tf (the workspace), logs.tf (a CloudWatch alarm that publishes here too).

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

data "aws_iam_policy_document" "alerts_topic" {
  # The AMP alert manager publishes as the service principal aps.amazonaws.com, only for THIS
  # workspace and account (confused-deputy protection through aws:SourceArn / aws:SourceAccount).
  statement {
    sid       = "AlertManagerPublishes"
    effect    = "Allow"
    actions   = ["sns:Publish", "sns:GetTopicAttributes"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["aps.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_prometheus_workspace.main.arn]
    }
  }

  # CloudWatch alarms of this account publish too (logs.tf).
  statement {
    sid       = "CloudWatchAlarmsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_prometheus_alert_manager_definition" "main" {
  workspace_id = aws_prometheus_workspace.main.id

  # group_by: one e-mail per alert name per namespace, not one per pod.
  # group_wait 30s: wait for sibling alerts before the first message.
  # repeat_interval 4h: a still-firing alert is repeated every four hours, not every minute.
  definition = <<-YAML
    alertmanager_config: |
      route:
        receiver: sns
        group_by: [alertname, namespace]
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 4h
      receivers:
        - name: sns
          sns_configs:
            - topic_arn: ${aws_sns_topic.alerts.arn}
              sigv4:
                region: ${var.region}
              subject: "[gatepass-${var.environment}] {{ .CommonLabels.alertname }} ({{ .Status }})"
              message: |
                {{ range .Alerts }}
                {{ .Annotations.summary }}
                {{ .Annotations.description }}
                Runbook: {{ .Annotations.runbook }}
                {{ end }}
  YAML

  depends_on = [aws_sns_topic_policy.alerts]
}

resource "aws_prometheus_rule_group_namespace" "platform" {
  name         = "platform"
  workspace_id = aws_prometheus_workspace.main.id
  data         = file("${path.module}/rules/platform.yaml")
}

resource "aws_prometheus_rule_group_namespace" "services" {
  name         = "services"
  workspace_id = aws_prometheus_workspace.main.id
  data         = file("${path.module}/rules/services.yaml")
}
