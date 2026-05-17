# budget.tf — AWS Budgets cost guardrail (opt-in, forker-tunable).
#
# Starting-point FinOps scaffolding, not a prescriptive cap. It ships a
# monthly `aws_budgets_budget` so a forked deployment has a cost backstop
# from `terraform apply` onward — but the defaults are deliberately
# conservative and meant to be tuned:
#   - `monthly_budget_usd` (default 25) — set this to YOUR steady-state
#     estimate. 25 suits the case-study's ~3h apply-then-destroy window; a
#     long-running fork should raise it (see the per-hour cost table in
#     README / deployment_guide).
#   - `budget_notification_email` (default "") — until set, the budget is a
#     silent cost tracker. Set it to arm 80%-actual + 100%-forecasted alerts.
# A forker who runs cost governance elsewhere (Cost Anomaly Detection, an
# org-level budget, a third-party FinOps tool) can simply delete this file.
# See ADR-0043 for the scope rationale.
#
# Account-wide on purpose — NOT scoped by the `Project` tag. A guardrail
# should also catch resources that escaped tagging (an orphaned NAT gateway,
# a leftover EIP), and a tag cost-filter additionally depends on the tag
# being activated as a cost-allocation tag in the Billing console first.
# Account-wide has neither footgun.
#
# Notifications attach only when `budget_notification_email` is set, keeping
# the default forker path free of unsolicited mail — same opt-in shape as
# main.tf's SNS wiring.

resource "aws_budgets_budget" "monthly" {
  name         = "aegis-enclave-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 80% of actual spend — early warning the acceptance window is overrunning.
  dynamic "notification" {
    for_each = var.budget_notification_email != "" ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_notification_email]
    }
  }

  # 100% forecasted — projected to blow the ceiling before month end.
  dynamic "notification" {
    for_each = var.budget_notification_email != "" ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = [var.budget_notification_email]
    }
  }
}
