# GITHUB ACTIONS TO AWS WITHOUT KEYS (OpenID Connect, "OIDC").
#
# WHY THIS EXISTS
#   CI has to push images to ECR and upload Lambda zips, so it needs AWS permissions. The
#   old way is to create an IAM user, generate an access key, and paste it into GitHub secrets.
#   That key never expires and is the classic way cloud accounts get breached. With OIDC there
#   is no stored secret at all:
#     1. A workflow run asks GitHub for a short-lived signed token ("I am workflow X of repo Y
#        on branch Z"). GitHub signs it; AWS can verify the signature.
#     2. The workflow sends that token to AWS STS: "let me assume role R".
#     3. AWS checks (a) the token really came from GitHub (the identity provider below) and
#        (b) the claims in it match the role's TRUST POLICY. If yes, it returns credentials
#        that last one hour.
#   So the security of the whole thing is in the trust policies below.
#
# THE CLAIMS THAT MATTER
#   aud ("audience"): who the token is meant for. Must be sts.amazonaws.com.
#   sub ("subject"):  who is asking, as text. For this repo it looks like
#       repo:<owner>@<owner-id>/gatepass-app@<repo-id>:ref:refs/heads/main   (a run on main)
#       repo:<owner>@<owner-id>/gatepass-app@<repo-id>:pull_request          (a run for a pull request)
#   IMMUTABLE SUBJECT (found 2026-11-07, first release run): repositories created recently use
#   GitHub's "immutable subject" claim, which adds the NUMERIC ids of the owner and the
#   repository. The old name-only form (repo:<owner>/gatepass-app:...) does not match, and AWS
#   answers "Not authorized to perform sts:AssumeRoleWithWebIdentity" (the release failed at
#   the login step). Check which form a repository uses with
#   `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` (use_immutable_subject).
#   The immutable form is also SAFER: names can be given up and re-registered by someone else
#   (rename, delete and re-create, transfer), numeric ids cannot, so a stranger who takes over
#   the old name cannot reuse our trust policy.
#   We compare sub with StringEquals (exact text), never with a wildcard. A loose rule such as
#   "repo:<owner>/*" would let any other repository, or a pull request, push images.
#
# HOW IT RELATES TO THE OTHER FILES
#   * ecr.tf and artifacts.tf: the permission policies below name those exact resources.
#   * kms.tf: the artifacts bucket is encrypted with the environment key, so uploads also need
#     permission to use that key.
#   * outputs.tf: publishes the role ARNs, which the workflows in gatepass-app will reference.
#   * The workflows themselves do not exist yet (Phase 4). The proof that this is right is
#     two runs then: a feature-branch run is DENIED the release role, a main-branch run is allowed.

locals {
  github_oidc_host = "token.actions.githubusercontent.com"
  app_repo         = "${var.github_owner}/${var.github_app_repo}"
  # The subject prefix in GitHub's immutable form: repo:<owner>@<owner-id>/<repo>@<repo-id>
  app_sub_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_app_repo}@${var.github_app_repo_id}"
}

# ---- The identity provider ------------------------------------------------------------------
# Tells this AWS account "tokens signed by GitHub's OIDC issuer are worth trusting for
# authentication". client_id_list is the expected audience. An account can have only ONE
# provider per URL (we checked: none exists yet). No thumbprint is set: current AWS validates
# GitHub's certificate itself, and the provider argument is optional.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# ---- Role 1: ci-pr (pull requests, read-only) -----------------------------------------------
# Used by workflows that run for pull requests. A PR can contain anybody's code, so this role
# can only LOOK: describe repositories and read scan results. It cannot push anything.
data "aws_iam_policy_document" "ci_pr_trust" {
  statement {
    sid     = "GitHubPullRequestsOfTheAppRepo"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = ["${local.app_sub_prefix}:pull_request"]
    }
  }
}

resource "aws_iam_role" "ci_pr" {
  name                 = "${local.name_prefix}-ci-pr"
  description          = "GitHub Actions, pull requests of the app repo: read-only access to ECR metadata"
  assume_role_policy   = data.aws_iam_policy_document.ci_pr_trust.json
  max_session_duration = 3600 # one hour is the minimum and plenty for a CI job
}

data "aws_iam_policy_document" "ci_pr" {
  statement {
    sid    = "ReadEcrMetadata"
    effect = "Allow"
    actions = [
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:ListImages",
    ]
    resources = [for repo in aws_ecr_repository.image : repo.arn]
  }
}

resource "aws_iam_role_policy" "ci_pr" {
  name   = "read-ecr-metadata"
  role   = aws_iam_role.ci_pr.id
  policy = data.aws_iam_policy_document.ci_pr.json
}

# ---- Role 2: ci-release (main branch only, can push) ----------------------------------------
# Used ONLY by workflows running on the main branch of the app repo, after code has been
# reviewed and merged. This is the role that can publish images and Lambda zips.
data "aws_iam_policy_document" "ci_release_trust" {
  statement {
    sid     = "GitHubMainBranchOfTheAppRepo"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = ["${local.app_sub_prefix}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "ci_release" {
  name                 = "${local.name_prefix}-ci-release"
  description          = "GitHub Actions, main branch of the app repo: push images to ECR and Lambda zips to the artifacts bucket"
  assume_role_policy   = data.aws_iam_policy_document.ci_release_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ci_release" {
  # ecr:GetAuthorizationToken is the "docker login" call. It is account-wide and AWS does not
  # allow it to be limited to a repository, so "*" is required here and ONLY here.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push (and read back, for layer reuse and signing) in the seven gatepass repositories only.
  statement {
    sid    = "EcrPushToGatepassRepositories"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = [for repo in aws_ecr_repository.image : repo.arn]
  }

  # Lambda zips go under the lambda/ prefix of the artifacts bucket and nowhere else.
  statement {
    sid       = "ArtifactsReadWriteLambdaPrefix"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/lambda/*"]
  }

  statement {
    sid       = "ArtifactsListLambdaPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["lambda/*"]
    }
  }

  # The bucket is encrypted with our KMS key, so writing and reading objects needs the key too.
  # The condition limits the permission to calls that come through S3, so this role cannot use
  # the key to encrypt or decrypt anything directly.
  statement {
    sid       = "ArtifactsEncryptionKeyViaS3Only"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.env.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ci_release" {
  name   = "push-images-and-lambda-zips"
  role   = aws_iam_role.ci_release.id
  policy = data.aws_iam_policy_document.ci_release.json
}
