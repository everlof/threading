# Remote diagnostics and support plan

Remote access spans one Mac, one or more selected transports, memberships, live WebSockets, APNs
and one or more iOS devices. A useful report must answer **where a flow stopped** without collecting the
chat, repository, notification text, or credentials.

## Support workflow

1. The reporter shakes the affected iPhone from the screen where the problem happened, or opens
   **Diagnostics** and chooses **Report a problem**.
2. A shake captures the screen it happened on and opens the report over it. The image stays on
   the phone: the switch on the report's own **Current screen** row decides whether it is part
   of the report, the sheet previews it under that row at full size while it is, and dismissing
   the sheet discards it.
3. The report composer accepts a user-written description. Additional device details are a
   separate, off-by-default opt-in and are gathered only when the user shares.
4. The Diagnostics page shows current protocol, Mac reachability, notification authorization, APNs token
   state and whether that Mac registered `push`, `live only`, or nothing.
5. A paired owner may choose **Share diagnostics for 30 minutes**. iOS or the browser sends its
   existing bounded history and new connection events to that Mac until the timer expires, the
   user stops it, or the client closes. Sharing is off by default and never survives an app/page
   reload.
6. **Share diagnostics only** exports the bounded JSON report without a description, optional
   device details or screenshot.
7. The Mac owner chooses Help → **Create Remote Support Report…**. The share-safe Mac report
   follows the same schema. **Reveal Diagnostics Log** remains separate because the owner-local
   journal can contain prompts, commands and paths and must not be attached blindly.
8. Support merges the two timelines by trace id and timestamps. If clocks differ, the handshake
   offset recorded by the clients is applied before comparison.

A report should make the common answer mechanical:

```text
iOS permission allowed
→ APNs token acquired
→ registration reached Mac
→ Mac selected member/device subscription
→ APNs accepted event (apns-id)
→ iOS received/opened event
```

The first missing transition identifies the owner: app permission, transport/auth, membership
routing, provider credentials, Apple delivery, or presentation policy.

Catalogue connectivity has the same reconstructable shape:

```text
hostRefreshStarted(trace)
├─ ≤4 private lanes: request(s) → succeeded / failed / cancelled
└─ hosted prepare: rendezvous → awaitingHost → offer → ICE → proxy
                   then request → succeeded / failed / cancelled
hostRefreshSucceeded(winning transport) / hostRefreshFailed
```

Only the read-only catalogue races: Hosted Direct runs beside at most four private-network lanes.
LAN and VPN each use one lane; Tailscale may use two so IPv4 and IPv6 doors do not block each
other. A door and its ten-port sticky range remain one sequential bounded walk inside a lane.
Paired `hostRouteStarted` / `hostRouteEnded` records own each lifecycle;
bounded `hostRouteProgress` records name the coarse hosted stages. Each route records `phase`,
`attempt`/`total`, `wave`, configured
`timeoutMS`, monotonic `durationMS`, structural error/status, and terminal result. `wave` is one of
three fixed tokens — `route`, `address`, `port` — naming which pass of the walk the attempt belongs
to. `attempt` alone cannot say why a walk was long: twenty attempts against one address nothing was
listening at, and twenty attempts against twenty addresses, look identical without it, and telling
them apart was the whole of the 2026-08-21 diagnosis. A walk that
abandons the rest of a door adds one `hostRouteEnded` with `result: skipped`, the `reason` it
ended (`door.answered` or `door.unreachable`), the failure code behind it, and in `detail` the number of
attempts it stood in for — one record per door, never one per skipped port, so an early stop reads
as a decision rather than as a gap in the attempt numbers. Only a response or a definitive
DNS/routing failure ends a door; a generic request timeout remains scoped to its attempted port.
Each catalogue request's terminal record also carries URLSession's last completed transaction as
bounded phase evidence: the furthest `networkStage`, completed DNS/TCP/TLS/server-wait/response
durations, fixed protocol and cellular/expense/constraint flags, and whether the connection was
reused. An absent duration is evidence too — `networkStage: tls` without `tlsMS` means the request
ended during that phase — so the next long handoff can distinguish tunnel/network establishment,
TLS, and a Mac that accepted a request but delayed its first byte. These fields contain no host,
address, interface name, URL, or payload. The transport kind travels from the Mac's advertised
candidate into downstream socket diagnostics; it is not re-guessed from an IP address that could
equally be LAN, VPN, or Tailscale.
A live session similarly carries one local trace through `socketConnecting`, `socketConnected` or
`socketFailed`/`socketEnded`, and `socketReconnectScheduled` records the next attempt and bounded
backoff delay. The dashboard event socket follows the same contract and has its own 15-second
hello deadline, so an accepted TCP/WebSocket connection that never produces its authoritative
first frame cannot disappear into an infinite wait. Pairing, sequential mutation and notification
failover, local discovery resolution, hosted-credential provisioning, and report-outbox delivery
also record their configured timeout and terminal outcome. No frame, payload, SDP, ICE candidate,
report body, or network address is logged.

## Diagnostic contract

`ThreadingRemoteKit` owns a versioned, append-only event schema used on every native surface.
Events describe state transitions; they do not contain user content.

Every record has:

- UTC timestamp, source (`macOSHost`, `iOSClient`, `browserClient`) and severity.
- A typed event name and allowlisted structural fields.
- A per-operation `trace` where the protocol already has one. Notification event ids are traces;
  APNs' `apns-id` is stored as the provider trace.
- Locally pseudonymised `peer` and `session` ids when grouping is necessary.
- A pseudonymised `origin` on every connect and connect failure, beside the `transport` kind. An
  address is a routable location of someone's machine, so only its scheme, host and port are
  hashed, and the shared upload policy refuses an `origin` value that is not already in that
  shape. Both sides derive it the same way, which is the only reason a joined report can say
  whether a phone was pointed at the address the Mac published. Without it, "wrong address" and
  "right address, host down" are the same record and have opposite fixes.
- An optional `detail` beside `code` or `reason`, carrying the bounded machine values behind a
  refusal. A rejected viewport, for example, records the clause that refused and the grid that
  was asked for.
- App/build, OS and remote-protocol versions in the report manifest.

Every connect reaches a terminal event. A socket that opens and is never greeted is ended by a
client-side hello deadline rather than awaited, because `URLSessionWebSocketTask` honours no
resource timeout and would otherwise leave a report that stops after `socketConnecting`. Where
URLSession kept the HTTP response behind a `NSURLErrorBadServerResponse`, its status is recorded
too: 530, 502 and 404 behind the same error code mean three different things.

The shared writer strips control characters, bounds each value, keeps seven days, and caps an
export at 5,000 newest events. Report assembly prunes before reading, accepts only regular files
with the exact `remote-diagnostics-YYYY-MM-DD.jsonl` spelling, and reads at most the newest 8 MiB
of each journal. A partial first line and any record above 64 KiB are discarded. The bound is
enforced on the opened file, so an externally enlarged or replaced journal cannot make a support
report allocate the whole file merely to throw away its old prefix.

The journal cannot write its own storage failures into itself. `ThreadingRemoteKit` therefore
emits a separate, rate-bounded storage-health event to the embedding app's unified logger. That
event carries only a fixed stage, `posix`/`cocoa`/`other` domain, numeric error code and affected
count; it cannot represent a path or error description. macOS and iOS both log the first failure
and its recovery, while a persistent failure is repeated at most once per minute per stage.

iOS also mirrors connectivity lifecycle events to the local unified-log category
`codes.threading.mobile/diagnostics`, alongside its fallback for ordinary screen and persistence
failures that may occur before a share-safe remote event exists. Connectivity lines contain only
event, trace, pseudonymous peer, hashed origin, phase, transport, surface, result, structural
code/status, duration, configured timeout, reconnect delay, bounded network-phase metrics and
attempt position; fallback records contain a fixed surface enum plus a fixed failure code or
numeric error domain/code.
Localized descriptions, hosts, URLs, paths, titles, attachment names and credentials cannot be
represented by either API.

Client-to-Mac upload has a second trust boundary: only an interactive all-sessions owner bearer
may call it; the declared source must match the shipping client header; batches are capped at 250
records and 256 KiB; timestamps, client-appropriate events and fields are revalidated; and values
must be compact machine tokens rather than prose, URLs or paths. The authenticated device id is
replaced with a Mac-side pseudonym. Raw console logs and the Mac's content-bearing diagnostics log
never use this route.

### Explicitly optional attachments and context

- A reporter description is a separate text attachment and is shared exactly as written.
- A screenshot is captured locally when the phone is shaken, because a prompt asking permission
  first is a prompt standing in front of the evidence. Capturing is not sharing: the image is held
  in the report request, the user sees the exact picture that would leave the phone, and it leaves
  only when the **Current screen** switch is still on as they send or share. A report opened from
  Diagnostics or the connection-recovery card captures nothing, since the screen it would take is
  the sheet itself.
- Additional device details are off by default. The allowlist covers model, idiom, locale,
  preferred language, time zone, power/thermal/storage/display state, app/connection state,
  counts, capability/scope and notification state. Connection state is carried as a bounded ring
  of its last transitions with their ages, not only as the current value, since a phone that
  never reached the Mac and one that reached it and dropped otherwise produce identical headers.
- Optional context still excludes names and stable device, host, account or session identifiers.

### Never recorded

- Bearer tokens, invitation links or APNs device tokens.
- Prompt, response, terminal, diff, filename, path, project or notification content.
- Member, device, account, repository or Mac display names.
- Raw request URLs; an error description can contain the credential-bearing fragment.
- Any address, on either side: the one a client aimed at and the one a Mac advertised are both
  recorded only as `origin` hashes, and the hash covers scheme, host and port so a pairing URL's
  bearer fragment cannot reach it.
- Clipboard, photo, attachment or voice contents.

Errors are stored as stable codes such as `remote.http.401`, `remote.upgradeRequired` or a
`URLError.Code`, never `localizedDescription`.

## Correlation model

The protocol needs operation ids rather than relying on stable personal identifiers:

| Flow | Correlation |
|---|---|
| Notification | Existing notification event id → APNs `apns-id` → opened event |
| REST request | Add `X-Threading-Trace` request/response header |
| WebSocket | A local connection trace already joins hello/end/failure/reconnect; a future optional wire trace joins it to the Mac |
| Permission | Existing permission request id plus WebSocket connection trace |
| Invitation acceptance | Request trace becomes the first membership trace |
| Hosted Firebase/FCM | Preserve the same trace through Cloud Function and FCM/APNs |

Optional fields must be introduced compatibly; diagnostics must never force an otherwise
compatible old client to update.

## Health checks

Checks are read-only unless the user explicitly chooses a test delivery.

### iOS

- Notification authorization and APNs token presence/environment.
- Active Mac reachability, HTTP status and remote-protocol compatibility.
- Membership scope/capability and permission-approval capability.
- Notification registration result per pseudonymised peer.
- WebSocket handshake, last successful frame, reconnect count and close code.
- App/Mac clock offset from a host timestamp.
- A separately confirmed **Send test notification** action, labelled with the exact target
  device and environment.

### macOS

- Loopback listener plus the selected Cloudflare and/or Tailscale transport state. A Tailscale
  failure records the typed prerequisite that needs attention (installation, sign-in/running,
  or HTTPS publishing) rather than including CLI output, hostnames or URLs.
- The iPhone records the selected policy-approved transport and socket reconnect events using
  transport kind and pseudonymised host identity only; endpoint addresses and request ids are
  excluded.
- APNs provider key load, team/key/topic presence and key age without exposing their values.
- Subscription matrix counts by owner/member, notification kind, environment and approval
  capability—never tokens or names.
- Last APNs outcome and provider trace per notification event.
- Connected socket count, slow-consumer drops, auth/rate-limit denials and protocol mismatches.
- Agent/MCP availability for `notify_user`.

### Multi-device view

The Mac diagnostics page should show one row per pseudonymised membership/device:

```text
device-a81f2c  Owner · Interactive · Approvals on · APNs sandbox · last seen 2m
device-42d019  Member · Chat only · Approvals off · Live only · last seen 1h
```

Actions remain capability-scoped: run a test for this device, revoke this membership, or copy
its report code. A guest can export its own report but cannot inspect another participant.

## Delivery phases

### Phase 0 — foundation (implemented)

- Shared privacy-bounded JSONL schema and report manifest.
- Durable iOS journal and Diagnostics sheet with live status, checks and export.
- Shake-to-report with an on-device capture, an inclusion switch on the row it is about,
  attachment preview and a manual Diagnostics fallback.
- Off-by-default, typed additional-device-details manifest.
- iOS notification and registration transitions; fully traced host refresh route racing and
  session socket hello/failure/end/reconnect lifecycles.
- Durable Mac remote journal and one-click share-safe support report.
- Browser privacy-bounded local journal plus explicit 30-minute iOS/browser forwarding into the
  paired Mac's share-safe timeline.
- Mac listener, transport, auth, registration, socket, permission and APNs transitions.
- Mac APNs acceptance/refusal records with notification trace and `apns-id`.
- Opt-in real APNs and Claude → MCP → APNs tests in `ThreadingNotificationE2E`.

### Phase 1 — cross-device traces

- HTTP trace header, WebSocket wire propagation and host timestamps.
- Optional Mac Support Bundle with explicitly redacted owner-local `EventLog` records.
- A small local timeline merger that explains gaps and clock offsets.
- Unit/integration tests proving credentials and content cannot enter a report.

### Phase 2 — guided diagnosis

- Mac diagnostics page and multi-device subscription matrix.
- Explicit per-device test notification with a visible trace/result on both devices.
- Check results phrased as actionable fixes, not raw transport errors.
- Report code shown on both sides so two files can be paired without device names.

### Phase 3 — operated service

- Consent-gated crash/error reporting for release builds.
- Firebase/FCM relay stages preserving the app trace id.
- Server-side aggregate health metrics with no transcript or stable personal identifiers.
- Expiring remote support upload, user-visible before submission and deletable by report code.

Hosted telemetry is additive. Local/self-hosted users retain the same on-device reports and
checks without Firebase.
