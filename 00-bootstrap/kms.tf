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
# Later layers add resource-specific statements when a service principal needs the key
# (for example events.amazonaws.com for an encrypted queue); that is decided in Phase 7.
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
