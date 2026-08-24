terraform {
  required_version = ">= 1.8.0"

  # State lives in R2, in this account, reached through R2's S3-compatible API. Deliberately a
  # *partial* configuration: the bucket, key and account-specific endpoint are supplied at init
  # time from an untracked backend.hcl, the same way terraform.tfvars carries the account and
  # zone IDs. Credentials never appear here; they come from the environment.
  #
  # `use_lockfile` is OpenTofu's native S3 locking, so no DynamoDB table is required. R2 has no
  # object versioning, so there is no state history to fall back on: the apply wrapper snapshots
  # the state object to a dated key instead.
  backend "s3" {}

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22"
    }
  }
}

provider "cloudflare" {}
