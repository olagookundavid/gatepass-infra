# WHO MAY USE THE CLUSTER: an EKS access entry.
#
# An access entry links an AWS identity (an IAM user or role) to Kubernetes permissions. It
# replaces the old aws-auth ConfigMap. Two objects:
#   aws_eks_access_entry               "this IAM principal may authenticate to the cluster"
#   aws_eks_access_policy_association  "and it gets this AWS-managed Kubernetes permission set,
#                                       over this scope"
#
# AmazonEKSClusterAdminPolicy over the whole cluster is the equivalent of the Kubernetes
# cluster-admin role. It is given to ONE principal (var.admin_principal_arn, your IAM user),
# which is visible in code, in the AWS console and in CloudTrail. Production gives humans a
# role from IAM Identity Center and keeps day-to-day access read-only (the account has no
# Identity Center, so a user stays; it is on the list of dev shortcuts).
#
# Argo CD (Phase 2) and Terraform's Helm provider reach the cluster as this same principal.
#
# The nodes need no entry here: EKS creates the access entry for the node role by itself when
# the managed node group is created. Karpenter's node role will need one (Phase 3).
#
# Related files: cluster.tf (authentication_mode = "API" is what makes this the only way in).

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
