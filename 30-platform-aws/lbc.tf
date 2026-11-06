# AWS permissions of the AWS Load Balancer Controller (LBC): the in-cluster program that
# turns a Kubernetes Ingress into a real Application Load Balancer (listeners, target groups,
# security group rules, the WAF attachment) and removes it again when the Ingress is deleted.
#
# THE POLICY is the one the project publishes for exactly this release, saved unchanged in
# policies/lbc-iam-policy.json:
#   https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.2/docs/install/iam_policy.json
#   sha256 16f232c9d9f79366fe949c4550ad517a202380058a9e48d45a4e215044a20a6a
# It is pinned to a release TAG and stored in this repository, unlike the course, which
# downloaded it from the `main` branch at apply time (whatever main said that day became our
# permissions). The chart version in gatepass-gitops (platform/aws-load-balancer-controller)
# is 3.6.2 for the same release: when you upgrade the chart, fetch the policy of the new tag
# and diff it against this file in the same pull request.
#
# The policy is broad on purpose: the controller creates and deletes load balancers,
# target groups and security groups, but it is scoped by TAGS in the policy itself (it may
# only change objects carrying its own `elbv2.k8s.aws/cluster` tag).
#
# Related files: pod-identity.tf (role, trust, association), waf.tf (the web ACL it attaches),
# gatepass-gitops/platform/aws-load-balancer-controller/values.yaml.

resource "aws_iam_policy" "lbc" {
  name        = "${local.name_prefix}-lbc"
  description = "AWS Load Balancer Controller ${local.name_prefix} (upstream policy v3.6.2, unchanged)"
  policy      = file("${path.module}/policies/lbc-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.workload["lbc"].name
  policy_arn = aws_iam_policy.lbc.arn
}

# UNVERIFIED (check on the first ALB): the upstream policy lets the controller ASSOCIATE a web
# ACL but not LIST them, and the IngressClassParams in gatepass-gitops names the ACL by NAME
# (`wafv2AclName`, so that no account id has to be written into the public repository). To
# turn a name into an ARN the controller has to list the ACLs. If the Ingress reports
# "AccessDenied ... wafv2:ListWebACLs" this statement is needed; if the first ALB comes up
# with the web ACL attached without it, delete this block and say so in the decision log.
# ListWebACLs cannot be limited to a resource, which is why the resource is "*".
data "aws_iam_policy_document" "lbc_waf_lookup" {
  statement {
    effect    = "Allow"
    actions   = ["wafv2:ListWebACLs"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lbc_waf_lookup" {
  name   = "waf-lookup"
  role   = aws_iam_role.workload["lbc"].id
  policy = data.aws_iam_policy_document.lbc_waf_lookup.json
}
