# TRACE SAMPLING for AWS X-Ray: how many requests are recorded as traces.
#
# A trace is the tree of one request (ALB -> service -> database). Recording all of them costs
# money and storage at real traffic, so production samples. The rule below says: record the first
# request each second (the reservoir, so even a quiet service always shows something) plus
# `trace_sampling_rate` of the rest. Dev records everything (rate 1) because traffic is
# tiny and being able to find THE trace of a test request matters more than the cost; production
# sets 0.05 (5%) and adds tail sampling in the collector (keep every error and every slow trace)
# when volume justifies it. The decision and its numbers are in the decision log.
#
# The collector reads this rule (xray:GetSamplingRules) only if it is configured to; the head
# sampling in our setup is decided by the SDK (parent-based, ratio from the OTEL_TRACES_SAMPLER
# variables in the generic chart) and X-Ray stores whatever arrives. This rule sets the default
# for anything that asks X-Ray for its sampling decision, and documents the intent.
#
# Related files: variables.tf (trace_sampling_rate), pod-identity.tf (sampling permissions).

resource "aws_xray_sampling_rule" "default" {
  rule_name      = "${local.name_prefix}-default"
  priority       = 1000
  version        = 1
  reservoir_size = 1
  fixed_rate     = var.trace_sampling_rate
  host           = "*"
  http_method    = "*"
  url_path       = "*"
  service_name   = "*"
  service_type   = "*"
  resource_arn   = "*"
}
