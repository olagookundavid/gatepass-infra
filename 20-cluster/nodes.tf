# The SYSTEM node group: a small, fixed set of on-demand EC2 machines that run the platform
# itself (CoreDNS now; Argo CD, the load balancer controller and Karpenter later).
#
# WHY A FIXED GROUP AND NOT ONLY KARPENTER. Karpenter (Phase 3) creates and removes nodes for
# workloads, but Karpenter is itself a pod: it needs a node to run on before it can create any
# other. The system group is that chicken-and-egg answer. It is on-demand (never Spot, which
# AWS can take back with two minutes' notice) and kept small. Everything else (the Gatepass
# services) runs on nodes Karpenter creates.
#
# THE TAINT. A taint repels pods unless they tolerate it. CriticalAddonsOnly=true:NoSchedule
# means only pods that say they tolerate it land here, so an ordinary workload can never fill
# the system nodes. Consequence for later phases: every platform chart we install before
# Karpenter exists (Argo CD in Phase 2, metrics-server, the controllers in Phase 3) must set a
# toleration for this taint and a nodeSelector for the label gatepass.io/pool=system.
# CoreDNS and the DaemonSet add-ons already tolerate it.
#
# THE LAUNCH TEMPLATE controls the machine itself:
#   * IMDSv2 required (http_tokens = "required") and hop limit 1: the instance metadata service
#     (where a machine reads its own credentials) can only be reached from the host, not from
#     inside a pod. A compromised pod cannot steal the node role's credentials this way.
#     Consequence: a pod that needs the region or VPC id must be given it explicitly (the load
#     balancer controller is, in Phase 3). Pod Identity does not use the metadata service.
#   * the root volume is gp3 and encrypted with the AWS-managed EBS key. A customer-managed
#     key would also need grants for the Auto Scaling service-linked role, or instances fail to
#     start; that extra step is skipped in dev (decision log).
#
# Nodes live in the PRIVATE subnets (three zones). Instance type, count and size are variables.
# The node group follows the cluster's Kubernetes version; AMI updates are a deliberate
# update of this resource (Phase 11 upgrade drill), never silent.
#
# Related files: iam.tf (node role), addons.tf (vpc-cni and kube-proxy are installed BEFORE the
# nodes so the nodes can become Ready), cluster.tf (the cluster they join).

resource "aws_launch_template" "system" {
  name_prefix = "${local.name_prefix}-system-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.system_node_disk_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.name_prefix}-system"
    }
  }

  # Replace the template (new version) instead of editing in place when it changes.
  update_default_version = true
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = data.aws_subnets.private.ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = var.system_instance_types

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  scaling_config {
    min_size     = var.system_nodes.min
    desired_size = var.system_nodes.desired
    max_size     = var.system_nodes.max
  }

  # During a node update, replace one node at a time.
  update_config {
    max_unavailable = 1
  }

  labels = {
    "gatepass.io/pool" = "system"
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  # The node role needs its policies, and the networking add-ons must exist, before a node can
  # become Ready. Without these dependencies the group is created but its nodes never join.
  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]
}
