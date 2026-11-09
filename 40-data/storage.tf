# THREE S3 BUCKETS: event images, ticket files, nightly reports.
#
#   images    event pictures. The browser uploads straight to S3 with a PRESIGNED URL the catalog
#             service hands out (the service signs it locally; the image bytes never pass through
#             the pod), and visitors read them through CloudFront (cdn.tf), never from S3 directly.
#             Encrypted with S3's own keys (SSE-S3), not our key: CloudFront reads the bucket with an
#             origin access control, and keeping the key out of that path avoids giving the CDN
#             decrypt rights (PLAN decision, Go review C1).
#   tickets   generated ticket files (a QR code image) written by the notifications worker and
#             handed out as short-lived presigned download links. SSE-KMS with our key; objects expire
#             after 30 days.
#   reports   the nightly sales CSV written by the report Lambda. SSE-KMS, versioned.
#
# THE SAME HARDENING ON ALL THREE (the recipe of 00-bootstrap/artifacts.tf):
#   public access blocked on every axis       a bucket is never public; CloudFront is the only reader
#                                             of images, by an identity-based rule below.
#   BucketOwnerEnforced                       no per-object ACLs, the bucket policy and IAM decide.
#   a policy that denies non-TLS requests     aws:SecureTransport = false is refused.
#   abort of incomplete multipart uploads     half-uploaded parts are billed until removed.
# force_destroy is on in dev so `terraform destroy` can delete a non-empty bucket; production keeps
# data buckets without it.
#
# Related files: cdn.tf (the distribution and the read rule on images), config.tf (names),
# 50-workloads (which service may do what on which prefix).

locals {
  buckets = {
    images  = { sse = "AES256", versioned = false, expire_days = 0 }
    tickets = { sse = "aws:kms", versioned = false, expire_days = 30 }
    reports = { sse = "aws:kms", versioned = true, expire_days = 0 }
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = "${local.name_prefix}-${each.key}-${local.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket                  = aws_s3_bucket.this[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = { for k, v in local.buckets : k => v if v.versioned }

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    bucket_key_enabled = each.value.sse == "aws:kms"

    apply_server_side_encryption_by_default {
      sse_algorithm     = each.value.sse
      kms_master_key_id = each.value.sse == "aws:kms" ? data.aws_kms_alias.env.target_key_arn : null
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  dynamic "rule" {
    for_each = each.value.expire_days > 0 ? [1] : []

    content {
      id     = "expire-objects"
      status = "Enabled"

      filter {}

      expiration {
        days = each.value.expire_days
      }
    }
  }

  dynamic "rule" {
    for_each = each.value.versioned ? [1] : []

    content {
      id     = "expire-old-versions"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = 30
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# Browser uploads: a presigned PUT from the web app's address (and a local development address).
resource "aws_s3_bucket_cors_configuration" "images" {
  bucket = aws_s3_bucket.this["images"].id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = ["https://app.${var.domain}", "http://localhost:3000"]
    allowed_headers = ["Content-Type", "Content-Length"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

data "aws_iam_policy_document" "tls_only" {
  for_each = local.buckets

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this[each.key].arn, "${aws_s3_bucket.this[each.key].arn}/*"]

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

resource "aws_s3_bucket_policy" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id
  # images: the TLS rule plus the CloudFront read rule (cdn.tf); the others: the TLS rule only.
  policy = each.key == "images" ? data.aws_iam_policy_document.images.json : data.aws_iam_policy_document.tls_only[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
