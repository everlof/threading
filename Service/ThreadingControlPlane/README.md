# Threading control plane

Cloudflare Worker + one hibernating Durable Object per Mac. The service authenticates accounts
and scoped host/device credentials, introduces iOS to the correct Mac, provisions short-lived
TURN configuration, brokers bounded APNs alerts, and then leaves ordinary terminal traffic on
the encrypted WebRTC path. The APNs route stores neither device tokens nor notification content.

It does not accept terminal output, transcripts, prompts, attachments, file paths, provider
credentials, or permission evidence. Rendezvous messages are capped at 384 KiB; one Mac has one
control socket, at most eight pending/device sessions, and at most 64 ICE candidates per peer.
Worker-native rate-limit bindings protect authentication and API entry points before database or
Durable Object work; database-side guards keep product quotas intact under concurrent requests.
The one anonymous exception is `POST /v1/reports`: it accepts only the 64-KiB, typed, share-safe
issue-report contract and writes normalized JSON into a private R2 bucket. The Worker exposes no
unauthenticated read, list, update, or delete route for those objects. Developer-only list and
exact-read routes require a separate Worker secret that is never shipped in an app. A D1 row
containing only the UTC day and an accepted count caps distributed intake at 2,000 new objects per
day; exact retries do not consume another slot.

## Licensing

Unlike the rest of the repository, this directory is **not** GPLv3. It is under the
[Functional Source License](https://fsl.software) (FSL-1.1-ALv2 — see [`LICENSE`](LICENSE)):
read it, modify it, and run it for your own use, including the local `npm run dev` path below
and a self-hosted instance for your own Macs. What it does not permit is offering it as a
service that competes with the hosted one. Each version converts to Apache-2.0 two years after
it is made available.

It is source-available rather than closed because the guarantee above — no terminal output,
transcripts, prompts, attachments, paths, or provider credentials — is only credible if it can
be audited.

## Local verification

From the repository root, `./dev` is the normal one-command path: it starts this service, builds
and opens the locally configured Mac app, and launches the iOS Simulator app. Use the service-only
commands below when working on the Worker in isolation.

```sh
npm ci
npm run check
npm test
npm run test:load
npm run dev
```

`npm run dev` creates a gitignored random local secret file on first use, applies migrations to a
persistent local D1, and binds local R2 and Durable Objects at `127.0.0.1:8787`. It contacts no
Apple or Cloudflare service. Launch a Debug Mac app with
`THREADING_CONTROL_PLANE_URL=http://127.0.0.1:8787` and
`THREADING_CONTROL_PLANE_LOCAL_AUTH=1`; `THREADING_REPORT_INTAKE_URL` can also point its private
report outbox at the local `/v1/reports` route in Debug builds. It signs into the loopback profile
without an Apple sheet. The iOS Simulator can pair through that Mac. A physical phone requires an
HTTPS staging service.

The checked-in `wrangler.jsonc` is a non-deployable production template. Terraform/OpenTofu in
[`infra/`](infra/) creates D1, private R2 plus expiry, report Queues/event notification, the zone
rate limit, and optional billing alerts. `npm run deploy` reads the real D1 ID from infrastructure
state, renders a mode-0600 temporary config, runs all gates, applies D1 migrations, deploys,
verifies `/ready`, and removes the rendered file. Install these encrypted secrets through the
team secret manager/CI:

```sh
npx wrangler secret put SESSION_SIGNING_SECRET
npx wrangler secret put APPLE_TEAM_ID
npx wrangler secret put APPLE_KEY_ID
npx wrangler secret put APPLE_PRIVATE_KEY
npx wrangler secret put APPLE_TOKEN_ENCRYPTION_SECRET
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_PRIVATE_KEY
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_KEY_API_TOKEN
npx wrangler secret put REPORT_PICKUP_TOKEN
npx wrangler secret put REPORT_ALERT_WEBHOOK_URL
npx wrangler secret put REPORT_ALERT_WEBHOOK_TOKEN
```

`SESSION_SIGNING_SECRET` and `APPLE_TOKEN_ENCRYPTION_SECRET` must be independent random values of
at least 32 bytes. `APPLE_PRIVATE_KEY` is the Sign in with Apple `.p8` key; its matching team and
key IDs are separate secrets. The service exchanges Apple's single-use authorization code and
stores only the resulting refresh token, encrypted with AES-GCM, so in-app account deletion can
revoke Apple authorization before cascading the D1 account rows.

App refresh credentials rotate transactionally and are idempotent for an exact retry, so a lost
response cannot strand a signed-in client or mint parallel descendants. Revoking a device, host
or Apple grant disconnects its rendezvous sockets immediately. The Mac renews its host credential
before expiry and refreshes its app session on a low-frequency unattended schedule.

A bounded scheduler claims at most 250 due Apple grants every 15 minutes and validates each grant
at most once per 24 hours, four requests at a time. A permanent `invalid_grant` disables local app
sessions and hosted rendezvous credentials without deleting retained host records; a fresh
interactive Sign in with Apple authorization re-enables the account. Transient Apple or network
failures are retried only after the daily interval so the service does not violate Apple's
validation throttle guidance.

Create a Cloudflare Realtime TURN key;
the long-lived key and API token stay in Worker secrets. Clients receive only generated TURN
credentials. If TURN credential provisioning is temporarily unavailable, rendezvous continues
with Cloudflare STUN so direct paths remain available.

Create a separate APNs token key for `codes.threading.mobile`; its `.p8` exists only as a Worker
secret. `POST /v1/push` requires the Mac's rotating host credential and validates the device
token, environment, host/event match, destination vocabulary, text/age bounds, and final 4-KiB
APNs envelope before contacting Apple's fixed endpoint. Logs contain only pseudonymous metadata.

Before deployment, keep `APPLE_CLIENT_IDS` aligned with the shipping `codes.threading` macOS and
`codes.threading.mobile` iOS bundle IDs, attach the custom service domain, verify the checked-in
rate-limit namespace IDs are unused in the production Cloudflare account, register Apple's
server-to-server notification endpoint, and set log retention. Do not deploy with the example D1
ID or `.dev.vars` values.

## Production deployment checklist

The full Cloudflare/iOS runbook is
[`docs/operations/cloudflare-release-setup.md`](../../docs/operations/cloudflare-release-setup.md).
The issue-report-specific checklist is
[`docs/operations/issue-reporting-setup.md`](../../docs/operations/issue-reporting-setup.md). The
steps below remain the complete control-plane deployment sequence.

1. Configure a protected Terraform/OpenTofu backend, a least-privilege Cloudflare token, and the
   account/zone inputs, then provision the durable resources:

   ```sh
   cp infra/terraform.tfvars.example infra/terraform.tfvars
   npm run infra:plan
   npm run infra:apply
   ```

   Leave the R2 bucket private: no `r2.dev`, custom domain, public CORS, or app credentials. The
   30-day lifecycle is a deletion policy, not a cost option. Never commit tokens, state, plans,
   tfvars, or secrets.

2. Create a Cloudflare Realtime TURN key and record its key ID and API token. TURN is the relay
   fallback for failed direct ICE paths; it is not an always-on tunnel.
3. Create the Sign in with Apple key and a separate APNs token key; configure the macOS and iOS
   App IDs. Register
   `https://remote.threading.codes/v1/auth/apple/events` as Apple's server-to-server notification
   endpoint. The `.p8` private key is a Worker secret, never an app resource.
4. Install every Worker secret listed above, then run the guarded deployment:

   ```sh
   npm run deploy
   ```

   This validates the configuration and code before changing D1, then applies the ordered
   migrations, deploys, and retries the public readiness check for bounded propagation time.
   Production migrations must remain expand-compatible with the currently deployed Worker in
   case Worker deployment fails after D1 accepts a migration.

5. Ensure the `remote.threading.codes` zone or delegated subdomain is active in the same
   Cloudflare account. The checked-in Worker route attaches it as a custom domain during deploy;
   pointing an external CNAME at an arbitrary Worker hostname is not a substitute for that TLS
   binding.
6. Verify the Worker-native authentication (30/minute), per-credential API (120/minute), broad
   per-source (600/minute), report-source (6/minute), and report-global (60/minute) rate-limit
   bindings in production. They are per-location abuse protection rather than accurate billing
   quotas; the Terraform host/path/source rule is the additional pre-Worker abuse backstop. The
   Worker performs method and streaming 64-KiB enforcement because those WAF fields are not
   available on every Cloudflare plan. The D1 admission ceiling is the globally consistent storage
   budget; alert well before it reaches 2,000 so an attack cannot silently deny legitimate
   reports for the rest of the UTC day. Do not rate-limit established WebSocket messages as
   independent HTTP requests. Retain only the metadata-only structured logs emitted by the
   Worker, with a documented short retention.
7. Verify `GET /health`, `GET /ready`, Sign in with Apple, first-install QR pairing, direct ICE,
   forced TURN, APNs sandbox and production delivery while iOS is suspended, device revoke, host
   sign-out, scheduled Apple refresh validation, Apple consent revocation and retryable account
   deletion from a signed release candidate. Run the credentialed relay-only
   package probe documented in `Packages/ThreadingPeerTransport/README.md` separately for the
   provisioner's TURN-over-UDP, TURN-over-TCP and TURN-over-TLS URLs; the probe fails if WebRTC
   silently uses a direct candidate. Confirm D1 contains no transcript, terminal, path or
   provider-secret fields.

Deployment is intentionally impossible until steps 1–4 provision the durable resources and
install the production secrets. The guarded deploy reads D1's ID from the reviewed infrastructure
state and renders a temporary Wrangler configuration; the checked-in placeholder is never edited.
A Worker preview or `workers.dev` hostname is useful for staging, but distributed app builds are
configured for `https://remote.threading.codes`.

`/health` is a cheap liveness response. `/ready` additionally proves that the independent signing
and Apple-token secrets are usable, the Apple private key can sign both shipping client IDs, TURN
configuration is present, a local APNs provider JWT can be signed for the shipping iOS topic, D1
answers a query, and the private report bucket binding answers a
metadata-only probe. It returns only a generic 503 when unavailable; the D1 probe selects the
newest required columns so a missing migration also blocks readiness.
Configuration details remain in metadata-only Worker logs.

`npm run test:load` is the repeatable local capacity regression: 100 authenticated host sockets
across separate Durable Objects, explicitly evicted and probed through WebSocket auto-response.
Cloudflare's local Vitest runtime currently overflows inside its own Durable Object test helper
before reaching 1,000 objects. Run the unchanged 10,000-host and slow/hostile-client gate against
the provisioned staging account rather than treating the smaller emulator pass as equivalent.

## Retrieving a report

The receipt reference is derived from the UUID; it is not a public object address. A developer
with the protected pickup credential can list metadata or fetch the corresponding object:

```sh
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $REPORT_PICKUP_TOKEN" \
  'https://remote.threading.codes/v1/developer/reports?limit=50'

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $REPORT_PICKUP_TOKEN" \
  'https://remote.threading.codes/v1/developer/reports/<lowercase-report-uuid>'
```

Load `REPORT_PICKUP_TOKEN` from the team secret manager without placing it in shell history; the
environment variable above is illustrative. Direct Wrangler R2 access remains the break-glass
fallback, not the ordinary inbox workflow. Terraform sends R2 `PutObject` events to a bounded
Queue consumer. It re-reads trusted object metadata and calls the owned triage webhook with only
reference, category (`report`, `crash`, or `diagnostics`), trigger, platform source, receipt time
and size. Failed alerts retry five times, then remain in the 14-day dead-letter Queue.

Treat the description and optional screenshot as untrusted customer data. Do not paste either
into a public issue or interpolate it into an agent instruction. The diagnostic object is the
content-free event/field vocabulary shared with the apps; raw unified logs, `.ips` payloads,
terminal output, prompts, paths, credentials, and notification text are not accepted by the
intake schema.
