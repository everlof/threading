variable "cloudflare_account_id" {
  description = "Cloudflare account that owns the isolated development Worker resources."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id must be a 32-character lowercase Cloudflare account ID."
  }
}

variable "service_hostname" {
  description = "Dedicated hostname for the operated development control plane."
  type        = string
  default     = "dev.remote.threading.codes"

  validation {
    condition     = var.service_hostname == "dev.remote.threading.codes"
    error_message = "Development app and Worker guards require dev.remote.threading.codes."
  }
}

variable "d1_database_name" {
  type    = string
  default = "threading-control-plane-development"

  validation {
    condition     = var.d1_database_name == "threading-control-plane-development"
    error_message = "Development must not share the production D1 database."
  }
}

variable "access_team_domain" {
  description = "Existing Cloudflare Zero Trust team domain, for example team.cloudflareaccess.com."
  type        = string

  validation {
    condition = can(regex(
      "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.cloudflareaccess\\.com$",
      var.access_team_domain,
    ))
    error_message = "access_team_domain must be a lowercase *.cloudflareaccess.com hostname."
  }
}

variable "allowed_emails" {
  description = "Exact lowercase identities allowed to authorize a development Mac. Never use a domain-wide rule."
  type        = list(string)
  sensitive   = true

  validation {
    condition = (
      length(var.allowed_emails) >= 1 &&
      length(var.allowed_emails) <= 8 &&
      length(distinct(var.allowed_emails)) == length(var.allowed_emails) &&
      alltrue([
        for email in var.allowed_emails :
        email == lower(trimspace(email)) &&
        can(regex("^[^[:space:]@]+@[^[:space:]@]+$", email)) &&
        length(email) <= 320
      ])
    )
    error_message = "allowed_emails must contain 1-8 unique, exact lowercase email addresses."
  }
}
