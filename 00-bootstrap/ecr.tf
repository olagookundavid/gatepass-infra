# YOU WRITE (task 2 of 3): container registries.
#
# GOAL
#   One private ECR repository per deployable image. The Dockerfile builds one image per binary
#   (ARG BINARY), and the contracts in gatepass-app/contracts/ list seven image binaries:
#   catalog-api, reservations-api, orders-api, orders-worker, orders-outbox-relay,
#   notifications-api, notifications-worker. The two Lambdas are zips in the artifacts bucket
#   (artifacts.tf), not images.
#
# CONSTRAINTS
#   * Name them gatepass/<binary> (the "/" makes a namespace in ECR). Create them with ONE
#     resource block and for_each over a set, not seven copies.
#   * Image tags are immutable: a tag, once pushed, can never point at another image. This is
#     what makes "sha-1a2b3c4" trustworthy in Git. (Also read the RESEARCH note below.)
#   * Scan on push: on.
#   * Encryption: KMS with the environment key from kms.tf, not the default AES256.
#   * Lifecycle policy per repo: keep the last 20 images, expire untagged ones after 1 day.
#     Think about what this could delete that you still need (hint: signatures and SBOMs are
#     stored in the same repository as extra images/tags - Phase 4 and 6).
#   * force_delete stays false: this is the persistent layer and images are not recreatable
#     from Terraform alone.
#
# HINTS
#   * aws_ecr_repository, aws_ecr_lifecycle_policy. jsonencode() builds the policy document.
#   * Expose the repository URLs as an output map so the CI and gitops code can use them.
#
# RESEARCH (answer in docs/notes/phase-00.md)
#   Plan change 10 warns that cosign signature tags (sha256-<digest>.sig) are pushed as new
#   tags in the same repository. With plain IMMUTABLE tags, can a CI re-run overwrite or fail on
#   them? Look in the ECR documentation for "tag immutability" and whether exclusion filters
#   exist for your provider version, and write down what you will do.
#
# ACCEPTANCE TEST
#   `aws ecr describe-repositories --query 'repositories[].[repositoryName,imageTagMutability,imageScanningConfiguration.scanOnPush]'`
#   shows seven repos, all immutable (or immutable-with-exclusions if you chose that), scan on.
#   `aws ecr get-lifecycle-policy --repository-name gatepass/catalog-api` returns your policy.
