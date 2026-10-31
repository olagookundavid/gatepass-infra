# YOU WRITE (task 4 of 4): account baseline - an audit trail.
#
# GOAL
#   Be able to answer "who did what, when, from where" for the AWS account. CloudTrail records
#   every API call (a console click, a Terraform apply, an assumed role). Without a trail you
#   only get the 90-day event history in the console, which is not searchable in bulk and is
#   not kept in your own bucket.
#
# CONSTRAINTS
#   * One trail, management events only, all regions or the home region (decide and say why).
#   * Delivered to a NEW dedicated S3 bucket with the same hardening as artifacts.tf
#     (public access blocked, versioning, KMS encryption, TLS only), plus the bucket policy
#     CloudTrail needs in order to write there (look up the exact statements).
#   * Log file validation on (it makes tampering detectable).
#   * Encrypt the logs with the environment key: the key policy in kms.tf must then allow
#     cloudtrail.amazonaws.com to use it. Work out why, and where that statement goes.
#   * Lifecycle: expire logs after a period you choose, to keep the bucket small.
#
# HINTS
#   * Resource types: aws_cloudtrail, aws_s3_bucket (+ the same companions as artifacts.tf),
#     aws_s3_bucket_policy, data "aws_iam_policy_document".
#   * Check the Free plan first (read-only): `aws cloudtrail describe-trails`. The first copy of
#     management events is free; additional trails and data events are not (verify on the
#     CloudTrail pricing page before adding more).
#   * GuardDuty (threat detection) is optional: `aws guardduty list-detectors` (read-only) tells
#     you whether the service answers; it has a free trial, check the terms before enabling.
#
# ACCEPTANCE TEST
#   1. `aws cloudtrail get-trail-status --name <trail>` shows IsLogging true.
#   2. Within about 15 minutes of an API call a log object appears under AWSLogs/ in the bucket.
#   3. `aws cloudtrail validate-logs` (read the CLI help) reports the digest files as valid.
