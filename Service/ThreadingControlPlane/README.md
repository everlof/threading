# Threading control plane

Cloudflare Worker + one hibernating Durable Object per Mac. The service authenticates accounts
and scoped host/device credentials, introduces iOS to the correct Mac, provisions short-lived
TURN configuration, and then leaves ordinary terminal traffic on the encrypted WebRTC path.

It does not accept terminal output, transcripts, prompts, attachments, file paths, provider
credentials, or permission evidence. Rendezvous messages are capped at 384 KiB; one Mac has one
control socket, at most eight pending/device sessions, and at most 64 ICE candidates per peer.

## Local verification

```sh
npm ci
npm run check
npm test
cp .dev.vars.example .dev.vars
npx wrangler d1 migrations apply threading-control-plane --local
npm run dev
```

The checked-in `wrangler.jsonc` intentionally contains a non-deployable D1 database ID. Create the
production D1 database, replace that value, apply migrations, then set these encrypted secrets:

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

Create a Cloudflare Realtime TURN key;
the long-lived key and API token stay in Worker secrets. Clients receive only generated TURN
credentials. If TURN credential provisioning is temporarily unavailable, rendezvous continues
with Cloudflare STUN so direct paths remain available.

Before deployment, configure the final native Sign in with Apple bundle IDs in
`APPLE_CLIENT_IDS`, attach the custom service domain, enable account/auth rate limits at the edge,
register Apple's server-to-server notification endpoint, and set log retention. Do not deploy
with the example D1 ID or `.dev.vars` values.
