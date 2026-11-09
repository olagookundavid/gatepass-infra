# Lookups shared by the files of this layer: who and where we are, the key, the DNS zone, the
# certificate and the alerts topic. Everything is found BY NAME so that no layer reads another
# layer's state (the layers are applied independently and some are rebuilt every day).
#
# Related files: all of them. The zone and certificate come from 05-dns (apply step 2 first, or the
# certificate lookup below fails because it only accepts an ISSUED certificate), the key from
# 00-bootstrap, the alerts topic from 60-observability.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "gatepass-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
}

# The environment key (00-bootstrap/kms.tf): encrypts the tables, queues, buckets and secrets.
data "aws_kms_alias" "env" {
  name = "alias/${local.name_prefix}"
}

# The delegated zone and its wildcard certificate (05-dns).
data "aws_route53_zone" "this" {
  name         = "${var.domain}."
  private_zone = false
}

data "aws_acm_certificate" "wildcard" {
  domain      = var.domain
  statuses    = ["ISSUED"]
  most_recent = true
}

# The alarm topic (60-observability): the dead-letter queue and Lambda alarms publish to it.
data "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

# The artifacts bucket (00-bootstrap/artifacts.tf) that holds the Lambda zips.
data "aws_s3_bucket" "artifacts" {
  bucket = "${local.name_prefix}-artifacts-${local.account_id}-${var.region}"
}
