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
# Related files: lbc.tf, karpenter-iam.tf, external-secrets.tf, ebs-csi.tf, kyverno.tf (the permissions);
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
    # Phase 6: the Kyverno admission controller reads ECR to verify image signatures.
    kyverno = {
      namespace       = "kyverno"
      service_account = "kyverno-admission-controller"
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
