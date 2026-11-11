# AWS permissions of the Kyverno ADMISSION and BACKGROUND controllers: read-only access to our ECR repositories.
#
# WHY IT NEEDS AWS AT ALL. The policy `gatepass-signed-images` (gatepass-gitops/platform/policies/
# signed-images.yaml) makes Kyverno check, when a Pod is created, that the image carries a cosign
# signature made by our release workflow. The signature is an OCI artifact stored in the SAME
# private ECR repository as the image (tag sha256-<digest>.sig), so Kyverno must be able to read
# the repository. It authenticates with the AWS default credential chain, which inside the pod
# is this Pod Identity role (the chart's registryClient already enables the `amazon` helper).
#
# LEAST PRIVILEGE. Pull-only, on the repositories under gatepass/ only:
#   ecr:GetAuthorizationToken   account-wide by design (a token is not tied to a repository;
#                               AWS allows only Resource "*" for this action)
#   ecr:BatchGetImage, ecr:GetDownloadUrlForLayer, ecr:BatchCheckLayerAvailability
#                               read manifests and layers (the signature is a tiny manifest)
# No push, no delete, no other repository. The REPORTS controller needs it too (it runs the background scans of
# the image-verification policy: found 2026-11-11, 401 in every report without it); the cleanup controller verifies no images and gets
# no role.
#
# Related files: pod-identity.tf (role, trust, association: namespace kyverno, service account
# kyverno-admission-controller); gatepass-gitops/bootstrap/kyverno.yaml (the install).

data "aws_iam_policy_document" "kyverno" {
  statement {
    sid       = "EcrToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPullGatepassRepositories"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [
      "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/gatepass/*",
    ]
  }
}

# The same read-only policy on both roles: admission (blocks at creation) and background (re-checks
# running pods and fills the policy reports). The reports and cleanup controllers verify nothing.
resource "aws_iam_role_policy" "kyverno" {
  for_each = toset(["kyverno", "kyverno-background", "kyverno-reports"])

  name   = "read-gatepass-ecr"
  role   = aws_iam_role.workload[each.key].id
  policy = data.aws_iam_policy_document.kyverno.json
}

# The policy was a single resource before the background controller got its own role; this keeps
# Terraform from deleting and re-creating the admission controller's permissions.
moved {
  from = aws_iam_role_policy.kyverno
  to   = aws_iam_role_policy.kyverno["kyverno"]
}
