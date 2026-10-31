# YOU WRITE (task 1 of 3): cost guardrails.
#
# GOAL
#   A monthly AWS Budget that e-mails var.alert_email, and Cost Anomaly Detection that e-mails
#   the same address when spend suddenly jumps. Cost control comes before everything else
#   because EKS, NAT and RDS bill by the hour whether or not anyone is looking.
#
# CONSTRAINTS
#   * Add a variable for the monthly limit (USD) in variables.tf; do not hard-code it here.
#     Think about the number: the account has about $118 of credits for the whole project.
#   * Alerts: at least 50% and 80% of the limit on ACTUAL spend, and 100% on FORECASTED spend.
#   * The subscriber is var.alert_email. Never write an address in this file (public repo).
#   * Anomaly detection: one monitor that follows spend per AWS service, one subscription
#     with an absolute-dollar impact threshold you choose and justify in a comment.
#   * Everything tagged through the provider's default_tags (nothing to do) - but check which
#     of these resource types actually support tags before adding a tags argument.
#
# HINTS
#   * Resource types to look up in the AWS provider docs: aws_budgets_budget,
#     aws_ce_anomaly_monitor, aws_ce_anomaly_subscription.
#   * AWS already created a monitor called "Default-Services-Monitor" in this account. Decide:
#     create your own, or import that one. Say why in a comment.
#   * Budgets are evaluated a few times a day, not instantly, so a test alert can take hours.
#
# ACCEPTANCE TEST
#   1. `terraform plan` shows only the new budget and anomaly resources, no changes elsewhere.
#   2. After apply: `aws budgets describe-budgets --account-id <id>` lists the budget with
#      three notifications.
#   3. Set one threshold very low (for example 1%), apply, wait for the e-mail, then set it back.
#
# BONUS (unverified, check the console page "Explore AWS" / credits): the Free plan advertises
# a credit for completing certain activities, and creating a budget is one of them.
