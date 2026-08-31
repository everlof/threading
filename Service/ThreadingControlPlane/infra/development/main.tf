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

# Access protects only the browser callback. The app-facing start/redeem, host, rendezvous and
# push routes remain reachable so native clients can use their own short-lived/scoped bearer
# credentials. The Worker verifies Access's JWT and repeats this exact-email allowlist itself,
# so a routing mistake cannot turn the edge cookie into authorization.
resource "cloudflare_zero_trust_access_application" "browser_authorization" {
  account_id = var.cloudflare_account_id
  name       = "Threading development browser authorization"
  domain     = "${var.service_hostname}/v1/auth/development/authorize"
  type       = "self_hosted"

  session_duration           = "1h"
  app_launcher_visible       = false
  http_only_cookie_attribute = true
  same_site_cookie_attribute = "lax"

  policies = [{
    name             = "Allow exact Threading development identities"
    decision         = "allow"
    precedence       = 1
    session_duration = "1h"
    include = [
      for email in var.allowed_emails : {
        email = { email = email }
      }
    ]
  }]
}
