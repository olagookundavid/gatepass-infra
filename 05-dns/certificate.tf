# THE TLS CERTIFICATE: one wildcard certificate for the whole subdomain, issued by ACM and
# validated through DNS records that Terraform writes into the zone.
#
# WHAT IT COVERS. `gatepass.<my-domain>` and `*.gatepass.<my-domain>`. A wildcard covers exactly
# one label: api.gatepass..., argocd.gatepass..., grafana.gatepass..., cdn.gatepass... all match;
# a.b.gatepass... does not. One certificate for every name we will ever put on the shared load
# balancer and on CloudFront means no per-service certificate work.
#
# HOW THE LOAD BALANCER FINDS IT. Nothing in Git names this certificate (its ARN contains the
# account id and the repository is public). The AWS Load Balancer Controller looks through ACM for
# a certificate whose names cover the Ingress host ("certificate discovery") and attaches it to the
# HTTPS listener. Conditions: the certificate must be ISSUED and in the same region (us-east-1).
#
# HOW VALIDATION WORKS. ACM asks us to prove that we control the name: it gives a CNAME record
# (name and value) that we must publish; ACM looks it up, finds it, issues the certificate.
# The apex name and the wildcard share ONE validation record (written twice, harmlessly, see the
# comment on the records below). The records are never removed: ACM checks
# them again at every renewal, about 60 days before expiry, and renews with no action from us.
#
# THE TWO-STEP APPLY (delegation_confirmed). ACM can only find the validation record if DNS for
# the subdomain really points at this zone, i.e. after the NS records exist in Cloudflare.
#   step 1: delegation_confirmed = false -> zone, CAA, certificate request, validation records.
#   (you add the NS records in Cloudflare; `dig NS <domain>` shows the four AWS servers)
#   step 2: delegation_confirmed = true  -> aws_acm_certificate_validation waits until ISSUED.
# Without the switch, step 1 would hang for up to 75 minutes and then fail.
#
# Related files: zone.tf (the zone the records go into), variables.tf (the switch), outputs.tf.

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  # ACM may need to replace the certificate for a change; create the new one first so the load
  # balancer never has a moment without a certificate.
  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # One entry per domain name on the certificate (the apex and the wildcard), keyed by DOMAIN NAME:
  # Terraform must know the keys of a for_each at plan time, and only the domain names are known
  # then (the record names and values are filled in by AWS once the certificate exists).
  validation_options = {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  }
}

# The apex name and its wildcard are validated by the SAME CNAME record, so the two entries below
# write the same record twice. allow_overwrite makes the second write an UPSERT instead of an
# "already exists" error.
resource "aws_route53_record" "validation" {
  for_each = local.validation_options

  zone_id         = aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = var.delegation_confirmed ? 1 : 0

  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]

  timeouts {
    create = "30m"
  }
}
