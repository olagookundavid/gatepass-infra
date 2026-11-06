# The four EKS managed add-ons, each at a pinned version.
#
# An ADD-ON is software AWS packages, installs into the cluster and keeps patched for us. Without
# them a cluster has no pod networking, no service routing and no DNS. Because
# bootstrap_self_managed_addons = false (cluster.tf), nothing is installed by default and every
# one is listed here: the cluster is exactly what the code says.
#
#   vpc-cni                 pod networking: gives every pod a real address from the private
#                           subnet. Configured with enableNetworkPolicy = "true", which turns
#                           on the built-in network-policy agent, so Kubernetes NetworkPolicy
#                           objects (Phase 6) are enforced.  Installed BEFORE the nodes.
#   kube-proxy              routes traffic for Kubernetes Services on each node.
#                           Installed BEFORE the nodes.
#   coredns                 cluster DNS (names like orders-api.gatepass.svc). It is a
#                           Deployment, so it needs nodes: installed AFTER the node group.
#   eks-pod-identity-agent  hands out per-pod AWS credentials (EKS Pod Identity). A DaemonSet;
#                           installed AFTER the node group.
#
# PINNED VERSIONS (var.addon_versions): left unset, "latest compatible" is installed and an
# unchanged config can behave differently after a rebuild. The values are the AWS defaults for
# Kubernetes 1.36 on the day of writing; upgrade them on purpose, with the cluster.
#
# resolve_conflicts: OVERWRITE on create lets EKS replace anything already present with its own
# configuration. PRESERVE on update keeps settings we changed by hand in the cluster instead of
# silently reverting them (we change none; this is the safe default).
#
# VERIFIED on the first apply (2026-11-04): vpc-cni and kube-proxy reach ACTIVE in seconds while
# there are no nodes yet (their DaemonSets then have zero pods to wait for), so the order above
# works in a single apply.
#
# Related files: nodes.tf (ordering), cluster.tf (bootstrap_self_managed_addons).

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "vpc-cni"
  addon_version = var.addon_versions["vpc-cni"]

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "kube-proxy"
  addon_version = var.addon_versions["kube-proxy"]

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "coredns"
  addon_version = var.addon_versions["coredns"]

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = var.addon_versions["eks-pod-identity-agent"]

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.system]
}
