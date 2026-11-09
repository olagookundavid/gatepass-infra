# ALARMS for the messaging layer: anything that lands in a dead-letter or failure queue, and any
# error of the hold-expirer Lambda, notifies the same alerts topic as the rest of the platform
# (60-observability: SNS -> e-mail).
#
# WHY "NOT EMPTY" IS THE RIGHT ALARM. A message only reaches a DLQ after five failed attempts: it is
# a poison message (a bug or bad data) or a consumer that has been broken for a while. Either way a
# human must look, so the threshold is "at least one message". The metric is
# ApproximateNumberOfMessagesVisible: the number waiting in the queue. Missing data counts as OK
# (an idle queue publishes no datapoints).
#
#   <queue>-dlq                      the three dead-letter queues
#   eventbridge-delivery-failures    a rule could not deliver an event (a broken target or key)
#   hold-expirer-stream-failures     the stream trigger gave up on a record
#   hold-expirer errors              the Lambda raised an error (the safety net is failing)
#
# Related files: messaging.tf and lambda.tf (the queues and the function), data.tf (the topic).

locals {
  alarmed_queues = merge(
    { for q, _ in local.queues : "${q}-dlq" => aws_sqs_queue.dlq[q].name },
    {
      "eventbridge-delivery-failures" = aws_sqs_queue.delivery_failures.name
      "hold-expirer-stream-failures"  = aws_sqs_queue.stream_failures.name
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "queue_not_empty" {
  for_each = local.alarmed_queues

  alarm_name          = "${local.name_prefix}-${each.key}-not-empty"
  alarm_description   = "Messages are waiting in ${each.value}. Read them (aws sqs receive-message), fix the cause, then redrive or purge."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.aws_sns_topic.alerts.arn]
  ok_actions          = [data.aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "hold_expirer_errors" {
  alarm_name          = "${local.name_prefix}-hold-expirer-errors"
  alarm_description   = "The hold-expirer Lambda failed. Expired holds may not be returning their tickets: check its log group and the stream-failures queue."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.hold_expirer.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.aws_sns_topic.alerts.arn]
  ok_actions          = [data.aws_sns_topic.alerts.arn]
}
