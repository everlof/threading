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
| Manual and inspector reporting | `issueReportOpened`, submission started/succeeded/deferred/failed; surface and trigger tokens | Inspector PNG path, full-resolution capture, clipboard contents |
| Report delivery | Idempotent report ID in the receipt plus delivered/queued/failed result token | HTTP body logging, caller address, authorization headers |
| Pairing and host credentials | pairing/refresh success or failure, transport/result/code tokens | invitation URLs, bearer material, host/device names |
| Remote listener and relay | listener/relay/socket lifecycle, protocol versions, pseudonymous peer/session tokens | SDP, ICE addresses, terminal data and connection credentials |
| Permission decisions | sent/received and capability/result tokens | command text, tool input, provider evidence |
| Notifications | authorization, registration, provider, received/suppressed/presented/opened state tokens | notification title/body, push token, session title |
| Optional environment | counts, enums, versions, permission states, memory/storage buckets | project/session/account names, stable identifiers, paths |

The Worker independently carries the same event/field allowlists. Adding a native event without
adding and testing the corresponding intake event is incomplete because the server will reject
the report. A platform log with no safe representation is not automatically a blind spot: it is
local-only by design until a concrete triage question justifies a new typed token.

## Review gate for new coverage

Before adding a field, state the exact triage question it answers and confirm that the value is a
bounded count, enum, version, timestamp, or locally pseudonymised identifier. Then update the
shared native vocabulary, Worker allowlist, contract tests, and this matrix together. Free-form
error text belongs in local logs, never in the diagnostic journal.
