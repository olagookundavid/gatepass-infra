# The two IAM roles every EKS cluster needs. A ROLE is an identity that an AWS service (not a
# person) takes on; the "trust policy" says WHICH service may take it, the attached policies
# say what it may then do.
#
#   cluster role   taken by the EKS control plane itself, to create network interfaces in our
#                  subnets, manage load balancer security groups, and use our KMS key.
#   node role      taken by the EC2 worker nodes (the kubelet on each node), to join the
#                  cluster, pull images from ECR and configure pod networking.
#
# Pods do NOT use the node role for their own AWS access: each workload gets its own narrow
# role through EKS Pod Identity (later phases). Keeping the node role small matters because
# every pod on a node could otherwise reach its permissions.
#
# DEV SHORTCUT: the VPC CNI plugin (pod networking) gets its AWS permissions through the node
# role (AmazonEKS_CNI_Policy below). Production gives the aws-node service account its own role
# through Pod Identity so the node role stays minimal; see the decision log.
#
# Related files: cluster.tf uses the cluster role; nodes.tf uses the node role; access.tf does
# NOT need an entry for the node role (EKS creates it for managed node groups).

# ---- cluster role ---------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name_prefix}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Secrets encryption: EKS encrypts every Kubernetes Secret with our key. The key policy in
# 00-bootstrap delegates to IAM ("EnableIamPolicies"), so the cluster role needs its own IAM
# permission on THAT key (and only that key).
data "aws_iam_policy_document" "cluster_kms" {
  statement {
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ListGrants",
      "kms:DescribeKey",
    ]
    resources = [data.aws_kms_alias.env.target_key_arn]
  }
}

resource "aws_iam_role_policy" "cluster_kms" {
  name   = "use-env-key-for-secrets"
  role   = aws_iam_role.cluster.id
  policy = data.aws_iam_policy_document.cluster_kms.json
}

# ---- node role ------------------------------------------------------------------------------
data "aws_iam_policy_document" "node_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name_prefix}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_trust.json
}

# Four AWS-managed policies, each with one job:
#   AmazonEKSWorkerNodePolicy            join the cluster, describe the instance's own network
#   AmazonEC2ContainerRegistryPullOnly   pull images from ECR (read-only; the older ...ReadOnly
#                                        policy also allows listing and describing)
#   AmazonEKS_CNI_Policy                 let the VPC CNI attach addresses to nodes (dev shortcut)
#   AmazonSSMManagedInstanceCore         reach a node through AWS Systems Manager Session
#                                        Manager when debugging, so there are no SSH keys and
#                                        no port 22 anywhere
locals {
  node_policies = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonEKS_CNI_Policy",
    "AmazonSSMManagedInstanceCore",
  ])
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = local.node_policies

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.key}"
}
