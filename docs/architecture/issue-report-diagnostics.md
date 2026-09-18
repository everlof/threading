# Issue-report diagnostic coverage

The private report is not a dump of operational logs. It is a bounded reconstruction made from
typed events and structural fields that are safe to share without reviewing raw logs. Add an
event at the failure seam when a report cannot otherwise answer a triage question; do not copy an
OSLog, EventLog, error description, URL, path, prompt, transcript, notification body, stack trace,
credential, or device/account name into this vocabulary.

## Coverage matrix

| Failure seam | Share-safe evidence in a report | Deliberately local evidence |
| --- | --- | --- |
| App launch and crash recovery | `appLaunched`, `uncleanExitDetected`, `recoveryModeEntered`; launch verdict, last checkpoint, bounded MetricKit crash tokens | `.ips` files, call trees, addresses, raw EventLog and unified log |
| Manual, inspector and connection-recovery reporting | `issueReportOpened`, submission started/succeeded/deferred/failed; surface and trigger tokens; up to four explicitly reviewed 12 KB JPEG previews in the private report body | Inspector PNG path, selected-image paths, full-resolution originals in the local outbox, clipboard contents |
| Report delivery | One trace per idempotent report ID, 30-second HTTPS timeout, duration, structural error/status and delivered/queued/failed result; protected iOS outbox retries at launch, foreground entry and foreground connectivity return | HTTP body logging, caller address, authorization headers |
| Attachment preview | Bounded `attachmentPreviewHistory` records start/ok/fail/cancel/skip in order; a terminal failure adds `attachmentPreviewFailed` with only kind and structural error code | Attachment name/path/id, bytes, localized error text, normal success/cancellation journal traffic |
| Pairing and host connectivity | pairing, catalogue refresh, mutation/notification failover, discovery resolution and hosted-credential provisioning; bounded route phase, attempt/total, timeout, duration, cancellation and winning-transport tokens | invitation URLs, bearers, raw origins, host/device names, request/response bodies |
| Remote listener and live transports | listener/door/socket lifecycle, protocol versions, explicit session and dashboard-event hello deadlines, reconnect attempt/backoff, pseudonymous peer/session tokens; hosted setup exposes only rendezvous/host-wait/offer/ICE/proxy stage names; `relayFailed` keeps its legacy name and carries a `TailscaleReadinessIssue` code beside its reason | SDP, ICE candidates or addresses, terminal/event frames and connection credentials |
| Opening a chat | `sessionOpenStarted`/`Progress`/`Ended` from the tap to a usable surface: fixed stages (catalogue, wake, socket, retry, hello) with cumulative duration, pooled/fresh/woken path, how the surface was revealed (hello, boundary, quiet, ceiling), and a closed agent-runtime token; the host's `terminalHydrationEnded` gives the resize hold, why it ended and how many output bursts it saw | session title, terminal bytes, prompt text, the raw `agentKind` string a Mac sends |
| Permission decisions | sent/received and capability/result tokens | command text, tool input, provider evidence |
| Notifications | authorization, registration, provider, received/suppressed/presented/opened state tokens | notification title/body, push token, session title |
| Optional environment | counts, enums, versions, permission states, memory/storage buckets | project/session/account names, stable identifiers, paths |

The repository-root `./dev` launcher directs both Debug apps at the loopback report intake. The
macOS `THREADING_REPORT_INTAKE_URL` process override is compiled only into Debug builds; a
production Mac app cannot redirect reviewed customer reports through its environment. The iOS
target makes the same distinction in Xcode build settings: Debug expands the plist value to an
empty string, while Release names `https://remote.threading.codes/v1/reports`.

An endpoint is stated or absent, never assumed: with neither the Debug override nor Info.plist's
`ThreadingReportIntakeURL`, the Mac writes its record and posts nothing, and the sheet says
**saved** rather than queued. A shipping build therefore has to set the Info.plist key or it
delivers nothing at all, which is a release-checklist item rather than a default. See
[`github.md`](github.md#where-a-private-report-goes-macissuereportoutbox).

The iPhone used to violate that rule with a compiled-in fallback aimed at this hostname before it
served the intake. The 2026-08-21 support report contains 250 failed handshakes and no success.
That fallback remains gone: a phone with no stated intake keeps its records, makes no attempt, and
says the report was saved. The shipping destination is now an explicit source-controlled Release
property in `Sources/ThreadingMobile-Info.plist` and the `ThreadingMobile` target, and
`test_mobile_report_intake_configuration.py` keeps Debug off and Release pointed at the reviewed
private Worker. A release-candidate receipt is still an operations check; source configuration is
not evidence that the deployed service answered that particular build.

Delivery that *is* configured now goes through `RemoteClient.deliverIssueReport`, whose session
shares the one `RemoteCertificatePinningDelegate` with every REST call and socket. It was
`URLSession.shared`, which is the one session in the app that cannot be given a delegate: report
delivery was the single network path where nothing could decide what to do about the certificate
it was offered and nothing recorded what was decided, which is why the incident's journal cannot
say whether an identity check passed, refused, or never ran.

Automatic retries back off. `flush()` runs at launch, on every foreground, and on every satisfied
path update, and a phone moving between a dead Wi-Fi and a tailnet produces those constantly;
nothing stood between an undeliverable report and an unbounded number of handshakes. A failed
delivery now earns 30 seconds, doubling to a ceiling of 15 minutes, recorded in the deferred
record's `attempt` and `delayMS`. A person tapping Send is a fresh instruction and never waits for
a backoff.

The vocabulary is not mirrored by hand. The authoritative manifest is
`Packages/ThreadingRemoteKit/Contracts/RemoteDiagnosticContract.json`; running
`scripts/generate_diagnostic_contract.py` produces the Swift enums/policies and the Worker
events, value classes, and source-scoped additional-detail sets. Architecture checks compare the
generated files byte-for-byte, and CI tests the generator plus the Worker's intake suite. Adding
a field or event anywhere else is incomplete by construction.

The Worker is the one public intake; the old `web/app/api/reports/route.ts` experiment is not a
shipping route or a second contract projection. At deploy-version skew, unknown additional-detail
or known-event field names are dropped without reading them into the stored DTO, and an unknown
event drops its complete record. The stored envelope carries a behavior-only contract fingerprint
plus `droppedUnknownFieldCount` and `droppedUnknownRecordCount`, and those counts participate in
idempotency. Known names still have every byte, alphabet, numeric, pseudonym, source, timestamp,
record-count, and body-size check. Unknown structural object keys and malformed known values still
reject the request. This preserves the privacy boundary while making a newer app lose one piece
of evidence rather than the person's entire report.

A platform log with no safe representation is not automatically a blind spot: it is local-only
by design until a concrete triage question justifies a new typed token.

## Review gate for new coverage

Before adding a field, state the exact triage question it answers and confirm that the value is a
bounded count, enum, version, timestamp, or locally pseudonymised identifier. Then edit the shared
manifest, regenerate both projections, add behavior tests, and update this matrix. Never edit a
generated projection or add a second hand-maintained allowlist. Free-form error text belongs in
local logs, never in the diagnostic journal.

## Deployment compatibility and failed deliveries

A successful `/ready` does not prove that production understands a shipping report. The 0.2.0
app always emitted `simulatorStreaming`, while the August 24 Worker still rejected that unknown
additional-detail field. Reviewed image arrays and newer diagnostic vocabulary had also not been
deployed. The release had checked TLS and local tests, not the deployed intake contract.

`scripts/verify_report_deployment.mjs` now asks `ReportDeploymentContractTests` to encode fixtures
using the shipping Swift DTOs: every diagnostic event/source, field validation class, additional
field and both image representations. `POST /v1/reports/validate` runs the same bounded parser,
rate limits and idempotency check as submission, but never stores or consumes daily capacity.
The gate requires an exact validation receipt and zero dropped fields/records. It runs before
local release refs move, before direct release archives, and after a production server deploy. The production deploy and CI also run these exact Swift
fixtures through the candidate Worker before any server deployment or database migration.
Unknown fields remain safely droppable for old clients; deployment probes require full evidence.

The control plane records handled 400, 409, 413, 415, 429 and 5xx failures for its six API route
families in D1, grouped into 15-minute windows. Expected 401/403/404 responses and validation
probes do not page. Rows carry only route family, HTTP status and count; console diagnostics add
server-owned error codes and validation reasons, never submitted values. Closed windows are
forwarded through the existing owned receiver to Pushover on the quarter-hour cron. Successful
alerts remove only the exact observed count; concurrent increments survive for another alert.
Failed alert delivery retains the row for retry, with seven-day bounded retention and at most
64 rows processed per run. Monitoring failure never replaces the original HTTP response.

This covers requests reaching our Worker. Cloudflare edge rejections, offline/TLS failures and
third-party APIs are outside that counter; they require edge or client-side monitoring. A
Pushover outage is logged and retried, not a guarantee of immediate notification.
