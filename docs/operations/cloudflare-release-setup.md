# Cloudflare and iOS release setup TODO

This is the release owner checklist for the hosted control plane. A box means production state
was inspected; code existing in the repository does not check it. Durable Cloudflare resources
are declared in `Service/ThreadingControlPlane/infra/`; Worker code, bindings, migrations,
secrets, custom domain, cron triggers and the Queue consumer are deployed through Wrangler.

## Account and infrastructure ownership

- [ ] Put the production Cloudflare account on the required Workers plan, add a payment method,
  name an account owner and on-call owner, and record account/zone IDs in the deployment system.
- [ ] Create a least-privilege CI API token for D1, R2, Queues, Notifications and Zone WAF writes.
  Store it only in CI/team secret management and exercise rotation.
- [x] Configure a protected remote Terraform/OpenTofu state backend with locking, versioning,
  recovery access and an owner. Never commit local state, plans, tfvars or API tokens.
  *(2026-08-24: state is in R2 at `threading-tofu-state/control-plane/terraform.tfstate`, using
  OpenTofu's native S3 locking — `use_lockfile`, no DynamoDB. The backend is declared partial in
  `versions.tf`; its account-specific values live in an untracked `infra/backend.hcl` the same way
  `terraform.tfvars` carries the account and zone IDs.)*
  **R2 has no object versioning**, so "versioning" above cannot be satisfied as written: the
  provider offers `cloudflare_r2_bucket_{cors,lifecycle,lock,event_notification,sippy}` and no
  versioning resource, because R2 does not implement it. Durability and locking are covered;
  point-in-time recovery from a bad write is not. The apply step therefore copies the state object
  to a dated `snapshots/` key afterwards, which is the substitute. HCP Terraform's free tier is
  the alternative if real state history is ever wanted, at the cost of a third party holding it.
- [x] If the zone already has an `http_ratelimit` entry-point ruleset, import it and merge every
  existing rule into `cloudflare_ruleset.report_rate_limit` before applying. One system owns the
  complete phase; do not split it between the dashboard and Terraform. *(2026-08-24: the zone had
  zero entry-point rulesets in that phase, so nothing needed importing.)*
- [x] Run `npm run infra:plan`, review the saved `.threading.tfplan`, then use `npm run infra:apply`
  to apply that exact plan. Confirm the resulting D1, private R2 bucket, 30-day lifecycle, report
  Queue, 14-day dead-letter Queue, R2 event notification and report rate-limit rule in production.
  *(2026-08-24: all seven applied and read back from the API. The lifecycle reports
  `maxAge=2592000s` on prefix `reports/v1/`, and the notification reports `PutObject` on
  `reports/v1/` + `.json` into `threading-issue-report-events`.)*

### The zone plan caps the edge rate limit, and the shipped values assumed a paid one

`main.tf` originally asked for a 60-second window and a 600-second mitigation timeout. **Neither
is available on a Free zone**, and the config could not apply there at all. Both failures are
entitlement errors from the rulesets API rather than anything wrong with the rule:

```
not entitled to use the period 60, can only use a period among [10]
not entitled to use a mitigation timeout different from 10
```

The module now derives both from one input. `report_rate_limit_period_seconds` defaults to 10 and
accepts 60; `report_requests_per_minute_per_source` stays the operator-facing rate and is
converted to the window's request count, so raising the period to 60 on a paid zone reproduces
the original rule exactly.

**What a Free zone actually buys is weaker than the design assumed, and it is the mitigation
timeout rather than the rate that matters.** The effective rate is unchanged: 12/minute becomes
2 per 10 seconds. But a flooding source is released after 10 seconds instead of 10 minutes, so
the edge sheds a sustained flood 60 times less effectively. The Worker's own limiters are
untouched and remain the real gate — `REPORT_RATE_LIMITER` at 6/minute per source and
`REPORT_GLOBAL_RATE_LIMITER` at 60/minute — so this degrades a backstop rather than the control.
Upgrading the zone plan and setting the period to 60 is the whole fix; no code changes.
- [ ] Configure `billing_alert_email`, `billing_alert_products`, and `billing_alert_limit` from
  the account's current `billing_usage_alert` schema and send a test notification. If Cloudflare
  does not offer that alert for the account, record the separately owned budget alarm here.

## Vendor bootstrap and secrets

- [ ] Activate `remote.threading.codes` in the same account and verify Cloudflare-managed TLS.
- [ ] Create a Realtime TURN key through Cloudflare's API. It is not exposed by the current
  Terraform provider. Put its one-time API token directly in secret management, install
  `TURN_KEY_ID` and `TURN_KEY_API_TOKEN`, and run forced relay-only probes over UDP, TCP and TLS.
- [ ] Configure Sign in with Apple for `codes.threading` and `codes.threading.mobile`; install its
  team ID, key ID and `.p8`, and register
  `https://remote.threading.codes/v1/auth/apple/events` for server-to-server account events.
- [ ] Create a separate APNs token key authorized for `codes.threading.mobile`; install
  `APNS_TEAM_ID`, `APNS_KEY_ID`, and `APNS_PRIVATE_KEY`. The `.p8` must not ship in either app or
  be installed on a user's Mac. The current single-secret Worker requires an existing/unrestricted
  key valid in both environments; newer environment-scoped Apple keys require separate Worker
  secrets and selection support. Verify one accepted delivery against each endpoint because the
  device tokens remain environment-specific.
- [ ] Generate independent 32-byte-or-longer values for session signing, stored Apple-token
  encryption, stored APNs-token encryption, report pickup and triage webhook authentication.
  Install every name pinned by `wrangler.jsonc` and retain operator copies only where explicitly
  required.
- [ ] Configure an owned HTTPS `REPORT_ALERT_WEBHOOK_URL`. Its receiver must deduplicate on the
  report ID and accept only the metadata-only event documented in `docs/ISSUE_REPORTING.md`.

## Guarded deployment

- [ ] From `Service/ThreadingControlPlane`, run `npm ci`, `npm run infra:plan`, and `npm run
  deploy`. The deploy wrapper must obtain D1's ID from state; never edit the checked-in placeholder.
- [ ] Confirm `/health` and `/ready` on the custom domain. Readiness must fail when Apple, TURN,
  APNs, D1, private R2, report pickup or alert configuration is absent.
- [ ] Confirm Worker observability contains identifiers, counts, timing and result categories
  only. Set a short owned retention and verify no request bodies, authorization headers, device
  tokens, notification text, report prose, screenshots, terminal content or paths are present.
- [ ] Verify both scheduled jobs, D1 migrations, Durable Object migration, all five Worker-native
  rate-limit bindings and the report Queue consumer are visible on the deployed Worker.

## iOS release gate

- [ ] On a signed development build, register a sandbox APNs token, suspend the app, and receive
  every notification kind through the Worker broker. Verify deep links and live/push deduplication.
- [ ] Repeat with a TestFlight build and production APNs. Test quiet kinds, sound-enabled kinds,
  expiration, collapse, an invalid token, APNs 429/5xx behavior, credential expiry and host revoke.
- [ ] Verify first-install hosted QR pairing on cellular, direct ICE, forced TURN, background and
  foreground recovery, repeated Wi-Fi/cellular handoff, device revoke and a lost/reinstalled phone.
- [ ] Verify Sign in with Apple, refresh rotation, consent revocation, account deletion and a
  subsequent clean sign-in on signed macOS and iOS release candidates.
- [ ] Complete the App Store privacy declarations, encryption-export determination, notification
  purpose/copy review, account-deletion review, privacy policy and support contact.

## Issue intake and operations

- [ ] Complete every item in `docs/operations/issue-reporting-setup.md`, including macOS manual,
  inspector and post-crash submissions plus iOS report/outbox retry.
- [ ] Trigger one report notification, force webhook failure through five Queue retries, inspect
  the dead letter without opening customer content, then redrive it after restoring the receiver.
- [ ] Document triage ownership, response expectation, pickup-token rotation and the sanitization
  review required before a public GitHub issue is created.
- [ ] Alert on sustained 429/5xx, APNs refusal/transport failure, Queue backlog/dead letters, report
  daily capacity, R2/D1/Worker errors and Cloudflare spend. Test every notification destination.
- [ ] Document the emergency intake stop: add a temporary Cloudflare block rule for exactly
  `remote.threading.codes/v1/reports`, verify a generic failure from both apps, preserve private
  pickup, and then import/reconcile or remove the rule through Terraform after the incident.
- [ ] Document incident response, Cloudflare/Apple credential rotation, account deletion,
  Terraform state recovery, D1 recovery, R2 lifecycle verification and Queue redrive.

## Cloud-free development

- [ ] Run repository-root `./dev` and verify `/ready`, local auth, D1 migrations, R2 report
  storage/pickup and WebRTC host-only ICE all work at `127.0.0.1:8787`.
- [ ] Verify the isolated Debug Mac app auto-enrolls, its private-report outbox uses the loopback
  intake, and the automatically launched iOS Simulator app pairs from the copied owner link.
- [ ] Confirm local mode never calls Apple identity, TURN, APNs or the triage webhook. Use staging,
  not a LAN HTTP exception, for a physical iPhone.
