# ACCOUNT SECURITY SERVICES (Phase 6): IAM Access Analyzer.
# Persistent: it keeps working between sessions and costs nothing.
#
# IAM ACCESS ANALYZER (external access)
#    Continuously checks the resource policies in this account (S3 buckets, KMS keys, IAM role
#    trust policies, SQS queues, Secrets Manager secrets, ...) and raises a FINDING whenever one
#    lets a principal OUTSIDE the account (or the public) in. It is the safety net for the
#    classic mistake "a bucket policy or a role trust policy accidentally allows `*`". Our
#    OIDC roles for GitHub Actions are expected to appear as findings (trust of an external
#    identity provider, limited by the `sub` condition); anything else is worth reading.
#    The analyzer of type ACCOUNT is free (the paid kinds are unused access and internal access).
#
# DELIBERATELY NOT HERE: Amazon Inspector (enhanced ECR scanning). Checked read-only on
# 2026-11-07: `aws inspector2 batch-get-account-status` answers SubscriptionRequiredException on
# this account (same family as Managed Grafana), so it cannot be enabled on the Free plan. Image
# scanning is covered by ECR basic scan on push (ecr.tf) and Trivy in the pull-request pipeline
# (Phase 4). Production would enable Inspector enhanced scanning (continuous re-scan).
#
# Related: ecr.tf, walkthrough 07 section "Analysis services".

resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "${local.name_prefix}-external-access"
  type          = "ACCOUNT"
}
