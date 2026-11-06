# The EBS CSI driver: what lets Kubernetes create an EBS disk when a PersistentVolumeClaim
# asks for storage (Prometheus and Grafana in Phase 5, any database-in-a-pod later).
#
# A fresh EKS cluster has NO working storage: the built-in `gp2` StorageClass uses the old
# in-tree provisioner, which current Kubernetes no longer ships. Without this add-on a PVC
# stays Pending forever. The StorageClass `gp3` in gatepass-gitops (cluster-config) uses it.
#
# It is an EKS MANAGED ADD-ON like the four in 20-cluster (AWS packages and patches it), but
# it lives in THIS layer because it needs an IAM role: the role comes from pod-identity.tf
# (key `ebs-csi`) and the managed policy below. Pod Identity gives the controller pods
# (service account ebs-csi-controller-sa in kube-system) that role; the node role is not used.
#
# UNVERIFIED (check on the first apply): the add-on's controller must tolerate the
# CriticalAddonsOnly taint of the system nodes, otherwise its pods stay Pending (we have no
# other nodes until Karpenter exists). The documented default tolerates it; if not, add
# configuration_values with a `controller.tolerations` entry and say so in the decision log.
# Check: kubectl -n kube-system get pods -l app=ebs-csi-controller.
#
# Related files: pod-identity.tf (role + association), gatepass-gitops/platform/cluster-config/
# storageclass-gp3.yaml.

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.workload["ebs-csi"].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = local.cluster_name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.ebs_csi_addon_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  # The association must exist before the controller pods start, or they start without
  # credentials and need a restart.
  depends_on = [aws_eks_pod_identity_association.workload]
}
