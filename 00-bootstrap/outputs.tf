# Values other layers (and the gitops repo's values files, through a reviewed file) read.
output "kms_key_arn" {
  description = "ARN of the environment key."
  value       = aws_kms_key.env.arn
}

output "kms_key_alias" {
  description = "Alias of the environment key."
  value       = aws_kms_alias.env.name
}

output "artifacts_bucket" {
  description = "Bucket for Lambda zips."
  value       = aws_s3_bucket.artifacts.bucket
}

output "ecr_repository_urls" {
  description = "Repository URL per image binary, for the CI workflows and the gitops values."
  value       = { for name, repo in aws_ecr_repository.image : name => repo.repository_url }
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "ci_pr_role_arn" {
  description = "Role for pull-request workflows of the app repo (read-only)."
  value       = aws_iam_role.ci_pr.arn
}

output "ci_release_role_arn" {
  description = "Role for main-branch workflows of the app repo (push images and Lambda zips)."
  value       = aws_iam_role.ci_release.arn
}

output "cloudtrail_bucket" {
  description = "Bucket that receives the CloudTrail log files."
  value       = aws_s3_bucket.cloudtrail.bucket
}

output "cloudtrail_name" {
  description = "Name of the account's audit trail."
  value       = aws_cloudtrail.main.name
}
