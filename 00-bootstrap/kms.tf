# One customer-managed KMS key per environment (plan rule 7: encryption at rest everywhere).
#
# WHY a customer-managed key (CMK) and not the AWS-managed ones (alias/aws/...):
#   * we own the key policy, so we decide who may use it;
#   * we can see every use in CloudTrail and disable the key in an emergency;
#   * AWS-managed keys cannot be shared across accounts.
# Cost: about $1 per month per key plus a small charge per request. One key for the whole
# environment keeps it cheap; production often uses one key per data class.
#
# THE KEY POLICY. A KMS key has no access at all unless its policy grants it (unlike most AWS
# resources, IAM alone is not enough). The statement below is the standard one: it allows the
# account's root principal, which in KMS means "let IAM policies in this account grant access
# to this key". After that, who may use the key is controlled with ordinary IAM policies on
# roles (EKS cluster role, Pod Identity roles, CI roles), which is what we want.
# It does NOT give everyone in the account access: a principal still needs an IAM policy that
# allows the kms:* action on this key.
#
# Service principals (AWS services acting on their own, such as CloudTrail) need their own
# statements, added below as they appear. Later layers may add more, for example
# events.amazonaws.com for an encrypted queue; that is decided in Phase 7.
data "aws_iam_policy_document" "kms_env" {
  statement {
    sid       = "EnableIamPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudTrail (baseline.tf) encrypts every log file with this key. A service principal is not
  # an IAM user or role in our account, so the "root" statement above does not cover it: the
  # key policy must name it. Two guards keep the permission narrow:
  #   * aws:SourceArn: only OUR trail may ask (prevents the "confused deputy" problem, where
  #     another account's trail tricks the service into using our key);
  #   * the encryption context must name a trail of this account.
  # The trail ARN is a TEXT value (local.trail_arn), not a reference to the trail resource,
  # because the trail already depends on this key and a reference would be circular.
  statement {
    sid       = "AllowCloudTrailToEncryptLogs"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*"]
    }
  }

  # CloudWatch Logs (added with Phase 1): the VPC flow-log group (10-network) and the EKS
  # control-plane log group (20-cluster) are encrypted with this key. The Logs service must be
  # allowed to use it, for log groups of THIS account and region only (the encryption context
  # names the log group; the condition pins the account). Without this statement, creating a
  # log group with kms_key_id fails with "The specified KMS key does not exist or is not
  # allowed to be used with LogGroup".
  statement {
    sid       = "AllowCloudWatchLogs"
    effect    = "Allow"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:*"]
    }
  }

  statement {
    sid       = "AllowCloudTrailToDescribeTheKey"
    effect    = "Allow"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "env" {
  description = "${local.name_prefix} general purpose key (EKS secrets, S3, SQS, logs)"

  # Automatic yearly rotation of the key material. Old material stays available for decryption,
  # so nothing has to be re-encrypted.
  enable_key_rotation = true

  # Deleting a key is irreversible and makes everything encrypted with it unreadable, so AWS
  # enforces a waiting period (7-30 days) during which the deletion can be cancelled.
  # 7 days is the shortest allowed, chosen because this is a learning project.
  deletion_window_in_days = 7

  policy = data.aws_iam_policy_document.kms_env.json
}

# The alias is the stable, human-readable name that code and policies refer to; the key id is
# a random UUID. Pointing the alias at a new key later is how a key is replaced without
# changing consumers.
resource "aws_kms_alias" "env" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.env.key_id
}
