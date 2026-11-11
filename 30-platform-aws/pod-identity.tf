# One IAM role per platform controller, each tied to ONE Kubernetes service account through
# EKS Pod Identity.
#
# HOW POD IDENTITY WORKS (the 2-minute version)
#   1. The role's trust policy names the service `pods.eks.amazonaws.com` as the only party
#      that may assume it (plus sts:TagSession, which Pod Identity uses to pass cluster, namespace
#      and service-account names as session tags).
#   2. An ASSOCIATION says: "pods running as service account X in namespace Y get role R".
#   3. The eks-pod-identity-agent DaemonSet (an add-on from 20-cluster) intercepts the AWS SDK's
#      credential request inside such a pod and answers with short-lived credentials for R.
# Nothing is written into the pod, no OIDC provider is involved, and the role does not mention
# the cluster, so the same role works after a cluster is rebuilt (the course's older IRSA
# method put the cluster's OIDC URL into every trust policy).
#
# The map below is the single list of "who runs where". The names MUST equal what the Helm
# charts create in gatepass-gitops (platform/<add-on>/values.yaml); if they differ the pod runs
# but AWS answers "no credentials". Each add-on's own .tf file attaches its permissions to
# aws_iam_role.workload[<key>].
#
# Related files: lbc.tf, karpenter-iam.tf, external-secrets.tf, ebs-csi.tf, kyverno.tf, external-dns.tf, keda.tf, rollouts.tf (the permissions);
# gatepass-gitops/platform/*/values.yaml and bootstrap/*.yaml (namespace and service account).

locals {
  workloads = {
    lbc = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
    karpenter = {
      namespace       = "kube-system"
      service_account = "karpenter"
    }
    external-secrets = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
    ebs-csi = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
    # Phase 6: the Kyverno admission controller reads ECR to verify image signatures, and the
    # background controller does the same when it re-checks pods that already exist (without a
    # role there the policy reports show ERROR 401 for every running pod, found 2026-11-07).
    kyverno = {
      namespace       = "kyverno"
      service_account = "kyverno-admission-controller"
    }
    kyverno-background = {
      namespace       = "kyverno"
      service_account = "kyverno-background-controller"
    }
    # Phase 6b: ExternalDNS writes the DNS records for Ingress hosts into the Route 53 zone of 05-dns.
    external-dns = {
      namespace       = "external-dns"
      service_account = "external-dns"
    }
    # Phase 9: KEDA's OPERATOR reads the length of the three queues to scale the workers (one role that
    # can read exactly those queues, instead of every worker's role reading its own: keda.tf).
    keda = {
      namespace       = "keda"
      service_account = "keda-operator"
    }
    # Phase 9: the Argo Rollouts controller queries the Prometheus workspace (AMP) during a canary
    # analysis (rollouts.tf).
    argo-rollouts = {
      namespace       = "argo-rollouts"
      service_account = "argo-rollouts"
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

resource "aws_eks_pod_identity_association" "workload" {
  for_each = local.workloads

  cluster_name    = local.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.workload[each.key].arn
}
