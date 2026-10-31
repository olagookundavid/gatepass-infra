# YOU WRITE (task 3 of 3): GitHub Actions to AWS without keys (OIDC).
#
# GOAL
#   GitHub's workflow runner proves who it is with a short-lived signed token (OIDC). AWS
#   trusts GitHub as an identity provider and lets only specific workflows assume specific
#   roles. No AWS access key is ever stored in GitHub. This is the single most security-relevant
#   file in the layer: a loose trust policy lets any fork or branch push images.
#
# WHAT TO BUILD
#   1. The IAM OIDC identity provider for https://token.actions.githubusercontent.com with the
#      client id (audience) sts.amazonaws.com. This account has none yet (checked 2026-10-30).
#      An account can have only ONE provider per URL.
#   2. Role "ci-pr": assumed by pull-request workflows of gatepass-app. Read-only: it may
#      describe ECR repositories/images (to look at scan results) and nothing else.
#   3. Role "ci-release": assumed ONLY by workflows running on the main branch of gatepass-app.
#      It may log in to ECR and push images to the seven gatepass/* repositories, put objects
#      under lambda/ in the artifacts bucket, and use the environment KMS key for those two
#      things. Nothing else.
#
# CONSTRAINTS (the learning is in these)
#   * The trust policy must check BOTH the audience (aud) and the subject (sub) claims, with
#     StringEquals, never StringLike with a wildcard.
#       - ci-release sub: repo:<owner>/gatepass-app:ref:refs/heads/main
#       - ci-pr sub:      repo:<owner>/gatepass-app:pull_request
#   * Permissions use exact ARNs. One action (ecr:GetAuthorizationToken) cannot be scoped to
#     a resource and needs "*"; know which one it is and say so in a comment.
#   * Set a maximum session duration (one hour is plenty) and give the roles a clear path/name
#     prefix such as gatepass-dev-ci-release.
#   * Owner and repo name come from variables (var.github_owner exists), not literals.
#
# HINTS
#   * Resource types: aws_iam_openid_connect_provider, aws_iam_role, aws_iam_role_policy,
#     data "aws_iam_policy_document".
#   * Find the exact claim names GitHub puts in the token in GitHub's documentation page
#     "OpenID Connect" under Security hardening for GitHub Actions ("Configuring OpenID Connect
#     in Amazon Web Services").
#   * Whether the provider resource still needs a thumbprint list: look it up in the provider
#     docs for your version (unverified here).
#
# ACCEPTANCE TEST
#   1. `terraform plan` clean after apply.
#   2. `aws iam get-role --role-name gatepass-dev-ci-release --query Role.AssumeRolePolicyDocument`
#      contains no "*" anywhere in a Condition.
#   3. In Phase 4 the real proof: a workflow on a feature branch tries to assume ci-release and
#      is DENIED; the same workflow on main succeeds.
