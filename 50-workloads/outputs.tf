# The role ARNs, for humans checking an association. The services never read them: Pod Identity
# resolves the role from the namespace and service account.

output "role_arns" {
  description = "IAM role per workload key."
  value       = { for k, r in aws_iam_role.workload : k => r.arn }
}

output "associations" {
  description = "namespace/service-account that receives each role."
  value       = { for k, w in local.workloads : k => "${w.namespace}/${w.service_account}" }
}
