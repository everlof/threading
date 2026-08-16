variable "cloudflare_account_id" {
  description = "Cloudflare account that owns the Worker, D1, R2, Queues, and TURN key."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id must be a 32-character lowercase Cloudflare account ID."
  }
}

variable "cloudflare_zone_id" {
  description = "Zone containing remote.threading.codes."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be a 32-character lowercase Cloudflare zone ID."
  }
}

variable "service_hostname" {
  description = "Production control-plane hostname."
  type        = string
  default     = "remote.threading.codes"

  validation {
    condition     = var.service_hostname == "remote.threading.codes"
    error_message = "The shipping apps and Worker preflight currently require remote.threading.codes."
  }
}

variable "worker_script_name" {
  description = "Worker deployed by Wrangler and attached to the issue-report Queue."
  type        = string
  default     = "threading-control-plane"
}

variable "d1_database_name" {
  type    = string
  default = "threading-control-plane"
}

variable "issue_report_bucket_name" {
  type    = string
  default = "threading-private-issue-reports"
}

variable "issue_report_queue_name" {
  type    = string
  default = "threading-issue-report-events"
}

variable "issue_report_dead_letter_queue_name" {
  type    = string
  default = "threading-issue-report-events-dlq"
}

variable "report_requests_per_minute_per_source" {
  description = "Pre-Worker zone limit. The Worker retains its stricter 6/minute report limiter."
  type        = number
  default     = 12

  validation {
    condition     = var.report_requests_per_minute_per_source >= 6 && var.report_requests_per_minute_per_source <= 60
    error_message = "The edge report limit must remain between 6 and 60 requests per minute per source."
  }
}

variable "billing_alert_email" {
  description = "Optional Cloudflare account email for usage alerts. Empty disables this resource."
  type        = string
  default     = ""
}

variable "billing_alert_products" {
  description = "Account-specific product values exposed by Cloudflare's billing_usage_alert schema."
  type        = list(string)
  default     = []
}

variable "billing_alert_limit" {
  description = "Account-specific limit value exposed by Cloudflare's billing_usage_alert schema."
  type        = string
  default     = ""
}
