# ACCOUNT BASELINE: an audit trail of every API call (AWS CloudTrail).
#
# WHY THIS EXISTS
#   Every action in AWS (a console click, a Terraform apply, a pod assuming a role) is an API
#   call. CloudTrail records them. Without a trail you can only see the last 90 days in the
#   console, you cannot search them in bulk, and you have no copy of your own. With a trail the
#   question "who deleted this, when, from which IP, using which role" always has an answer,
#   which is the first thing needed after any security incident or "what broke?" investigation.
#
# WHAT IS RECORDED AND WHAT IS NOT
#   Management events only (creating, changing, deleting resources; sign-ins). Data events (every
#   S3 object read, every Lambda invoke) are NOT recorded: they are very high volume and are
#   billed per event. The first copy of management events is free (verify on the CloudTrail
#   pricing page); this bucket and the key requests cost pennies.
#
# HOW IT RELATES TO THE OTHER FILES
#   * Same hardening recipe as artifacts.tf (public access blocked, versioning, KMS encryption,
#     TLS only), repeated for a second bucket because logs and build artifacts have different
#     owners, retention and readers.
#   * kms.tf: CloudTrail encrypts each log file with the environment key. For that, the key
#     policy has a statement that lets the CloudTrail service use the key. That statement names
#     the trail by its ARN WRITTEN AS TEXT (local.trail_arn) instead of pointing at the trail
#     resource, otherwise key -> trail -> key would be a circular dependency.
#   * Persistent: the trail keeps recording between sessions.
#
# DELIBERATELY NOT HERE: GuardDuty (threat detection). It belongs with the security baseline
# (Phase 6, walkthrough 07) because it is most useful together with EKS protection.

locals {
  trail_name = "${local.name_prefix}-trail"
  # Built as text on purpose (see above). The format is fixed by AWS.
  trail_arn = "arn:${local.partition}:cloudtrail:${var.region}:${local.account_id}:trail/${local.trail_name}"
}

# ---- The log bucket (same recipe as artifacts.tf) -------------------------------------------
resource "aws_s3_bucket" "cloudtrail" {
  bucket = "${local.name_prefix}-cloudtrail-${local.account_id}-${var.region}"
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.env.arn
    }
    bucket_key_enabled = true
  }
}

# Logs are only useful for a while in a learning project: delete them after 90 days so the
# bucket does not grow without bound. (A real company keeps them for a year or more, often
# in a separate security account that nobody in the workload account can delete from.)
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  depends_on = [aws_s3_bucket_versioning.cloudtrail]

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# THE BUCKET POLICY CLOUDTRAIL NEEDS. A service cannot write into your bucket unless the bucket
# says so. The two CloudTrail statements follow the pattern in the CloudTrail documentation
# ("Amazon S3 bucket policy for CloudTrail"): the service may read the bucket's ACL, and may
# put objects only under AWSLogs/<account-id>/, and only on behalf of OUR trail (the
# aws:SourceArn condition stops another account's trail from writing here: the "confused deputy"
# problem). The third statement is the same TLS-only rule as in artifacts.tf.
data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

# ---- The trail itself ------------------------------------------------------------------------
resource "aws_cloudtrail" "main" {
  name           = local.trail_name
  s3_bucket_name = aws_s3_bucket.cloudtrail.id

  # One trail that covers every region (an attacker or a mistake in another region is still
  # recorded) and also the global services (IAM, STS, CloudFront) that are not tied to a region.
  is_multi_region_trail         = true
  include_global_service_events = true

  # Adds a signed "digest" file every hour listing the hash of each log file written. Anyone
  # can later check with `aws cloudtrail validate-logs` that no log file was changed or deleted:
  # evidence that holds up after an incident.
  enable_log_file_validation = true

  # Encrypt log files with the environment key (the key policy in kms.tf allows this).
  kms_key_id = aws_kms_key.env.arn

  # The bucket must accept CloudTrail's writes before the trail is created, otherwise creation
  # fails with "Incorrect S3 bucket policy".
  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
