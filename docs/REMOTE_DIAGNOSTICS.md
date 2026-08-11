# Remote diagnostics and support plan

Remote access spans one Mac, one or more selected transports, memberships, live WebSockets, APNs
and one or more iOS devices. A useful report must answer **where a flow stopped** without collecting the
chat, repository, notification text, or credentials.

## Support workflow

1. The reporter shakes the affected iPhone from the screen where the problem happened, or opens
   **Diagnostics** and chooses **Report a problem**.
2. A shake asks whether to continue without a screenshot or capture the current screen. The
   screenshot is taken only after that choice, previewed in the report and removable.
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

## Diagnostic contract

`ThreadingRemoteKit` owns a versioned, append-only event schema used on every native surface.
Events describe state transitions; they do not contain user content.

Every record has:

- UTC timestamp, source (`macOSHost`, `iOSClient`, `browserClient`) and severity.
- A typed event name and allowlisted structural fields.
- A per-operation `trace` where the protocol already has one. Notification event ids are traces;
  APNs' `apns-id` is stored as the provider trace.
- Locally pseudonymised `peer` and `session` ids when grouping is necessary.
- App/build, OS and remote-protocol versions in the report manifest.

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

iOS also has a local unified-log fallback at `codes.threading.mobile/diagnostics` for ordinary
screen and persistence failures that may occur before a share-safe remote event exists. Those
records contain only a fixed surface enum plus a fixed failure code or numeric error domain/code;
localized descriptions, hosts, URLs, paths, titles, attachment names and credentials cannot be
represented by the API.

Client-to-Mac upload has a second trust boundary: only an interactive all-sessions owner bearer
may call it; the declared source must match the shipping client header; batches are capped at 250
records and 256 KiB; timestamps, client-appropriate events and fields are revalidated; and values
must be compact machine tokens rather than prose, URLs or paths. The authenticated device id is
replaced with a Mac-side pseudonym. Raw console logs and the Mac's content-bearing diagnostics log
never use this route.

### Explicitly optional attachments and context

- A reporter description is a separate text attachment and is shared exactly as written.
- A screenshot is never taken merely because the phone was shaken. The user selects it in a
  preflight prompt, sees the image that will leave the phone, and can remove it before sharing.
- Additional device details are off by default. The allowlist covers model, idiom, locale,
  preferred language, time zone, power/thermal/storage/display state, app/connection state,
  counts, capability/scope and notification state.
- Optional context still excludes names and stable device, host, account or session identifiers.

### Never recorded

- Bearer tokens, invitation links or APNs device tokens.
- Prompt, response, terminal, diff, filename, path, project or notification content.
- Member, device, account, repository or Mac display names.
- Raw request URLs; an error description can contain the credential-bearing fragment.
- Clipboard, photo, attachment or voice contents.

Errors are stored as stable codes such as `remote.http.401`, `remote.upgradeRequired` or a
`URLError.Code`, never `localizedDescription`.

## Correlation model

The protocol needs operation ids rather than relying on stable personal identifiers:

| Flow | Correlation |
|---|---|
| Notification | Existing notification event id → APNs `apns-id` → opened event |
| REST request | Add `X-Threading-Trace` request/response header |
| WebSocket | Add optional connection trace to `hello`; reuse it for end/failure |
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
- Shake-to-report with screenshot preflight, attachment preview and manual Diagnostics fallback.
- Off-by-default, typed additional-device-details manifest.
- iOS notification, registration, host refresh and session-socket transitions.
- Durable Mac remote journal and one-click share-safe support report.
- Browser privacy-bounded local journal plus explicit 30-minute iOS/browser forwarding into the
  paired Mac's share-safe timeline.
- Mac listener, transport, auth, registration, socket, permission and APNs transitions.
- Mac APNs acceptance/refusal records with notification trace and `apns-id`.
- Opt-in real APNs and Claude → MCP → APNs tests in `ThreadingNotificationE2E`.

### Phase 1 — cross-device traces

- HTTP trace header, WebSocket connection trace and host timestamps.
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
