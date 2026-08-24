locals {
  report_prefix = "reports/v1/"

  # Cloudflare meters the rate-limit *window* by zone plan: a Free zone is entitled only to a
  # 10-second period, and asking for 60 fails the apply outright with "not entitled to use the
  # period 60, can only use a period among [10]". The operator-facing input stays a per-minute
  # rate, because that is the number worth reasoning about and it does not change when the plan
  # does; the window and its request count are derived from it. On a paid zone, raising
  # report_rate_limit_period_seconds to 60 reproduces the original rule exactly.
  rate_limit_period   = var.report_rate_limit_period_seconds
  rate_limit_requests = max(1, ceil(var.report_requests_per_minute_per_source * local.rate_limit_period / 60))

  # The same entitlement caps how long a flooding source stays blocked: a Free zone rejects any
  # mitigation timeout other than 10 ("not entitled to use a mitigation timeout different from
  # 10"). Derived from the window rather than given its own variable, because both facts encode
  # one thing — whether this zone is on a paid plan — and two knobs could disagree.
  rate_limit_mitigation = local.rate_limit_period == 10 ? 10 : 600
  billing_alert_enabled = (
    var.billing_alert_email != "" &&
    length(var.billing_alert_products) > 0 &&
    var.billing_alert_limit != ""
  )
}

resource "cloudflare_d1_database" "control_plane" {
  account_id = var.cloudflare_account_id
  name       = var.d1_database_name

  read_replication = {
    mode = "disabled"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_r2_bucket" "issue_reports" {
  account_id = var.cloudflare_account_id
  name       = var.issue_report_bucket_name

  # A placement *hint*, not a jurisdiction. It records where this bucket is meant to live
  # instead of leaving it to whatever Cloudflare picks, and it is the location this account
  # already selects on its own. Deliberately not `jurisdiction = "eu"`: that puts the bucket in
  # a separate namespace behind a different S3 endpoint, so the Worker's r2_buckets binding
  # would silently bind a *different* bucket of the same name unless it carried the same key.
  # Revisit only as a legal decision about report contents, and change both sides together.
  location = "eeur"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_r2_bucket_lifecycle" "issue_reports" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.issue_reports.name
  rules = [{
    id = "delete-private-issue-reports-after-30-days"
    conditions = {
      prefix = local.report_prefix
    }
    enabled = true
    delete_objects_transition = {
      condition = {
        max_age = 30 * 24 * 60 * 60
        type    = "Age"
      }
    }
  }]
}

resource "cloudflare_queue" "issue_report_events" {
  account_id = var.cloudflare_account_id
  queue_name = var.issue_report_queue_name
  settings = {
    message_retention_period = 4 * 24 * 60 * 60
  }
}

resource "cloudflare_queue" "issue_report_dead_letters" {
  account_id = var.cloudflare_account_id
  queue_name = var.issue_report_dead_letter_queue_name
  settings = {
    message_retention_period = 14 * 24 * 60 * 60
  }
}

resource "cloudflare_r2_bucket_event_notification" "issue_report_created" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.issue_reports.name
  queue_id    = cloudflare_queue.issue_report_events.queue_id
  rules = [{
    actions     = ["PutObject"]
    description = "Notify the private Threading triage consumer after a committed report"
    prefix      = local.report_prefix
    suffix      = ".json"
  }]
}

# This repository owns the zone entry-point ruleset for the rate-limit phase. Import an existing
# phase ruleset before applying instead of allowing Terraform to replace dashboard-owned rules.
# The free-plan-compatible expression intentionally uses host and path only; method and body-size
# enforcement remains in the Worker because those WAF fields require higher Cloudflare plans.
resource "cloudflare_ruleset" "report_rate_limit" {
  zone_id     = var.cloudflare_zone_id
  name        = "Threading control-plane rate limits"
  description = "Pre-Worker abuse backstop for anonymous private issue-report intake"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [{
    ref         = "threading_private_issue_report_source"
    description = "Block a source that floods the issue-report path"
    expression  = "http.host eq \"${var.service_hostname}\" and http.request.uri.path eq \"/v1/reports\""
    action      = "block"
    ratelimit = {
      characteristics     = ["cf.colo.id", "ip.src"]
      period              = local.rate_limit_period
      requests_per_period = local.rate_limit_requests
      mitigation_timeout  = local.rate_limit_mitigation
    }
  }]
}

# Billing alert filter values vary with the products enabled on an account. Keeping them as
# explicit inputs makes the policy declarative without guessing a product identifier that the
# production account may reject.
resource "cloudflare_notification_policy" "billing_usage" {
  count = local.billing_alert_enabled ? 1 : 0

  account_id  = var.cloudflare_account_id
  alert_type  = "billing_usage_alert"
  name        = "Threading Cloudflare usage budget"
  description = "Alert before Threading's Cloudflare usage exceeds the owned budget."
  enabled     = true
  mechanisms = {
    email = [{ id = var.billing_alert_email }]
  }
  filters = {
    product = var.billing_alert_products
    limit   = [var.billing_alert_limit]
  }
}

check "complete_billing_alert_configuration" {
  assert {
    condition = (
      (var.billing_alert_email == "" && length(var.billing_alert_products) == 0 && var.billing_alert_limit == "") ||
      local.billing_alert_enabled
    )
    error_message = "Set billing_alert_email, billing_alert_products, and billing_alert_limit together, or leave all three empty."
  }
}
