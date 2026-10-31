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
