# WHAT ARGO ROLLOUTS MAY DO IN AWS: ask the Prometheus workspace questions. Nothing else.
#
# During a canary the controller runs the AnalysisTemplate of the service (gatepass-gitops
# charts/gatepass-service/templates/analysis.yaml): two PromQL queries about the NEW version's error rate
# and latency, sent to the AMP workspace with a SigV4 signature made from THIS role's credentials. The
# permissions are the read side of AMP: query, and the calls Grafana-style tools use to list series and
# labels. No remote write (only the OpenTelemetry collector may write), no workspace management.
#
# The workspace is found by name (alias = gatepass-<env>), as 60-observability created it.
# Related files: pod-identity.tf (the role and its association), data.tf (the workspace lookup).

data "aws_iam_policy_document" "rollouts" {
  statement {
    sid    = "QueryTheMetricsWorkspace"
    effect = "Allow"
    actions = [
      "aps:QueryMetrics",
      "aps:GetSeries",
      "aps:GetLabels",
      "aps:GetMetricMetadata",
    ]
    resources = data.aws_prometheus_workspaces.main.arns
  }
}

resource "aws_iam_role_policy" "rollouts" {
  name   = "query-amp"
  role   = aws_iam_role.workload["argo-rollouts"].id
  policy = data.aws_iam_policy_document.rollouts.json
}
