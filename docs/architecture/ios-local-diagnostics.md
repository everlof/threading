# Local iOS diagnostics

> Status: **implemented, shipping, opt-in** (2026-08-22).

Read alongside [`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md) for pairing and the dashboard event
socket, [`persistence.md`](persistence.md) for durable diagnostics and privacy, and
[`mcp-and-display.md`](mcp-and-display.md) for typed agent tools and image results.

## Contract

Local diagnostics lets a paired owner iPhone give its Mac a bounded, content-free operational
capture over Threading's selected LAN route. A local agent can request fresh evidence later, or
inspect the newest bounded Mac cache when the phone is offline. If the person separately enables
automatic error screenshots on the phone, an error record may also retain the Threading window in
a three-image device-local ring for the next offload.

This is shipping code, but it is inert until two independent switches are on:

- **Mac:** Settings > Advanced > Local Diagnostics > **Allow paired-iPhone checkups**.
- **iPhone:** Settings > Advanced > Device checkups > Local diagnostics.

Both default off on a fresh install. Turning either switch off immediately stops new requests;
turning it back on takes effect on an already-authenticated socket without an app restart. The
Mac retains cached evidence until **Clear Evidence** is pressed. The iPhone keeps its screenshot
ring until **Clear error screenshots** is pressed.

## How to ask for a checkup

Use this prompt:

> **Check up on my iOS app usage. Use the newest cached evidence if my phone is offline, and tell
> me whether the evidence is fresh or cached.**

The short version also works:

> **Check up on my iOS app usage.**

The agent should call `inspect_ios_diagnostics`, select the only phone when no device id was
given, request fresh evidence, and explicitly label the result `fresh` or `cached`. With several
phones, `list_ios_diagnostic_devices` exposes their opaque ids and the agent asks which one to
inspect. Useful deliberate variants are:

- **Do a fresh iOS checkup now and include a screenshot of the current screen.** This selects the
  explicit `current` screenshot policy.
- **Check the latest iOS error without taking a new screenshot.** This uses the retained incident
  image, if present, without photographing the current screen.
- **Use only cached evidence for an iOS checkup.** This does not contact the phone.

The tools explain the two settings paths when either side has not opted in.

## Phone behavior

The iPhone Local diagnostics page shows both consent switches, the route, the last successful
upload, a bounded failure code, the retained error-screenshot count, a clear action, and the
ordinary-language agent prompt.

After the authenticated `/ws/events` socket receives its authoritative first frame, the phone
announces diagnostics only when its switch is on, the active pairing is the owner, and its
selected endpoint kind is `lan`. If the Mac switch is also on, the Mac immediately requests a
normal capture, throttled to one automatic request per device per minute. The Mac still records
the authenticated live phone while its switch is off so enabling can issue that first request
without requiring a reconnect; it does not mint a nonce or accept evidence while off.

Every `.error` record schedules an incident capture after 300 milliseconds only when both iPhone
switches are on and the app is foreground-active. Captures have a 60-second cooldown, use the
existing Threading-window renderer, are JPEG-compressed below 420 KiB, and are pruned to three
files. A consent generation token cancels a capture that was already waiting when either switch
is turned off. There is no attempt to render after a crash, suspension, or termination.

The default request uses `latestIncident`: it never takes a screenshot merely because a checkup
ran. `current` is an explicit tool argument and renders the current Threading window at request
time. `none` sends no image.

## Evidence boundary

A capture contains fixed fields only:

- app version/build, iOS version and machine model;
- app lifecycle state and connection phase;
- the selected endpoint kind;
- paired-host and visible-session counts;
- up to the existing diagnostic journal's bounded maximum records;
- optionally one JPEG and the closed provenance value `incident` or `current`.

The diagnostics reuse `RemoteDiagnosticRecord` and `RemoteDiagnosticUploadPolicy`. That policy
admits only known events and allowlisted, bounded structural fields. Prompts, terminal output,
paths, URLs, credentials, notification text, request bodies and arbitrary log prose do not fit the
wire type. “All logs” here therefore means all retained records the structured Threading journal
deliberately owns, not iOS unified logs or strings emitted by dependencies.

Failed REST requests contribute their stable refusal code (for example `unknownModel`) and HTTP
status, never the response prose or request body. A phone talking to an older Mac records the
status-only fallback; a future code is reduced to the journal's bounded machine-token alphabet
instead of being discarded. This is enough to identify the failed guard without exposing the
project, account, prompt or selected value that reached it.

The screenshot is the sole content-bearing exception. An incident screenshot requires the
separate iPhone switch and is limited to the foreground app window. A current screenshot is taken
only for the agent tool's explicit `current` policy. Both have a JPEG marker and size check on the
Mac, and a screenshot is attached to the MCP result only when the selected capture contains it.

## Transport, authentication and custody

Local diagnostics reuses the existing paired transport; it adds no iOS listener, Bonjour
service, or second identity system.

```text
paired owner iPhone             opted-in Mac                  local agent
     | auth /ws/events              |                               |
     |<----- appTheme first frame --|                               |
     |-- mobileDiagnosticsHello --->|                               |
     |<----- capture request -------|                               |
     |------ authenticated POST --->|                               |
     |                               |<-- inspect_ios_diagnostics ---|
     |<----- fresh capture request --|                               |
     |------ authenticated POST --->|------ summary + image -------->|
```

The Mac accepts signals only on the app-events socket from a current interactive owner
authorization with `canManageHost`, a paired device id, and the `lan` route claim. Each request
mints a random single-use id bound to that device for 30 seconds. The separate
`POST /api/local-diagnostics/capture` route repeats normal bearer authentication and iOS
client/device headers, requires that request id in both header and body, and refuses disabled,
unsolicited, expired, cross-device, malformed, non-LAN or oversized captures.

The Mac cache lives below Application Support in `Threading/MobileDiagnosticsCaptures`.
Publication is an atomic write followed by a decode/equality check. Startup loading is shallow
and bounded. The store retains at most 8 captures per device and 40 total; each encoded capture
is at most 900 KiB. Tool reads are memory-only after startup.

The store that owns a request nonce also owns its complete manual-request lifecycle. A fresh tool
request installs one continuation and receives exactly one terminal result: published capture,
disabled consent, disconnected phone, timeout, caller cancellation, or validated-storage failure.
There is no main-actor polling loop. Terminal results are remembered for a bounded minute-long,
64-entry window so disable/disconnect/cancellation cannot race just ahead of continuation
registration. Timeout and cancellation synchronously revoke the nonce, making any later upload
unsolicited instead of silently caching evidence after the caller stopped waiting.

“LAN” is an availability rule, not proof that both radios use the same physical access point. A
VPN or private route can be indistinguishable at this layer, and an authenticated client supplies
its selected endpoint kind. Pairing, current owner authorization, the pinned TLS channel,
single-use request, fixed evidence vocabulary, size limits and independent opt-ins form the trust
boundary. UI and agent output therefore say `local network` or `LAN route`, never “same Wi-Fi
verified.”

## Agent tools

- `list_ios_diagnostic_devices` lists connected and cached phones, capture time and opaque device
  id.
- `inspect_ios_diagnostics` accepts optional `device_id`, `fresh`, and screenshot policy
  (`incident`, `current`, or `none`).

Fresh inspection waits at most eight seconds. If a connected phone misses that deadline, or the
phone is offline, the tool returns the newest cache when one exists and says why it is cached. Its
text result includes device/build/OS, lifecycle, connection, route, counts, capture/cache times,
and the newest 60 structural records. An applicable JPEG is returned as an MCP image content
block. When the Mac switch is off, neither tool exposes cached evidence.

The tools use the existing settings/directory MCP family because the app, transport and cache are
host-owned. This deliberately is not an extension component: an extension cannot replace or
relabel consent while Threading retains pairing, authorization, nonce issuance, evidence
allowlisting, screenshot consent and custody. Presentation outside the small host settings pages
remains agent-owned.

## Shipping verification

Both Release products contain the DTOs, event names, route, settings and tool identities. Tests
hold the switches off by default, exercise disable/re-enable on a live registered connection,
reject the route while the Mac is off, enforce the owner/iOS/LAN/single-use request boundary, and
prove capture, timeout, disable, disconnect and service teardown each resolve a manual inspection
exactly once. UI evidence covers the two opt-in settings surfaces. A physical-device check remains
the final proof that the installed phone and Mac can exchange a fresh capture over their chosen
LAN route.
