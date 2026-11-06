# What the platform AWS layer publishes, for people (the walkthrough prints them) and for
# checks. Nothing here is a secret. Other layers look things up by name, not through this
# state, so these outputs are documentation of the names gatepass-gitops must agree with.

output "karpenter_node_role_name" {
  description = "Name of the IAM role of nodes launched by Karpenter: the `role` in the EC2NodeClass (gatepass-gitops/platform/cluster-config/karpenter-nodeclass.yaml)."
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_interruption_queue_name" {
  description = "Name of the SQS queue Karpenter polls: `settings.interruptionQueue` in gatepass-gitops/platform/karpenter/values.yaml."
  value       = aws_sqs_queue.karpenter.name
}

output "waf_web_acl_name" {
  description = "Name of the WAF web ACL: `wafv2AclName` in gatepass-gitops/platform/cluster-config/ingressclass-alb.yaml."
  value       = aws_wafv2_web_acl.main.name
}

output "pod_identities" {
  description = "Which service account gets which role (must equal the Helm values in gatepass-gitops)."
  value = {
    for k, v in local.workloads : k => "${v.namespace}/${v.service_account} -> ${aws_iam_role.workload[k].name}"
  }
}

output "cluster_arn" {
  description = "ARN of the cluster this layer's associations belong to (a lookup, shown so a wrong cluster is obvious)."
  value       = data.aws_eks_cluster.main.arn
}
