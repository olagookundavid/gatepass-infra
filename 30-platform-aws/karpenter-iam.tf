# The two IAM identities Karpenter needs: one for the controller (a pod) and one for the
# nodes it launches.
#
#   CONTROLLER ROLE   gatepass-dev-karpenter (pod-identity.tf). Taken by the Karpenter pod
#                     through Pod Identity. It may launch and terminate EC2 instances, create
#                     instance profiles, read the interruption queue and read pricing and AMI
#                     data. Split into six small policies, as upstream does, because one IAM
#                     managed policy is limited to 6144 characters.
#   NODE ROLE         gatepass-dev-karpenter-node. Taken by the EC2 instances Karpenter
#                     creates (the same four policies as the system node group's role in
#                     20-cluster, plus SSM so Session Manager works). Karpenter 1.x creates
#                     and deletes the INSTANCE PROFILE that wraps this role by itself: the
#                     EC2NodeClass in gatepass-gitops only names the role.
#
# The policies come from the upstream template for Karpenter v1.15.1
#   https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.15.1/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml
#   sha256 8ee49d6de4f2397797aea5c961706c90491a291b6a961268000cb2daadbd958f
# (the course installed Karpenter 1.8.2 with older, differently shaped policies). They were
# extracted into policies/*.json.tftpl with only the CloudFormation placeholders replaced by
# the Terraform variables below. Read them for the SCOPING: instances may only be launched,
# tagged and terminated when they carry the tags of THIS cluster and a Karpenter node pool,
# so a compromised Karpenter pod cannot touch the system nodes or other EC2 instances.
#
# ACCESS ENTRY: a node must be allowed to join the cluster. Managed node groups get this
# automatically (20-cluster/iam.tf says so); nodes Karpenter launches do not, so the node role
# gets an access entry of type EC2_LINUX here (EKS then maps it to the system:nodes group).
#
# Related files: pod-identity.tf (controller role, association), karpenter-queue.tf (the queue
# the controller reads), gatepass-gitops/platform/cluster-config/karpenter-*.yaml (the
# EC2NodeClass names the node role below).

locals {
  karpenter_node_role_name = "${local.name_prefix}-karpenter-node"

  karpenter_policy_vars = {
    partition     = local.partition
    region        = var.region
    account_id    = local.account_id
    cluster_name  = local.cluster_name
    node_role_arn = aws_iam_role.karpenter_node.arn
    queue_arn     = aws_sqs_queue.karpenter.arn
  }

  karpenter_policies = toset([
    "node-lifecycle",
    "iam-integration",
    "eks-integration",
    "interruption",
    "zonal-shift",
    "resource-discovery",
  ])
}

# ---- node role ------------------------------------------------------------------------------
data "aws_iam_policy_document" "karpenter_node_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = local.karpenter_node_role_name
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_trust.json
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = local.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# ---- controller role ------------------------------------------------------------------------
resource "aws_iam_policy" "karpenter" {
  for_each = local.karpenter_policies

  name        = "${local.name_prefix}-karpenter-${each.key}"
  description = "Karpenter controller (${each.key}); upstream policy for v1.15.1"
  policy      = templatefile("${path.module}/policies/karpenter-${each.key}.json.tftpl", local.karpenter_policy_vars)
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  for_each = local.karpenter_policies

  role       = aws_iam_role.workload["karpenter"].name
  policy_arn = aws_iam_policy.karpenter[each.key].arn
}
