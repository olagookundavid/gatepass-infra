# S3 bucket for build artifacts that are not container images: the two Lambda zips
# (bootstrap.zip per commit SHA). Container images go to ECR instead (ecr.tf).
#
# Everything here is a baseline every S3 bucket in this project follows:
#   1. Block Public Access on: no ACL or policy can make the bucket public.
#   2. Versioning on: an overwritten or deleted object is recoverable (also lets Terraform
#      reference an exact zip version).
#   3. Default encryption with our KMS key (bucket key on, which cuts KMS request cost).
#   4. TLS only: a bucket policy denies any request that is not HTTPS.
#   5. Old versions expire, so versioning does not grow forever.
#
# This bucket belongs to the persistent layer: it costs cents and CI needs it every day.
resource "aws_s3_bucket" "artifacts" {
  # Bucket names are global across all AWS accounts; account id + region makes ours unique
  # without a random suffix.
  bucket = "${local.name_prefix}-artifacts-${local.account_id}-${var.region}"
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.env.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  # Versioning must exist before a noncurrent-version rule makes sense.
  depends_on = [aws_s3_bucket_versioning.artifacts]

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    # An empty filter means "all objects".
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "artifacts_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

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

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_tls_only.json

  # Apply the public-access block first so the two never race.
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}
