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
