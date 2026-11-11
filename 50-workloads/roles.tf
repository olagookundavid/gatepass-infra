# ONE IAM ROLE PER DEPLOYABLE, each tied to ONE Kubernetes service account by EKS Pod Identity.
#
# The idea of 30-platform-aws/pod-identity.tf, applied to the business services: a role per workload,
# so that the catalog pod cannot touch the orders queue and the orders worker cannot send mail. If one
# pod is compromised, its blast radius is its own role. What each role may do is in policies.tf and
# follows PLAN section 7 line by line.
#
# THE NAMING CONTRACT WITH GITOPS (Phase 8). An application directory apps/<name> in gatepass-gitops
# becomes the Argo CD application <name>, the service account <name> (the chart names it after the
# release) and runs in the namespace gatepass-<service>, where <service> is the directory name up to its
# first dash (platform/services/applicationset.yaml): ONE NAMESPACE PER SERVICE (decision 2026-11-10,
# before that every deployable had its own). Pod Identity binds a role to namespace AND service account,
# so the deployables of one namespace still get separate roles through their service accounts. The two
# migration Jobs use their own service accounts in the namespace of the service (so the migrate role can
# be broader than the runtime role, and only for the Job):
#
#   catalog                 catalog-api             namespace gatepass-catalog
#   catalog-migrate         `catalog-api migrate`   namespace gatepass-catalog,  SA catalog-migrate
#   reservations            reservations-api (HTTP)                    namespace gatepass-reservations
#   reservations-consumer   reservations-api, CONSUMER_ENABLED only   namespace gatepass-reservations
#   orders                  orders-api              namespace gatepass-orders
#   orders-migrate          `orders-api migrate`    namespace gatepass-orders,   SA orders-migrate
#   orders-worker           orders-worker           namespace gatepass-orders
#   orders-outbox-relay     orders-outbox-relay     namespace gatepass-orders
#   notifications           notifications-api       namespace gatepass-notifications
#   notifications-worker    notifications-worker    namespace gatepass-notifications
#   data-bootstrap          the database bootstrap Job (platform job, not a service)  namespace data-bootstrap
#
# Credentials are injected when a pod STARTS, so this layer must exist before the pods do (it is
# applied before 25-gitops-bootstrap). A pod whose service account has no association here gets no AWS
# access at all (and the metadata endpoint is closed to pods, 20-cluster / Karpenter node class).
#
# Related files: data.tf (what is looked up), policies.tf (the permissions), 40-data and 45-database
# (the resources).

locals {
  workloads = {
    catalog               = { namespace = "gatepass-catalog", service_account = "catalog" }
    catalog-migrate       = { namespace = "gatepass-catalog", service_account = "catalog-migrate" }
    reservations          = { namespace = "gatepass-reservations", service_account = "reservations" }
    reservations-consumer = { namespace = "gatepass-reservations", service_account = "reservations-consumer" }
    orders                = { namespace = "gatepass-orders", service_account = "orders" }
    orders-migrate        = { namespace = "gatepass-orders", service_account = "orders-migrate" }
    orders-worker         = { namespace = "gatepass-orders", service_account = "orders-worker" }
    orders-outbox-relay   = { namespace = "gatepass-orders", service_account = "orders-outbox-relay" }
    notifications         = { namespace = "gatepass-notifications", service_account = "notifications" }
    notifications-worker  = { namespace = "gatepass-notifications", service_account = "notifications-worker" }
    # Not a service: the Job that creates the database roles after every rebuild
    # (gatepass-gitops platform/data-bootstrap). Its role may read ONE secret, the master password.
    data-bootstrap = { namespace = "data-bootstrap", service_account = "data-bootstrap" }
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

resource "aws_eks_pod_identity_association" "workload" {
  for_each = local.workloads

  cluster_name    = local.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.workload[each.key].arn
}

resource "aws_iam_role_policy" "workload" {
  for_each = local.statements

  name   = "least-privilege"
  role   = aws_iam_role.workload[each.key].id
  policy = data.aws_iam_policy_document.workload[each.key].json
}
