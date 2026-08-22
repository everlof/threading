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

The Worker independently carries the same event/field allowlists. Adding a native event without
adding and testing the corresponding intake event is incomplete because the server will reject
the report. A platform log with no safe representation is not automatically a blind spot: it is
local-only by design until a concrete triage question justifies a new typed token.

## Review gate for new coverage

Before adding a field, state the exact triage question it answers and confirm that the value is a
bounded count, enum, version, timestamp, or locally pseudonymised identifier. Then update the
shared native vocabulary, Worker allowlist, contract tests, and this matrix together. Free-form
error text belongs in local logs, never in the diagnostic journal.
