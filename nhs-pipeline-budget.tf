# ---------- Cost safety net ----------
# Whole-account budget, not scoped to just this project - simplest to set
# up, and this project's real usage (a few cents/month) is so far under
# these thresholds that a trip here means something else entirely is worth
# looking at too.

variable "budget_alert_email" {
  description = "Where AWS sends budget threshold emails"
  type        = string
  default     = "moeshazly25@gmail.com"
}

resource "aws_budgets_budget" "account_cost_alert" {
  name              = "account-cost-alert"
  budget_type       = "COST"
  limit_amount      = "2"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"
  time_period_end   = "2087-06-15_00:00" # deliberately far out - AWS's own examples use this pattern to mean "no real end date"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
