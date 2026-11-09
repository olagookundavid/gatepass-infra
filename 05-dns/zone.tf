# THE HOSTED ZONE FOR THE SUBDOMAIN, plus a CAA record.
#
# WHAT THIS IS. A public Route 53 hosted zone answers DNS questions for ONE name and everything
# under it: here gatepass.<my-domain>. The parent domain (<my-domain>) stays in Cloudflare with
# its web site and its mail records. The two are joined by DELEGATION: in Cloudflare you add NS
# records named `gatepass` that list this zone's four name servers (outputs.tf prints them).
# From then on every resolver that looks up anything under gatepass.<my-domain> is sent to AWS.
# Nothing else in the parent domain is touched.
#
# WHY PERSISTENT (like 00-bootstrap and 60-observability). The four name servers are chosen by AWS
# when the zone is created. If the zone were destroyed every night, the next one would get
# different name servers and the NS records in Cloudflare would be wrong again; the certificate's
# validation records live in the zone too and must never disappear (ACM renews the certificate
# only while they exist). So the zone is made once and `make up` / `make down` never touch it.
# What changes daily are the RECORDS ExternalDNS writes for the load balancer (alias records), not
# the zone.
#
# FORCE_DESTROY IS FALSE: Terraform refuses to delete a zone that still holds records it does not
# own (ExternalDNS's alias and ownership TXT records). Deleting this layer on purpose means
# emptying the zone first.
#
# THE CAA RECORD says which certificate authorities may issue certificates for this name. We list
# the four names AWS documents for ACM (amazon.com, amazontrust.com, awstrust.com, amazonaws.com);
# anybody else asking another CA for a certificate for gatepass.<my-domain> is refused by that CA.
# The parent domain has no CAA records today (checked 2026-11-09), and CAA is looked up by walking
# up the name, so this record is the first one found. It is optional hardening: no CAA at all would
# also work.
#
# Related files: certificate.tf (the certificate for this name), outputs.tf (name servers, zone id),
# gatepass-infra/30-platform-aws/external-dns.tf (the role that may write records into this zone).

resource "aws_route53_zone" "this" {
  name          = var.domain
  comment       = "Gatepass ${var.environment}: delegated subdomain, records written by Terraform and ExternalDNS"
  force_destroy = false
}

resource "aws_route53_record" "caa" {
  zone_id = aws_route53_zone.this.zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 3600

  records = [
    "0 issue \"amazon.com\"",
    "0 issue \"amazontrust.com\"",
    "0 issue \"awstrust.com\"",
    "0 issue \"amazonaws.com\"",
    "0 issuewild \"amazon.com\"",
    "0 issuewild \"amazontrust.com\"",
    "0 issuewild \"awstrust.com\"",
    "0 issuewild \"amazonaws.com\"",
  ]
}
