# Report alerts

The owned receiver for the control plane's `REPORT_ALERT_WEBHOOK_URL`. One job: turn a bounded,
content-free "a report arrived" event into a notification somebody actually sees.

```text
control plane ──POST /v1/report-alert──▶ this Worker ──▶ ntfy topic ──▶ phone
                (bearer + Idempotency-Key)   (auth, dedup, format)
```

## Why this exists rather than pointing the control plane at a service

`configuredReportAlertWebhook` rejects any URL carrying a query string, a fragment, or embedded
credentials, and posts its own JSON shape under an `Authorization: Bearer`. Almost every hosted
webhook fails at least one of those: Slack and Discord ignore the body shape, ntfy rejects an
`Authorization` header it did not issue, and anything carrying a token in the query string is
refused before it is called.

More importantly, the runbook requires the receiver to **deduplicate on the report ID**, and a
third-party endpoint cannot. The intake Queue retries a failed delivery five times with the same
`Idempotency-Key`, so without dedup one report pages five times.

Keeping this in between also means the channel is a deployment detail of *this* Worker. Swapping
ntfy for email or Slack is an edit to `forward()` and a redeploy, with no change to any Threading
secret and no redeploy of the control plane.

## What it never sees

The event carries an ID, a reference, three machine tokens, an ISO timestamp and a byte count.
No description, no screenshot, no diagnostics, no path, no account. It stores nothing but a dedup
marker keyed by report ID, and that expires after an hour.

## Deduplication is best-effort, deliberately

Dedup uses the Cache API rather than KV or D1, so it is per-colo and evictable. That is a real
limitation and it is the right trade here: the failure it guards against is a Queue retry landing
within minutes, which almost always reaches the same colo, and the cost of a miss is a duplicate
phone notification rather than anything incorrect.

The marker is written **after** a successful forward, never before. Recording it first would mean
a failed delivery got suppressed on retry, turning a transient ntfy outage into a permanently lost
alert.

If duplicates ever become a genuine annoyance, a small dedicated D1 is the upgrade; the account
already has D1 available and the token scope to create one.

## The topic is a secret

ntfy topics are readable by anyone who knows the name, so `NTFY_TOPIC` is random rather than
descriptive and is installed with `wrangler secret put`, not as a var. The payload is metadata
only, so the consequence of a guessed topic is someone learning that a report arrived and how many
bytes it was, but there is no reason to accept even that.

## Secrets

```
wrangler secret put REPORT_ALERT_WEBHOOK_TOKEN   # must equal the control plane's value
wrangler secret put NTFY_TOPIC
```

Both sides must agree on the token or delivery fails closed, which is the point: an
unauthenticated caller must not be able to page the operator.

## Local

```
cp .dev.vars.example .dev.vars   # then edit
npx wrangler dev --port 8799
```

The rejection paths are worth exercising after any change, because they are the security surface:
a `GET` is 405, an unknown path 404, a missing or wrong bearer 401, a malformed or oversized body
400, and a duplicate report ID 204 with nothing forwarded.
