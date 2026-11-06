# Remote state in S3 (the course's shared state bucket, new key per layer).
#
# The block is intentionally EMPTY ("partial configuration"): the bucket name, key and region
# live in backend.hcl, which is git-ignored. Reasons:
#   * this repository is public and we do not publish the bucket name;
#   * the same code can point at another bucket (a different account) without a code change.
#
#   terraform init -backend-config=backend.hcl
#
# See backend.hcl.example for the values. `use_lockfile = true` is S3-native locking: Terraform
# writes a .tflock object next to the state, so no DynamoDB lock table is needed (the course
# README that mentions DynamoDB locking is outdated).
terraform {
  backend "s3" {}
}
