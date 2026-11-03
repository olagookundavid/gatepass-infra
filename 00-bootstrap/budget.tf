# COST GUARDRAILS: a monthly budget and a spend-spike detector, both e-mailing var.alert_email.
#
# WHY THIS EXISTS
#   EKS, NAT gateways, RDS and load balancers bill by the hour whether or not anyone is looking.
#   One forgotten cluster over a weekend can eat a large share of the account's credits. The two
#   mechanisms here catch two different failure modes:
#     * AWS Budget          "we are spending more than planned this month" (slow, predictable)
#     * Anomaly Detection   "something suddenly costs far more than usual" (fast, unpredictable)
#
# HOW IT RELATES TO THE OTHER FILES
#   * variables.tf supplies the e-mail address, the monthly limit and the anomaly threshold.
#   * locals.tf supplies the name prefix. Nothing else depends on this file (it can be applied
#     or removed without affecting the rest of the layer).
#   * Everything is persistent: budgets and monitors cost (almost) nothing and must keep watching
#     between sessions, so `make down` never touches this layer.

# ---- 1. The monthly budget ------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # IMPORTANT, and easy to get wrong on this account: our bill is paid with promotional CREDITS.
  # By default a budget measures cost AFTER credits are subtracted, which here is always about
  # $0, so it would never alert while the credits quietly drain. Excluding credits (and refunds)
  # makes the budget measure the real usage cost, which is what we want to watch.
  # UNVERIFIED until the first alert: compare the budget's "current spend" in the console with
  # Cost Explorer's unblended cost.
  cost_types {
    include_credit = false
    include_refund = false
  }

  # Three e-mails: early warning, strong warning, and a forecast warning (AWS predicts from the
  # month so far that we WILL pass the limit, which can fire before we actually do).
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# ---- 2. Cost Anomaly Detection --------------------------------------------------------------
# A "monitor" decides WHAT to watch; here: spend per AWS service (a jump in EC2, NAT or EKS
# stands out against that service's own history).
#
# HISTORY (2026-11-03): an account may have only ONE monitor of type DIMENSIONAL/SERVICE, and
# AWS had created one by itself ("Default-Services-Monitor", with a subscription that only
# e-mailed at $100 AND +40%). The first apply failed with "Limit exceeded on dimensional spend
# monitor". We deleted AWS's default monitor and subscription by hand (decision log) so that
# this monitor and subscription are the account's own, in code. If AWS ever re-creates its
# default, delete it again or the apply fails with the same error.
resource "aws_ce_anomaly_monitor" "services" {
  name              = "${local.name_prefix}-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

# A "subscription" decides WHO is told and WHEN. DAILY sends one summary e-mail a day. (The
# alternative IMMEDIATE only works with an SNS topic, not with plain e-mail.)
# The threshold is an absolute dollar impact: a day with everything left running costs roughly
# $10-13 here, so an anomaly worth $10 or more is one worth a message. Tune it in variables.tf.
resource "aws_ce_anomaly_subscription" "email" {
  name             = "${local.name_prefix}-anomaly-email"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "EMAIL"
    address = var.alert_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }
}
