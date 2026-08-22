# Debug iOS bridge

> Status: **implemented, Debug only** (2026-08-22).

Read alongside [`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md) for pairing and the dashboard event
socket, [`persistence.md`](persistence.md) for durable diagnostics and privacy, and
[`mcp-and-display.md`](mcp-and-display.md) for typed agent tools and image results.

## Contract

When a Debug iPhone app is paired as the owner of a Debug Mac app and reaches it through
Threading's selected LAN route, the phone automatically gives the Mac a bounded, content-free
operational capture. A local agent can request a fresh capture later, or inspect the newest Mac
cache when the phone is offline. Debug error records also capture the Threading window into a
three-image local ring; the newest image can accompany the next offload.

The bridge is compile-time absent from Release builds. It does not change the shipping issue
report or 30-minute diagnostic-sharing flow.

## How to ask for a checkup

Use this prompt:

> **Check up on my iOS app usage. Use the newest cached evidence if my phone is offline, and tell
> me whether the evidence is fresh or cached.**

The short version also works:

> **Check up on my iOS app usage.**

The agent should call `inspect_ios_debug`, select the only phone when no device id was given,
request fresh evidence, and explicitly label the result `fresh` or `cached`. With several phones,
`list_ios_debug_devices` exposes their exact Debug ids and the agent asks which one to inspect.
Useful deliberate variants are:

- **Do a fresh iOS checkup now and include a screenshot of the current screen.** This selects the
  explicit `current` screenshot policy.
- **Check the latest iOS error without taking a new screenshot.** This uses the retained incident
  image, if present, without photographing the current screen.
- **Use only cached evidence for an iOS checkup.** This does not contact the phone.

## Phone behavior

The Debug iOS Settings page has a Developer-only **Debug bridge** destination. Its single switch
is on by default and persists through `UserDefaults`. The page shows:

- that the implementation is Debug-only and limited to the paired Mac/local-network route;
- the last successful upload and retained error-screenshot count;
- a bounded failure code when the latest upload failed;
- the ordinary-language agent prompt and the privacy boundary.

After the authenticated `/ws/events` socket receives its authoritative first frame, the phone
announces the bridge only when the active pairing is the owner and its selected endpoint kind is
`lan`. The Mac immediately requests a normal capture, throttled to one automatic request per
device per minute.

Every Debug `.error` record schedules an incident capture after 300 milliseconds when the app is
active. Captures have a 60-second cooldown, use the existing Threading-window renderer, are JPEG
compressed below 420 KiB, and are pruned to three files. If the authenticated LAN event socket is
still healthy, the phone immediately announces the incident and the Mac requests it. Otherwise,
the retained image is picked up after reconnection or an agent checkup. There is no attempt to
render after a crash, suspension, or termination.

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

The screenshot is the sole content-bearing exception. It exists only in Debug compilation, is
limited to the app window, has a JPEG marker and size check on the Mac, and is attached to the MCP
result only when the selected capture contains it.

## Transport, authentication and custody

The bridge reuses the existing paired transport; it adds no iOS listener, Bonjour service, or
second identity system.

```text
Debug iPhone                    Debug Mac                     local agent
     | auth /ws/events              |                               |
     |<----- appTheme first frame --|                               |
     |------ mobileDebugHello ----->|                               |
     |<----- capture request -------|                               |
     |------ authenticated POST --->|                               |
     |                               |<----- inspect_ios_debug ------|
     |<----- fresh capture request --|                               |
     |------ authenticated POST --->|------ summary + image -------->|
```

The Mac accepts bridge signals only on the app-events socket from a current interactive owner
authorization with `canManageHost`, a paired device id, and the `lan` route claim. Each request
mints a random single-use id bound to that device for 30 seconds. The separate
`POST /api/debug/mobile-capture` route repeats normal bearer authentication and iOS client/device
headers, requires that request id in both header and body, and refuses unsolicited, expired,
cross-device, malformed, non-LAN or oversized captures.

The Mac cache lives below Application Support in `Threading/MobileDebugCaptures`. Publication is
an atomic write followed by a decode/equality check. Startup loading is shallow and bounded. The
store retains at most 8 captures per device and 40 total; each encoded capture is at most 900 KiB.
Tool reads are memory-only after startup.

“LAN” is an availability rule, not proof that both radios use the same physical access point. A
VPN or private route can be indistinguishable at this layer, and an authenticated Debug client
supplies its selected endpoint kind. The pairing, current owner authorization, pinned TLS channel,
single-use request and Debug compilation are the trust boundary. UI and agent output therefore say
`local network` or `LAN route`, never “same Wi-Fi verified.”

## Agent tools

The two built-ins exist only under `#if DEBUG`:

- `list_ios_debug_devices` lists connected and cached phones, capture time and opaque device id.
- `inspect_ios_debug` accepts optional `device_id`, `fresh`, and screenshot policy
  (`incident`, `current`, or `none`).

Fresh inspection waits at most eight seconds. If a connected phone misses that deadline, or the
phone is offline, the tool returns the newest cache when one exists and says why it is cached. Its
text result includes device/build/OS, lifecycle, connection, route, counts, capture/cache times,
and the newest 60 structural records. An applicable JPEG is returned as an MCP image content
block.

The tools use the existing settings/directory MCP family because the app, transport and cache are
host-owned. This is deliberately not an extension component: extensions cannot weaken the
pairing, Debug compilation, evidence allowlist, custody limits or screenshot policy. Presentation
outside this small host settings page remains agent-owned.

## Compile-time boundary

DTOs, URL construction, phone collection/UI/hooks, Mac route/store, and MCP identities,
definitions and handlers are all enclosed in `#if DEBUG`. Release verification builds both
products and confirms that `inspect_ios_debug`, `list_ios_debug_devices`,
`/api/debug/mobile-capture`, `mobileDebugCaptureRequest`, and the Debug settings copy are absent
from their app bundles.
