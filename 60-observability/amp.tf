# The metrics store: an Amazon Managed Service for Prometheus (AMP) workspace.
#
# WHAT IT IS. A Prometheus-compatible database that AWS runs. Collectors push samples to it
# (`remote_write`, signed with the pod's IAM role); Grafana and the alert rules query it with
# PromQL. You pay per ingested sample and per query, nothing while it is empty. Metrics are kept
# 150 days by default (AWS-controlled).
#
# WHY NOT run Prometheus in the cluster: storage, upgrades, high availability and the data
# itself would die with every `make down`. AMP survives teardown, so history and dashboards
# keep working across rebuilds, and it is the managed service the course used.
#
# ENCRYPTION. The default AWS-owned key (a customer-managed key needs a key policy for the
# service and was not verified; production uses the project key like the log groups).
#
# The workspace is created ONCE, here, and the collectors in the cluster learn its address
# from the output `amp_remote_write_url`, which gatepass-gitops needs as a value: it is not a
# secret and not an account id, but it does contain the workspace id, so it is injected from the
# cluster side, not written in the public repository (see walkthrough 06 step C).
#
# Related files: alerts.tf (alert manager and rules live in this workspace), pod-identity.tf
# (who may write and read), outputs.tf.

resource "aws_prometheus_workspace" "main" {
  alias = local.name_prefix
}
