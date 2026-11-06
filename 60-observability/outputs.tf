# What this layer publishes. The AMP URLs and workspace id are not secrets; they are printed so
# the gatepass-gitops side can be given them (walkthrough 06 step C) without being committed.
#
# Related files: amp.tf, alerts.tf, logs.tf, pod-identity.tf.

output "amp_workspace_id" {
  description = "Id of the Prometheus workspace."
  value       = aws_prometheus_workspace.main.id
}

output "amp_remote_write_url" {
  description = "Where the collectors push metrics (SigV4)."
  value       = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}

output "amp_query_url" {
  description = "Where Grafana queries metrics (the data source URL, SigV4)."
  value       = aws_prometheus_workspace.main.prometheus_endpoint
}

output "alerts_topic_arn" {
  description = "SNS topic that receives every alert."
  value       = aws_sns_topic.alerts.arn
}

output "application_log_group" {
  description = "Log group the node agent writes to."
  value       = aws_cloudwatch_log_group.application.name
}

output "pod_identities" {
  description = "Who runs where: role bound to namespace/service account."
  value = {
    for k, v in local.workloads : k => "${v.namespace}/${v.service_account} -> ${aws_iam_role.workload[k].name}"
  }
}
