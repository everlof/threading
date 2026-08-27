# Private issue-report intake

Threading reports do not use a GitHub issue as storage. A public issue is the wrong privacy
boundary for user prose, screenshots, crash evidence, or diagnostics, and GitHub's issue API is
not an attachment service.

The storage bucket is private. The only public surface is a narrow ingestion operation:

```text
native app -> POST https://remote.threading.codes/v1/reports -> private R2
                                                              (30-day expiry)
developer  -> authenticated developer pickup API -----------> list metadata / exact object
private R2 -> event Queue -> Worker metadata lookup ---------> owned triage webhook
```

There is deliberately no unauthenticated GET, list, update, or delete route. Developer pickup
requires an independent Worker secret that is never distributed with the app. A receipt is a
reference, not a download URL. Nothing automatically mirrors a report into the public source
repository.

## App destinations

The iOS consent screen has three explicit destinations:

1. **Send report** writes a bounded report to the protected iOS outbox and posts it to the private
   intake. Failed network, rate-limit, and 5xx deliveries remain in the outbox and retry when the
   app launches, becomes active, or observes connectivity return while it remains in the
   foreground.
2. **Send to my Threading** appears only for a paired owner whose Mac exposes the Threading
   checkout. It creates a real local agent task over the existing authenticated host route. It
   does not pass through the public service.
3. **Share files…** packages the full support JSON, description, and selected original screenshot
   into one `threading-report-<yyyyMMdd-HHmmss>.zip`, then opens the system share sheet with that
   single attachment. The user chooses the recipient and can inspect the archive first. The stamp
   is the moment the archive was written, so saving a second report neither collides with the
   first nor produces two files a person cannot tell apart.

The macOS Help report, inspector report, and post-crash notice submit the same public DTO with
trigger `manual` or `postCrash`. The inspector strips the temporary PNG path and sends only a
bounded JPEG preview of the image shown to the reporter. A crash submission is opt-in and
contains the share-safe diagnostic summary: launch checkpoints, bounded MetricKit counts/tokens,
and content-free lifecycle records. It does not upload the `.ips` file, EventLog journal, unified
log, stack frames, terminal output, prompts, paths, or credentials. **Show Crash Report** remains
the local route for a user who wants to inspect or share Apple's original artifact themselves.

HTTP is used because reporting is a durable, idempotent mutation. A WebSocket may later deliver a
status notification, but cannot be the only submission record: either app can be suspended after
the server commits but before it receives the response.

The iOS connection-recovery card opens the same reviewed consent screen with trigger
`connectionRecovery`. It does not capture a screenshot automatically and it does not depend on
the paired Mac being reachable. **Send report** therefore remains useful for the exact failure the
card describes: the protected outbox records the reviewed package first and delivers it when an
Internet route is available.

## Public wire contract

`Packages/ThreadingRemoteKit/Contracts/RemoteDiagnosticContract.json` is the shared diagnostic
vocabulary. `scripts/generate_diagnostic_contract.py` projects it into Swift types/policies and
the Worker's TypeScript sets/value classes; generated-file freshness, generator tests, native
policy tests, and the Worker's intake suite all run in `scripts/ci.sh`. The public DTO remains in
`PublicIssueReporting.swift`, and `issue-report-intake.ts` independently revalidates and
normalizes every field because public input is hostile.

- The description is required and capped at 10 KiB.
- Diagnostics use the existing content-free event, field, and additional-detail allowlists. At
  most 250 records are retained and encoded diagnostics are capped at 24 KiB. A Mac report may
  include validated records previously imported from its paired iOS or browser clients; a direct
  iOS report may contain only iOS records. Unsafe local records are omitted before encoding, and
  the Worker independently rejects them if a caller crafts a request around that client gate.
- An explicitly opted-in screenshot becomes an at-most-12-KiB JPEG preview. The original image is
  available only through **Share files…**.
- The whole request is capped at 64 KiB before JSON parsing, including when `Content-Length` is
  absent or false.
- The lowercase UUID is both the protected-outbox key and `Idempotency-Key`. The object key is
  server-derived; an exact retry returns its first receipt, while reuse with different content is
  a conflict.
- Unknown structural object keys, old/future timestamps, control characters in known fields,
  invalid known diagnostic values, mismatched sources, compressed bodies, and non-JPEG previews
  are rejected. Unknown diagnostic field names are dropped and counted. An unknown event drops
  its complete record and is counted; its unrecognized fields are never retained.

The stored object is normalized JSON with a server receipt time, accepted DTO, behavior-only
shared-contract fingerprint, and dropped-field/record counts. The loss counts participate in the
idempotency digest, so two submissions that lost different amounts of evidence are not treated as
one exact retry; the fingerprint is provenance and does not break retries across unrelated
contract deployments. The service does not retain dropped values, the caller's address, or
headers in the object. Worker logs contain only the random report ID, diagnostic source, idempotency outcome,
drop counts, and bounded error code—not request bodies, descriptions, screenshots, addresses, or
credentials.

R2 emits a `PutObject` event only after commit. The bounded Queue consumer looks the object up by
its server-derived key, validates custom metadata, and sends an idempotent triage event containing
only report ID/reference, category (`report`, `crash`, or `diagnostics`), trigger, platform source,
receipt time and size. It never reads the object body. Delivery retries five times and then moves
to a 14-day dead-letter Queue. The receiver credential and pickup credential are independent.

## Abuse boundary

An app-bundled token is not authentication; anyone who can download the app can recover it.
Anonymous reporting therefore remains safe by bounding the work an untrusted caller can cause:

- Cloudflare rejects traffic before storage through the broad source/API limiters, a dedicated
  6-per-minute source limiter, and a 60-per-minute global-key limiter in each edge location.
- An atomic D1 counter containing only UTC day and accepted count admits at most 2,000 new
  objects per day across all edge locations. Exact UUID retries are resolved from R2 first and do
  not consume another slot.
- The Worker refuses oversized or compressed bodies before buffering, validates an exact schema,
  and stores at most one object for each UUID.
- R2 is reachable only through the Worker binding. Keep `r2.dev`, custom domains, public CORS, and
  public credentials disabled.
- The `reports/v1/` lifecycle deletes objects after 30 days. Terraform also owns a zone-level
  host/path/source rule; Worker streaming enforces the 64-KiB body ceiling on plans without WAF
  body fields. Production still needs an early daily-capacity alert and a spend alert. Edge
  rate-limit bindings are per-location abuse protection; D1 is the globally consistent storage
  ceiling.

App Attest can later strengthen iOS submissions, but it is not the trust boundary and cannot be a
universal requirement because the service is unavailable on macOS. Authenticated Threading
accounts should receive reserved capacity once both apps can present account credentials;
post-crash reporting must still work before sign-in. Client proof-of-work may raise an attacker's
cost, but does not identify a legitimate installation. The production runbook therefore combines
edge/body limits, global D1 admission, early alerts, spend limits, and an emergency intake-disable
procedure rather than treating one client-side signal as a complete denial-of-service solution.

## Deployment and pickup

The release-blocking checklist is `docs/operations/issue-reporting-setup.md`. It covers bucket
creation, private access, lifecycle, D1, WAF/body rules, capacity and spend alerts, the developer
credential, metadata-only new-report notification, pickup smoke tests, credential rotation, and
privacy verification. `/ready` fails if the bucket binding cannot answer a metadata probe or the
developer pickup secret is absent.

The developer-only routes are:

```text
GET /v1/developer/reports?limit=50&cursor=...   metadata-only inbox page
GET /v1/developer/reports/<lowercase-uuid>      one exact stored envelope
```

Both require `Authorization: Bearer <REPORT_PICKUP_TOKEN>`. Listing never includes reporter prose
or screenshot data. The exact-object route returns untrusted customer evidence and must be used
only by a protected operator or triage client.

Reports are customer data, not executable tasks. A developer or a dedicated triage tool retrieves
one object by receipt, treats all reporter-controlled values as untrusted evidence, and creates a
sanitized public issue only when it contains no private material. Automatic agent pickup must
wrap the DTO as inert input and must never turn the description into instructions.

The share-safe failure-to-diagnostic matrix and its extension gate live in
`docs/architecture/issue-report-diagnostics.md`. Operational logs that cannot meet that typed
boundary remain local by design; they are not bulk-copied into a report.

## Privacy and local durability

- Submission happens only after the reporter reviews the selected fields and presses a send
  action.
- The diagnostic base excludes messages, prompts, paths, notification text, device names, stable
  identifiers, raw crash material, and credentials. Additional device context is separately
  opt-in and comes from an explicit enum.
- Pending iOS reports use complete file protection. The outbox holds at most 20 reports and
  refuses another instead of deleting an older unsent one.
- A report older than the intake window is rejected and removed as non-retryable; R2 removes an
  accepted report after 30 days.
- Raw local journals remain local unless the user explicitly chooses **Share files…**.
