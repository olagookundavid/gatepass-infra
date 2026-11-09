# Values other layers and the humans need.
#
# name_servers is what you type into Cloudflare (four NS records named after the subdomain label).
# zone_id and certificate_arn are looked up by NAME by the other layers (data sources), not read
# from this layer's state, so they are printed here only for convenience.

output "zone_name" {
  description = "The delegated subdomain."
  value       = aws_route53_zone.this.name
}

output "zone_id" {
  description = "Route 53 hosted zone id (not secret; the ExternalDNS role is scoped to this zone)."
  value       = aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "Create one NS record per line in the parent zone (Cloudflare), named like the subdomain label, DNS only."
  value       = sort(aws_route53_zone.this.name_servers)
}

output "certificate_arn" {
  description = "ACM certificate (wildcard). Not referenced from Git; the load balancer controller discovers it."
  value       = aws_acm_certificate.this.arn
}

output "certificate_status" {
  description = "PENDING_VALIDATION until the delegation exists and step 2 has run, then ISSUED."
  value       = aws_acm_certificate.this.status
}
