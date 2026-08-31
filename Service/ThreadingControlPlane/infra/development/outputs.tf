output "d1_database_id" {
  description = "Rendered into the development Wrangler configuration by the deploy wrapper."
  value       = cloudflare_d1_database.control_plane.uuid
}

output "development_access_audience" {
  description = "Access application AUD verified independently by the Worker."
  value       = cloudflare_zero_trust_access_application.browser_authorization.aud
}

output "development_access_issuer" {
  description = "Exact issuer accepted by the Worker for Access JWTs."
  value       = "https://${var.access_team_domain}"
}

output "allowed_emails" {
  description = "The same exact allowlist is enforced at Access and again inside the Worker."
  value       = var.allowed_emails
  sensitive   = true
}
