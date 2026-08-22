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
| Manual, inspector and connection-recovery reporting | `issueReportOpened`, submission started/succeeded/deferred/failed; surface and trigger tokens | Inspector PNG path, full-resolution capture, clipboard contents |
| Report delivery | One trace per idempotent report ID, 30-second HTTPS timeout, duration, structural error/status and delivered/queued/failed result; protected iOS outbox retries at launch, foreground entry and foreground connectivity return | HTTP body logging, caller address, authorization headers |
| Pairing and host connectivity | pairing, catalogue refresh, mutation/notification failover, discovery resolution and hosted-credential provisioning; bounded route phase, attempt/total, timeout, duration, cancellation and winning-transport tokens | invitation URLs, bearers, raw origins, host/device names, request/response bodies |
| Remote listener and live transports | listener/door/socket lifecycle, protocol versions, explicit session and dashboard-event hello deadlines, reconnect attempt/backoff, pseudonymous peer/session tokens; hosted setup exposes only rendezvous/host-wait/offer/ICE/proxy stage names; `relayFailed` keeps its legacy name and carries a `TailscaleReadinessIssue` code beside its reason | SDP, ICE candidates or addresses, terminal/event frames and connection credentials |
| Permission decisions | sent/received and capability/result tokens | command text, tool input, provider evidence |
| Notifications | authorization, registration, provider, received/suppressed/presented/opened state tokens | notification title/body, push token, session title |
| Optional environment | counts, enums, versions, permission states, memory/storage buckets | project/session/account names, stable identifiers, paths |

The repository-root `./dev` launcher directs both Debug apps at the loopback report intake. The
macOS `THREADING_REPORT_INTAKE_URL` override is compiled only into Debug builds; a production app
cannot redirect reviewed customer reports through its process environment.

An endpoint is stated or absent, never assumed: with neither the Debug override nor Info.plist's
`ThreadingReportIntakeURL`, the Mac writes its record and posts nothing, and the sheet says
**saved** rather than queued. A shipping build therefore has to set the Info.plist key or it
delivers nothing at all, which is a release-checklist item rather than a default. See
[`github.md`](github.md#where-a-private-report-goes-macissuereportoutbox).

**The iPhone follows the same rule, and did not.** `MobileIssueReportOutbox` carried a compiled-in
`https://remote.threading.codes/v1/reports` fallback, which is what the 2026-08-21 support report
is full of: 250 deliveries, every one `url.-1200` in a few hundred milliseconds, and not one
success in the whole journal. The host is not serving the intake — its DNS is the domain
registrar's parking record, and the address behind it answers a TLS ClientHello with a
`handshake_failure` alert and no certificate at all — so the fallback was never a safety net,
only a guess that could not succeed, spending the phone's radio and the report's own bounded
journal ring proving it. The fallback is gone; a phone with no stated intake keeps its records and
makes no attempt, and the sheet says the report was saved and can be shared.

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

The Worker independently carries the same event/field allowlists. Adding a native event without
adding and testing the corresponding intake event is incomplete because the server will reject
the report. A platform log with no safe representation is not automatically a blind spot: it is
local-only by design until a concrete triage question justifies a new typed token.

## Review gate for new coverage

Before adding a field, state the exact triage question it answers and confirm that the value is a
bounded count, enum, version, timestamp, or locally pseudonymised identifier. Then update the
shared native vocabulary, Worker allowlist, contract tests, and this matrix together. Free-form
error text belongs in local logs, never in the diagnostic journal.
