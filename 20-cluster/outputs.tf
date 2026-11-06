# What the cluster layer publishes: for people (the Makefile and the walkthrough print them) and
# for the layers above, which look the cluster up by name, not through this state.

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.main.arn
}

output "cluster_security_group_id" {
  description = "The security group EKS created for the cluster (control plane and managed nodes). Karpenter and the load balancer controller are pointed at it in Phase 3."
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  description = "ARN of the IAM role of the system nodes."
  value       = aws_iam_role.node.arn
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster (adds a context called gatepass-dev)."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --alias ${aws_eks_cluster.main.name} --region ${var.region}"
}
