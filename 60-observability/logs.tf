# APPLICATION LOGS in CloudWatch Logs, with a retention period and the environment key.
#
# WHY RETENTION IS SET HERE. A log group created by an agent on first write has NO expiry: logs
# are kept and billed forever. The course's collector did exactly that. Creating the group in
# Terraform, before the collector writes, fixes the retention in review: 14 days in dev.
# `make check-retention` lists every log group in the account that still has none.
#
# WHAT WRITES HERE. The node agent (gatepass-gitops/platform/otel-agent) reads the container log
# files of the gatepass-* namespaces and writes each line as it is (raw_log), one log stream per
# pod. The services log JSON with a `trace_id` field, so a log line and its trace can be joined.
#
# ENCRYPTION. Encrypted with the environment key (its policy lets the CloudWatch Logs service
# use it, added in 00-bootstrap/kms.tf).
#
# THE ERROR-RATE ALARM. The agent writes each log event as JSON {body, attributes, resource, ...};
# the service's own JSON fields are under `attributes`. A metric filter counts events whose
# `attributes.level` is `error`;
# the alarm fires when there are more than 5 in 5 minutes and publishes to the alerts topic.
# It needs no load balancer id and works for every service the day it starts logging.
# (Matching on JSON fields: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)
#
# Related files: pod-identity.tf (the collector may write here only), alerts.tf (the topic).

resource "aws_cloudwatch_log_group" "application" {
  name              = "/gatepass/${var.environment}/application"
  retention_in_days = var.application_log_retention_days
  kms_key_id        = data.aws_kms_alias.env.target_key_arn
}

resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "${local.name_prefix}-error-lines"
  log_group_name = aws_cloudwatch_log_group.application.name
  pattern        = "{ $.attributes.level = \"error\" }"

  metric_transformation {
    name          = "ApplicationErrorLines"
    namespace     = "Gatepass/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${local.name_prefix}-application-error-lines"
  alarm_description   = "More than 5 error-level log lines in 5 minutes across the gatepass services. Search the application log group for level=error."
  namespace           = "Gatepass/${var.environment}"
  metric_name         = "ApplicationErrorLines"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
