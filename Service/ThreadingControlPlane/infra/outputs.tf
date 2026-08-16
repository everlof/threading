output "d1_database_id" {
  description = "Rendered into the production Wrangler configuration by the deploy wrapper."
  value       = cloudflare_d1_database.control_plane.uuid
}

output "issue_report_bucket_name" {
  value = cloudflare_r2_bucket.issue_reports.name
}

output "issue_report_queue_name" {
  value = cloudflare_queue.issue_report_events.queue_name
}

output "issue_report_dead_letter_queue_name" {
  value = cloudflare_queue.issue_report_dead_letters.queue_name
}

output "billing_alert_managed" {
  value = local.billing_alert_enabled
}
