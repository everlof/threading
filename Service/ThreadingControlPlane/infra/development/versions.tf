terraform {
  required_version = ">= 1.8.0"

  # Development state is still sensitive and remote. Its backend.hcl must use a state key that
  # is different from production; see README.md. Credentials come from the environment.
  backend "s3" {}

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22"
    }
  }
}

provider "cloudflare" {}
