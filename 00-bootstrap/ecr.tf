# CONTAINER REGISTRIES: one private ECR repository per deployable image.
#
# WHY THIS EXISTS
#   Kubernetes runs container images, and images have to live in a registry that the cluster's
#   nodes can pull from. ECR is AWS's registry: nodes authenticate with their IAM role, so no
#   registry password is ever stored anywhere. CI (the ci-release role in github_oidc.tf) pushes
#   here; the cluster pulls from here.
#
# WHY SEVEN REPOSITORIES
#   The Dockerfile builds one image per binary (ARG BINARY), and the deploy contracts in
#   gatepass-app list seven image binaries. orders has three binaries (api, worker, outbox
#   relay) and notifications two, because each scales and fails independently. The two Lambda
#   functions are zip files in the artifacts bucket (artifacts.tf), not images.
#
# HOW IT RELATES TO THE OTHER FILES
#   * kms.tf: repositories are encrypted with the environment key.
#   * github_oidc.tf: its IAM policies list exactly these repository ARNs, nothing broader.
#   * outputs.tf: publishes the repository URLs for the CI and gitops code.
#   * Persistent layer: images cannot be recreated by Terraform alone, so `make down` leaves
#     this file's resources in place and force_delete stays false.

locals {
  # The image names (= the Docker build argument BINARY). A set, so for_each can create one
  # repository per element from a single resource block.
  image_binaries = toset([
    "catalog-api",
    "reservations-api",
    "orders-api",
    "orders-worker",
    "orders-outbox-relay",
    "notifications-api",
    "notifications-worker",
  ])
}

resource "aws_ecr_repository" "image" {
  for_each = local.image_binaries

  # "gatepass/" makes a namespace, so the images read gatepass/catalog-api, gatepass/orders-api...
  name = "gatepass/${each.key}"

  # TAG IMMUTABILITY: once a tag such as "sha-1a2b3c4" is pushed it can never be pointed at a
  # different image. That makes a tag in Git trustworthy ("this commit is that image"). We still
  # deploy by DIGEST (the sha256 of the image), which cannot change at all.
  # The exclusion: tools like cosign store signatures and SBOMs in the same repository under
  # tags that start with "sha256-" (for example sha256-<digest>.sig). Re-running a signing job
  # rewrites such a tag, which strict immutability would reject, so those tags alone stay
  # mutable. A mutable signature TAG is safe because verification checks the cryptographic
  # signature, not the tag.
  # UNVERIFIED until the first apply: the filter syntax (WILDCARD) and that ECR accepts this
  # combination on this account; the plan only validates the provider schema.
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  # Basic vulnerability scan every time an image is pushed (results appear on the image).
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encrypt images at rest with our customer-managed key instead of the default AES256 key.
  # UNVERIFIED: whether the pushing role needs any extra KMS permission (ECR normally uses a
  # grant, so the push policy in github_oidc.tf has none); the first CI push will show it.
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.env.arn
  }

  # Never let a destroy delete a repository that still contains images.
  force_delete = false
}

# LIFECYCLE POLICY: without one, every build is stored (and billed) forever.
# Rules are evaluated by priority; the catch-all "any" rule must come last.
#   1. Untagged images (left behind when a tag moves) expire after 1 day.
#   2. Keep the newest 45 images. Each release pushes about three objects (the image, its
#      signature and its SBOM), so 45 is roughly the last 15 releases. If this number were too
#      small, cleanup could delete an image that is still deployed.
resource "aws_ecr_lifecycle_policy" "image" {
  for_each = aws_ecr_repository.image

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the newest 45 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 45
        }
        action = { type = "expire" }
      },
    ]
  })
}
