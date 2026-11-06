# Pod Identity ASSOCIATIONS for the observability workloads (the collectors and Grafana).
#
# The two IAM roles are created in 60-observability, a PERSISTENT layer (the metrics workspace
# and the alert history must survive `make down`). An association needs the cluster, so it lives
# here, in the ephemeral layer that is rebuilt with the cluster. The roles are found by name; the
# names are the contract: gatepass-<env>-otel-collector and gatepass-<env>-grafana.
#
# If 60-observability has never been applied this layer fails at plan time with "no matching IAM
# Role", which is the right message: apply 60 first (once; it is not part of `make up`).
#
# Namespaces `observability` and `observability-node` and the service accounts `otel-collector` and `grafana` are what the
# Helm values in gatepass-gitops create (platform/otel-*/values.yaml, platform/grafana/values.yaml).
#
# Related files: pod-identity.tf (the same idea for the add-ons), 60-observability/pod-identity.tf.

# `role` is the IAM role (by name suffix) the association uses. The node agent runs in its own
# namespace (it needs host access, platform/observability/namespaces.yaml) but is a collector like
# the others, so it uses the same write-only role.
locals {
  observability_workloads = {
    otel-collector = { namespace = "observability", service_account = "otel-collector", role = "otel-collector" }
    otel-agent     = { namespace = "observability-node", service_account = "otel-collector", role = "otel-collector" }
    grafana        = { namespace = "observability", service_account = "grafana", role = "grafana" }
  }
}

data "aws_iam_role" "observability" {
  for_each = toset([for w in local.observability_workloads : w.role])

  name = "${local.name_prefix}-${each.key}"
}

resource "aws_eks_pod_identity_association" "observability" {
  for_each = local.observability_workloads

  cluster_name    = local.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = data.aws_iam_role.observability[each.value.role].arn
}
