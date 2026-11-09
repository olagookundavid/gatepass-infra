# AWS permissions of ExternalDNS: the in-cluster program that turns the host names of Ingress
# objects into DNS records.
#
# THE CHAIN. You write an Ingress with host api.<domain>. The load balancer controller builds the
# ALB (its name is random and changes every time the cluster is rebuilt). ExternalDNS watches
# the Ingresses, sees the host and the ALB address, and writes an ALIAS record api.<domain> ->
# the ALB into the Route 53 zone. After a `make down && make up` the ALB is new, ExternalDNS
# upserts the same record to point at it, and the stable name works again within about two
# minutes. Without it you would copy the new ALB name into DNS by hand every day.
#
# WHY IT IS SCOPED TO ONE ZONE (the course used the AWS-managed AmazonRoute53FullAccess policy,
# which lets a controller change EVERY zone in the account). The role may:
#   route53:ChangeResourceRecordSets      only in the hosted zone of 05-dns (zone ARN)
#   route53:ListHostedZones, ListResourceRecordSets, ListTagsForResources
#                                         read-only listing; AWS does not allow these to be
#                                         limited to one zone ("*"), they change nothing
# The zone is found by NAME (data source), the same convention as the other layers: 05-dns is
# persistent and applied once, this layer is rebuilt daily.
#
# ExternalDNS also writes a TXT "ownership" record next to each record it creates
# (heritage=external-dns, owner id = the cluster), so it only ever updates records it made.
#
# Related files: pod-identity.tf (role, trust, association: namespace external-dns, service
# account external-dns), 05-dns/zone.tf (the zone), gatepass-gitops/bootstrap/external-dns.yaml
# (the install).

data "aws_route53_zone" "this" {
  name         = "${var.domain}."
  private_zone = false
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid       = "ChangeRecordsInTheGatepassZoneOnly"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:${local.partition}:route53:::hostedzone/${data.aws_route53_zone.this.zone_id}"]
  }

  statement {
    sid    = "ListZonesAndRecords"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "write-gatepass-zone"
  role   = aws_iam_role.workload["external-dns"].id
  policy = data.aws_iam_policy_document.external_dns.json
}
