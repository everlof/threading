# Threading control plane

Cloudflare Worker + one hibernating Durable Object per Mac. The service authenticates accounts
and scoped host/device credentials, introduces iOS to the correct Mac, provisions short-lived
TURN configuration, and then leaves ordinary terminal traffic on the encrypted WebRTC path.

It does not accept terminal output, transcripts, prompts, attachments, file paths, provider
credentials, or permission evidence. Rendezvous messages are capped at 384 KiB; one Mac has one
control socket, at most eight pending/device sessions, and at most 64 ICE candidates per peer.
Worker-native rate-limit bindings protect authentication and API entry points before database or
Durable Object work; database-side guards keep product quotas intact under concurrent requests.

## Local verification

```sh
npm ci
npm run check
npm test
cp .dev.vars.example .dev.vars
npx wrangler d1 migrations apply threading-control-plane --local
npm run dev
```

The checked-in `wrangler.jsonc` intentionally contains a non-deployable D1 database ID. `npm run
deploy` runs the production preflight, type-check and full Worker suite before making a remote
change, applies D1 migrations, deploys the Worker, and then verifies `/ready` through the custom
domain. The checked-in `secrets.required` contract makes Wrangler refuse local startup or
deployment when a required encrypted binding is absent; the preflight pins that list so a
configuration edit cannot silently weaken it. Create the production D1 database, replace that
value, then set these encrypted secrets:

```sh
npx wrangler secret put SESSION_SIGNING_SECRET
npx wrangler secret put APPLE_TEAM_ID
npx wrangler secret put APPLE_KEY_ID
npx wrangler secret put APPLE_PRIVATE_KEY
npx wrangler secret put APPLE_TOKEN_ENCRYPTION_SECRET
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_KEY_API_TOKEN
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

Before deployment, keep `APPLE_CLIENT_IDS` aligned with the shipping `codes.threading` macOS and
`codes.threading.mobile` iOS bundle IDs, attach the custom service domain, verify the checked-in
rate-limit namespace IDs are unused in the production Cloudflare account, register Apple's
server-to-server notification endpoint, and set log retention. Do not deploy with the example D1
ID or `.dev.vars` values.

## Production deployment checklist

1. Authenticate Wrangler with the production Cloudflare account and create the D1 database:

   ```sh
   npx wrangler login
   npx wrangler d1 create threading-control-plane
   ```

   Put the returned database ID in `wrangler.jsonc`. Never commit account tokens or secret values.

2. Create a Cloudflare Realtime TURN key and record its key ID and API token. TURN is the relay
   fallback for failed direct ICE paths; it is not an always-on tunnel.
3. Create the Sign in with Apple key and configure the macOS and iOS App IDs. Register
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
6. Verify the Worker-native authentication (30/minute), per-credential API (120/minute), and
   broad per-source (600/minute) rate-limit bindings in production. They are permissive,
   per-location abuse protection rather than billing quotas. Do not rate-limit established
   WebSocket messages as independent HTTP requests. Retain only the metadata-only structured logs
   emitted by the Worker, with a documented short retention.
7. Verify `GET /health`, `GET /ready`, Sign in with Apple, first-install QR pairing, direct ICE, forced TURN,
   device revoke, host sign-out, scheduled Apple refresh validation, Apple consent revocation and
   retryable account deletion from a signed release candidate. Run the credentialed relay-only
   package probe documented in `Packages/ThreadingPeerTransport/README.md` separately for the
   provisioner's TURN-over-UDP, TURN-over-TCP and TURN-over-TLS URLs; the probe fails if WebRTC
   silently uses a direct candidate. Confirm D1 contains no transcript, terminal, path or
   provider-secret fields.

Deployment is intentionally impossible until steps 1–4 replace the placeholder database ID and
example secrets. A Worker preview or `workers.dev` hostname is useful for staging, but distributed
app builds are configured for `https://remote.threading.codes`.

`/health` is a cheap liveness response. `/ready` additionally proves that the independent signing
and Apple-token secrets are usable, the Apple private key can sign both shipping client IDs, TURN
configuration is present, and D1 answers a query. It returns only a generic 503 when unavailable;
configuration details remain in metadata-only Worker logs.
