# The WAF web ACL: the filter that sits IN FRONT of the Application Load Balancer and drops
# bad requests before they reach any pod.
#
# HOW IT IS ATTACHED. This layer only creates the ACL. The load balancer controller attaches
# it to the ALB because the IngressClassParams in gatepass-gitops (platform/cluster-config/
# ingressclass-alb.yaml) says `wafv2AclName: gatepass-dev`. It is set once on the class, so
# EVERY Ingress of the class is protected and a service team cannot forget the annotation. It is
# referenced by NAME on purpose: an ACL ARN contains the account id, which must not appear in
# the public repository.
#
# RULES (evaluated in priority order, lowest number first; the first rule that blocks wins):
#   10  AWSManagedRulesCommonRuleSet        the OWASP-style basics: cross-site scripting, path
#                                           traversal, oversized bodies, bad user agents
#   20  AWSManagedRulesKnownBadInputsRuleSet  payloads known to exploit specific software (for
#                                           example Log4Shell-style strings)
#   30  AWSManagedRulesAmazonIpReputationList source addresses AWS itself sees attacking others
#   40  rate limit (per client IP)          blocks an IP that sends more than waf_rate_limit
#                                           requests in 5 minutes; the protection against a
#                                           single noisy client or a crude flood
# Managed rule groups are maintained by AWS (no cost beyond the rule's own price), but their
# rules can block legitimate traffic (a false positive): that is why every group is in the
# list, not silently trusted. Phase 6 turns on logging and tunes exclusions with real traffic.
#
# default_action allow: anything no rule blocks passes. A deny-by-default ACL is for APIs with
# a fixed set of callers.
#
# COST (us-east-1 list prices, verify on the pricing page): $5 per ACL per month + $1 per rule
# per month (the 4 rules above: $4; the managed groups count as one rule each) + $0.60 per
# million requests. About $9 a month, or $0.30 a day while it exists. The layer is torn down
# with `make down`, so it is billed by the hour.
#
# CLOUDWATCH METRICS are on for the ACL and every rule (cloudwatch_metric_name): the Phase 5
# dashboards graph blocked requests per rule from them. sampled_requests_enabled keeps the last
# few hundred requests per rule viewable in the console for free (Check it yourself, 7).
#
# Related files: lbc.tf (the permission to associate), outputs.tf (the name),
# gatepass-gitops/platform/cluster-config/ingressclass-alb.yaml (who references it).

locals {
  waf_managed_groups = {
    "common-rule-set" = {
      priority = 10
      name     = "AWSManagedRulesCommonRuleSet"
    }
    "known-bad-inputs" = {
      priority = 20
      name     = "AWSManagedRulesKnownBadInputsRuleSet"
    }
    "ip-reputation" = {
      priority = 30
      name     = "AWSManagedRulesAmazonIpReputationList"
    }
  }
}

resource "aws_wafv2_web_acl" "main" {
  name        = local.name_prefix
  description = "Regional web ACL for the shared Application Load Balancer of ${local.name_prefix}"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.waf_managed_groups

    content {
      name     = rule.key
      priority = rule.value.priority

      # "none" = use the actions the rule group itself defines (block). "count" would only
      # record matches, which is how you trial a new group without breaking traffic.
      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name_prefix}-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name_prefix
    sampled_requests_enabled   = true
  }
}
