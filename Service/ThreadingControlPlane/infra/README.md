# Cloudflare infrastructure

Terraform or OpenTofu owns durable account and zone resources. Wrangler owns the Worker script,
Durable Object migration, bindings, cron triggers, observability, custom domain, and the Queue
consumer. D1 SQL migrations remain in `../migrations/` and are applied by the guarded deployment.
This single-owner split avoids Terraform and Wrangler continually replacing each other's state.

Managed here:

- production D1 database (destroy-protected);
- private R2 issue-report bucket (destroy-protected) and mandatory 30-day `reports/v1/` expiry;
- report event Queue, 14-day dead-letter Queue, and R2 `PutObject` notification;
- the zone entry-point report rate-limit ruleset;
- an optional account billing-usage alert.

## OpenTofu, and the two account-specific files

`.terraform.lock.hcl` was produced by `tofu init`, so OpenTofu is what this module has been
exercised with. `scripts/infra.mjs` and `scripts/deploy-production.mjs` both default their CLI to
`terraform`; export `THREADING_INFRA_CLI=tofu` unless Terraform itself is installed. The deploy
wrapper reads `d1_database_id` through that same CLI, so getting it wrong fails the deploy rather
than silently using the checked-in placeholder.

Two files here are deliberately untracked and must exist before any command works:

- `terraform.tfvars` — the account and zone IDs.
- `backend.hcl` — the state bucket, key and account-specific R2 endpoint, passed as
  `tofu init -backend-config=backend.hcl`. The `backend "s3" {}` block in `versions.tf` is partial
  on purpose so no account-specific value is committed. Credentials come from
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in the environment, which for R2 means an S3
  access key created under R2 → Manage API Tokens, *not* the Cloudflare API token.

## The rate-limit rule is capped by the zone plan

A Free zone accepts only a 10-second window and a 10-second mitigation timeout; asking for
anything else fails the apply with an entitlement error. `report_rate_limit_period_seconds`
carries that fact, and both the window's request count and the mitigation timeout derive from it,
so a paid zone reproduces the originally intended rule by setting it to 60. See
`docs/operations/cloudflare-release-setup.md` for what the Free-plan values cost in practice.

Not stored here: API tokens, Worker secrets, Apple `.p8` material, TURN credentials, report pickup
credentials, webhook credentials, Terraform state, or customer reports. Use a protected remote
state backend and the team secret manager. A local state file is sensitive operational data even
though this module intentionally places no application secret in it.

## First production apply

1. Create a least-privilege Cloudflare API token outside Terraform. It needs D1, R2, Queues,
   Notifications and Zone WAF write permissions for the resources enabled here. Export it as
   `CLOUDFLARE_API_TOKEN`; do not put it in `terraform.tfvars`.
2. Copy `terraform.tfvars.example` to the ignored `terraform.tfvars`, replace account/zone IDs,
   and configure the billing alert using values returned by the account's
   `GET /alerting/v3/available_alerts` response. Leaving all three billing inputs empty omits the
   policy, but production release sign-off must then record the separately owned equivalent.
3. If the zone already has an `http_ratelimit` phase ruleset, import it and merge its rules into
   `cloudflare_ruleset.report_rate_limit`; Cloudflare permits one entry-point ruleset per phase.
   Do not apply this module over a dashboard-owned ruleset.
4. Run `terraform init`, then `npm run infra:plan`. Inspect the saved
   `infra/.threading.tfplan` and apply that exact plan with `npm run infra:apply`; the ignored
   plan must not be committed or reused after configuration changes. `tofu` is interchangeable;
   set `THREADING_INFRA_CLI=tofu` for repository scripts.
5. Install Worker secrets through the team secret-manager/CI path, then run `npm run deploy` from
   the service directory. The wrapper reads `d1_database_id` from this state and never modifies
   the checked-in production template.

TURN-key creation is an account bootstrap action rather than a Terraform resource in the current
Cloudflare provider. Create it through the Realtime API, write the returned secret directly to
the secret manager (it is returned once), and install only its key ID and API token as Worker
secrets. Account creation, payment method, nameserver delegation, Apple configuration, APNs keys,
and ownership of the alert destination are also release bootstrap inputs; the production TODO
tracks their verification.
