# AWS permissions of the Kyverno ADMISSION controller: read-only access to our ECR repositories.
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
# No push, no delete, no other repository. The background and reports controllers do not verify
# images and get no role.
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

resource "aws_iam_role_policy" "kyverno" {
  name   = "read-gatepass-ecr"
  role   = aws_iam_role.workload["kyverno"].id
  policy = data.aws_iam_policy_document.kyverno.json
}
