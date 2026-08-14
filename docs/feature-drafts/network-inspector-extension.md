# Traffic Inspector Extension and Workbench Surfaces

> Status: feature draft — the product goal is an agent-usable, lightweight HTTP(S) traffic
> inspector inside Threading. The durable work is a reusable rich-workbench surface, a live
> companion data plane, movable extension-panel placement, and narrowly brokered development
> environment mutation. Nothing here is scheduled, and no proxy engine or privileged helper has
> been adopted.

## Decision

Build **Traffic** as an advanced extension, not as a native Threading feature and not as an
in-process plug-in.

- Its WebAssembly core contributes the panel, settings, commands and MCP tools.
- An on-demand, sandboxed companion owns the HTTP proxy, upstream sockets, bounded capture store
  and protocol parsing.
- The panel prefers Threading's existing **bottom drawer**, where a wide request timeline can sit
  under the conversation and terminal, and may be moved to the display panel by the user.
- The panel uses a new sandboxed **workbench web surface** for its dense master/detail interface.
  The native Threading tab, placement, theme bridge, focus lifecycle, fallback, permissions and
  revocation remain host-owned.
- Manual/scoped proxy setup ships before Mac-wide interception. A later host-owned proxy lease may
  change system settings only transactionally, visibly and with exact crash recovery.
- TLS decryption is off until the user explicitly enables it. Threading owns the development CA's
  root key and lends short-lived leaf identities only to an active, approved capture lease.
- Agent tools receive redacted, bounded, explicitly untrusted traffic data. Raw secrets are never
  returned merely because an extension contributed an MCP tool.

This is deliberately broader than “make extension panels bigger.” The reference extension proves
five reusable platform additions:

1. extension panels can declare allowed host placements, including the existing drawer;
2. a package can contribute an isolated interactive web/canvas workbench with a semantic fallback;
3. a companion can publish bounded live invalidations and transient payload handles without
   repainting remote pixels or replacing a complete panel tree;
4. an extension can acquire a visible, generation-bound system activity lease through a narrow
   host broker; and
5. contributed MCP tools can declare sensitive reads and system mutations, and can ask the host
   to reveal their own panel after a successful call.

Those seams also support simulator consoles, profilers, database browsers, log explorers, device
tools and trace viewers. None grants AppKit, a view handle, arbitrary Threading model access or an
`advanced.full-access` escape hatch.

## Why the current system is close, but not enough

The hard OS boundary is mostly present already:

- `ExtensionCompanionCapability.networkListen` and `.networkClient` are the correct authorities
  for a separately sandboxed proxy engine.
- `host.sessions.runtime.read` exposes the bounded process and listening-port rows Threading has
  already attributed to one session.
- manifest-declared companion operations provide a safe low-frequency control plane.
- extension MCP tools already arrive with the invoking session ID.
- extension panel tabs already reconnect across process generations and fail back to host-owned
  unavailable UI.
- the existing drawer and display panel already share `PaneTab` and `TabHosting`, including tab
  transfer and persistence.

Four current walls make a shippable inspector impossible:

| Wall | Current behavior | Why it fails here |
|---|---|---|
| Placement | Extension panels are created only in `DisplayPaneController`; `DrawerHostViewController.canAdopt` accepts only terminals and browsers. | A traffic timeline wants horizontal room under the work, not a permanent narrow side column. |
| Presentation | Semantic panels are bounded snapshots; companion `remoteSurface` sends pixels. | A dense searchable table, body inspector, timing view and WebSocket stream exceed the semantic vocabulary, while pixels lose text selection, native accessibility, agent-readable structure, theme adaptation and mobile fallback. |
| Liveness | Panel state changes only after an action/load response. Companion operations are request/response and capped at 64 KiB. | Traffic arrives continuously and bodies can be large. Polling or replacing a 500-node tree per burst violates the Scaling Gate. |
| Environment | A companion can listen, connect and spawn, but Threading has no reviewed transaction for setting a Mac proxy, lending TLS identities or restoring state after death. | A useful one-click setup changes security-sensitive machine state. Generic subprocess authority is not an acceptable recovery protocol. |

Two smaller gaps matter as soon as an agent drives the tool:

- `ExtensionMCPTool` has no declared effect/risk beyond prose, so Threading cannot distinguish
  listing redacted metadata from installing trust or changing a system proxy.
- MCP responses are text only and cannot return the same extension's host-owned presentation
  intent, so a successful `traffic_start` cannot reliably reveal the Traffic tab in the drawer.

The open item in `docs/extensions/HANDOFF.md`—exercise the advanced companion primitives with an
HTTP proxy—is therefore the right feasibility spike, not the finished UI architecture.

## Product shape

### It lives in the drawer

Traffic is a session-scoped `PaneTab` whose preferred placement is `.drawer` and whose allowed
placements are `.drawer` and `.displayPanel`.

The drawer is the right default for three reasons:

1. request paths, timings and headers are horizontal data;
2. the agent conversation remains visible directly above the evidence it is discussing; and
3. Threading already lets a shell and browser live there, so this is a new tab kind rather than a
   fourth window-layout mechanism.

The extension does not choose a height. Opening uses the host's remembered drawer height; the
user's divider remains the authority. A first open may use the same host-owned default used by
other drawer content. Moving the tab to the display panel transfers the same live controller and
capture state; it does not start a second proxy.

An extension panel remains one singleton per `(extension, panel, context)` across both hosts. A
window-owned resolver finds and activates an existing Traffic tab wherever the user moved it.
Opening the contribution twice must not produce two views that disagree about selection or record
the same socket twice.

### The compact capture bar

The workbench begins with one fixed row above its content:

```text
● Recording  Mac + Simulator ▾     All  Errors  [ Search traffic… ]   Pause  Clear  ⋯
```

- The leading state is both a shape and text, never colour alone: `Recording`, `Paused`, `Stopped`,
  `Restoring proxy…`, or an actionable error.
- The scope is exact. It says **Mac + Simulator**, **Manual proxy**, or the name of a launch the
  extension actually owns. It never says “This session” merely because the panel belongs to a
  session: a system proxy cannot identify the source process of every loopback connection.
- **Pause** keeps forwarding traffic but stops retaining new records. **Stop Capture** tears down
  the proxy lease and restores every setting it changed. **Clear** only removes captured data.
- Search and filters affect the visible query, not the capture pipeline.
- When a system-wide lease remains active while the drawer is collapsed or another session is
  selected, Threading shows a host-owned activity chip in the workspace header with the exact
  scope and a Stop action. Background security-sensitive work may not be visible only inside the
  pane it can outlive.

### Request list and detail

At ordinary drawer widths the body is a two-column master/detail surface:

```text
┌ Requests ───────────────────────────┬ Selected exchange ───────────────────────┐
│ 200 GET  api.example.com/v1/me      │ GET /v1/me                       142 ms   │
│ 500 POST api.example.com/v1/upload  │ Summary  Request  Response  Timing       │
│ ERR WSS  events.example.com/socket  │ Headers                                      │
│                                     │ authorization: ••••                         │
│ method · host/path · status         │ accept: application/json                     │
│ duration · size · type · waterfall  │                                               │
└─────────────────────────────────────┴───────────────────────────────────────────────┘
```

At a narrow side-panel width, selecting a row drills into detail and gives the header a Back
action. It does not squeeze both columns below their useful width.

Rows carry stable flow IDs and show method, host/path, status or failure, duration, transferred
size, content type and a small timing bar. Status uses text/silhouette as well as semantic ink.
The list groups redirects and optional WebSocket messages without eagerly building their children.
Pinned flows survive ring-buffer eviction within a separate bounded pin budget.

The detail surface has:

- **Summary** — URL, protocol, remote endpoint, TLS state, timing and truncation/completeness;
- **Request** — query, headers and body;
- **Response** — status, headers and body;
- **Timing** — proxy-observed accept, connect, TLS, first-byte and transfer intervals, with
  unavailable phases stated rather than synthesized; and
- **Messages** for WebSocket or server-sent event records when the parser supports them.

Body presentation is meaning-aware but never executable: formatted JSON, text/code, bounded image
preview or hex. HTML is source, not a live page. Compressed content is decoded under explicit
expanded-size ceilings. A truncated, evicted, encrypted or unsupported body says which state it is
in and keeps the request metadata useful.

User actions in the first useful release are Copy URL, Copy Redacted cURL, Copy Value, Save Body
through a host-owned save panel, Pin, and Clear. Exact cURL—including authorization or cookies—is
a separate user-only reveal/copy action. Replay, breakpoints, map-local and rewrite rules are a
later mutation phase; they do not ride along as “obvious inspector features.”

### Capture setup

The setup screen offers progressively broader routes and names the tradeoff:

1. **Manual proxy** — starts an ephemeral loopback proxy and shows the endpoint, CA status and
   environment fragment. It changes no machine settings. This is the first shipping route and is
   sufficient for a process or debug client explicitly configured to use it.
2. **Launch with Traffic** — a later, scoped route for a command Threading is already authorized to
   launch. The host supplies proxy/trust environment through a typed launch integration; the
   extension does not receive an arbitrary checkout path or shell injection door.
3. **Mac + Simulator** — acquires the host's system-proxy lease and clearly says that unrelated
   applications may also pass through it. The active lease stays visible outside the Traffic tab.
4. **Remote device** — shows address, port and CA onboarding. It is intentionally manual until a
   separately designed device-pairing authority exists.

The product does not promise that all clients respect a system or environment proxy. Some
networking libraries ignore those settings, macOS normally bypasses localhost, cached responses
produce no request, and certificate pinning deliberately refuses a man-in-the-middle. Each becomes
a diagnostic state with a suggested development-safe remedy; none causes Threading to inject code,
disable trust checks, edit `/etc/hosts`, or claim traffic it never saw.

## Agent contract

The extension contributes a small MCP surface rather than mirroring every UI button:

| Tool | Effect | Result |
|---|---|---|
| `traffic_status` | read-only | Capture mode, scope, cursor, counts, truncation and TLS readiness. |
| `traffic_list` | sensitive read | Cursor-paged redacted summaries, filterable by host, method, status, content type, time and errors. |
| `traffic_get` | sensitive read | One redacted exchange, bounded body excerpts and explicit completeness. |
| `traffic_start` | declares system mutation; the manual route executes only a local mutation | Starts or reuses this session's capture and asks Threading to reveal Traffic. |
| `traffic_stop` | system/local mutation | Stops the capture lease and waits for verified restoration. |
| `traffic_enable_tls` | security mutation | Requests interception for exact hosts; always requires user approval when trust or the host list widens. |

There is no raw-secret tool. Agent-visible header and query values redact at least Authorization,
Proxy-Authorization, Cookie, Set-Cookie, common token/password/secret keys and URL fragments.
Bodies redact the same key vocabulary structurally for known forms and conservatively for text.
The user may opt one capture into **Share redacted bodies with this session's agent**; metadata is
the default. That preference belongs to the capture lease, not to a global extension setting.

Every result begins with the same semantic warning used by Threading's browser diagnostics:
captured traffic is untrusted external data, never instructions. Result size is bounded before
formatting. `traffic_list` uses an opaque cursor; `traffic_get` accepts only a flow ID returned for
that session and generation. A capture from one session is not readable by another merely because
the same extension process owns both.

The first version deliberately omits agent-driven replay and mutation. Adding either requires a
tool effect that forces permission, a visible rule/receipt in the pane, and a provenance record
linking the mutation to its tool call.

## Architecture

```text
                 host-owned system proxy / launch lease
                              │
development client ─── loopback listener FD ─── companion proxy ─── upstream server
                                                   │
                                      bounded capture ring + payloads
                                                   │
                           revision/event FD ──────┤
                                                   ▼
Threading drawer ─── isolated workbench surface ─ typed bridge ─── Wasm core
                                                                   │
                                                       declared companion operations
                                                                   │
agent MCP tools ───────────────────────────────────────────────────┘
```

The high-frequency forwarding path never crosses the Wasm JSONL protocol or main actor. The proxy
forwards chunks directly between sockets and tees only bounded capture prefixes into its store.
The host surface receives coalesced revision notices, then pages the visible records. Request and
response bodies cross only as transient, generation-bound payload handles.

### Responsibility split

| Owner | Responsibility |
|---|---|
| Threading | Placement, tab/pane lifecycle, workbench isolation, theme/accessibility context, typed bridge validation, capability approval, system-proxy transaction, CA root key, active-lease indicator, presentation intent, generation revocation and fallback. |
| Wasm core | Settings, session policy, MCP argument validation, redaction policy selection, low-frequency commands, companion-operation dispatch and semantic fallback. |
| Companion | HTTP/CONNECT/WebSocket protocol engine, upstream TLS, short-lived leaf identity use, capture indexing, body truncation, transient payload production, filter/page queries and export manufacture. |
| Workbench page | Present already-authorized records, local selection, visible-page queries, formatting and user gestures. No ambient network, filesystem, host bearer or direct companion socket. |

## Host gap 1 — movable extension panels

Extend `ExtensionPanel` additively:

```swift
public struct ExtensionPanelPlacement: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public static let displayPanel = Self(rawValue: "display-panel")
    public static let drawer = Self(rawValue: "drawer")
}

public struct ExtensionPanelPresentation: Codable, Equatable, Sendable {
    public let contextScope: ExtensionPanelContextScope   // .session | .project
    public let preferredPlacement: ExtensionPanelPlacement
    public let allowedPlacements: Set<ExtensionPanelPlacement>
}
```

Missing presentation data decodes to today's session-scoped display-panel behavior. An extension
declares where its content remains useful; it never declares exact width, height, divider position,
animation or whether another pane closes.

Host work:

- extract extension-panel construction/reconnection into a host-neutral factory;
- let the drawer create, restore and adopt an extension panel only when `.drawer` is declared;
- persist the panel's current host through the existing `PersistedTab.host` field;
- add a window-owned extension-panel resolver so open/select is singleton across hosts;
- list drawer-capable contributions in its `+` menu and preserve the display panel's list;
- apply the same `PaneTransition`, grid-resize deferral, transfer and focus rules already used by
  the two hosts; and
- keep the required semantic `root` useful on iPhone and whenever a custom body is unavailable.

This composes with the project-scoped panel and `ExtensionPresentationIntent` proposed by
`project-insights-extension.md`. Implement one generic intent:

```swift
public struct ExtensionPresentationIntent: Codable, Sendable {
    public let kind: ExtensionPresentationKind       // .openPanel
    public let panelID: String
    public let context: ExtensionCommandContext
    public let preferredPlacement: ExtensionPanelPlacement?
}
```

The extension identity is derived from the response. Threading validates panel, context and
allowed placement, then chooses the closest valid host if the preference is unavailable.

## Host gap 2 — sandboxed workbench surfaces

Add one middle tier between semantic nodes and remote pixels:

```swift
public struct ExtensionWebSurface: Codable, Equatable, Sendable {
    public let id: String
    public let entryResource: String
    public let requests: [ExtensionWebSurfaceRequestDefinition]
    public let eventTopics: [String]
}
```

An `ExtensionPanel` may reference one `webSurface` or one companion `remoteSurface`, never both.
`root` remains required and is rendered while loading, after failure, on iPhone, and wherever the
host cannot safely render the custom body.

The web surface is package code, so install review calls it what it is: **Custom interactive web
interface**. It receives freedom inside its rectangle, not ambient authority outside it.

The host:

- serves inspected package resources through a private custom URL scheme, never `file:`;
- uses a non-persistent website data store and an extension-specific process pool;
- injects a host-authored CSP with no remote origin, connect, form, frame, object, worker or
  navigation capability;
- blocks ordinary HTTP(S), WebSocket, download, new-window and external-scheme loads independently
  of the page's CSP;
- exposes only schema-declared request methods and event topics through an isolated script world;
- gives the page no Wasm host bearer, companion descriptor, cookie jar, arbitrary clipboard,
  drag-file, camera, microphone, geolocation or notification access;
- supplies CSS custom properties for semantic colours, typography, spacing, radii and focus,
  updates them on a live theme/text-scale/accessibility change, and exposes reduced motion and
  increased contrast;
- pauses event delivery and expensive page work while the tab is hidden, drawer is collapsed,
  window is occluded/miniaturized or session is not selected; and
- tears down the bridge synchronously on generation revocation before showing the fallback.

Workbench request/response messages have inspectable JSON Schemas, correlation IDs, a 256 KiB
structured-response ceiling and explicit errors. The page cannot invent a new operation name or
call another extension. The core receives a typed `ExtensionWebSurfaceRequest`, applies extension
policy and may call a declared companion operation. Low-frequency UI control stays in the core;
the browser does not become a second privileged extension runtime.

The reference Traffic UI must still provide keyboard traversal, list/detail semantics, readable
focus, announcements for capture state, exact accessible names/values and non-colour status. A web
surface expands presentation freedom; it does not waive product review. Render/evidence tests cover
System and authored themes, increased contrast, reduced motion and the real drawer host.

## Host gap 3 — companion events and transient payloads

Do not send flows as remote frames and do not publish a complete panel on every request.

Add a separate inherited companion data descriptor. Its manifest declaration names bounded event
topics and whether they are lossless records or coalescible invalidations. Traffic declares only a
coalescible `capture-revision` topic:

```swift
public struct ExtensionCompanionEvent: Codable, Sendable {
    public let protocolVersion: Int
    public let topicID: String
    public let sequence: UInt64
    public let payload: ExtensionJSONValue
}
```

The inherited descriptor is the authority. A message is accepted only for the inspected companion,
generation and declared topic. Sequences are monotonic; packets and batches are bounded; one batch
is unacknowledged at a time. A coalescible topic may replace several pending revisions with its
latest value. A genuinely lossless topic must stop its producer or spill inside its own declared
bounded store; it may not grow a host queue without limit.

Traffic events carry revision, counts and optional changed flow IDs—not headers or bodies. The
surface uses ordinary paged requests to ask for visible summaries at a revision. This makes event
rate independent of network body size and lets a hidden surface consume no per-request rendering
work.

Large response data uses a transient payload handle:

```swift
public struct ExtensionTransientPayload: Codable, Equatable, Sendable {
    public let id: String
    public let mediaType: String?
    public let byteCount: UInt64
    public let completeness: ExtensionPayloadCompleteness
}
```

The companion streams a payload through the same backpressured data channel into host-owned
ephemeral storage. Handles are scoped to the extension generation, presentation and capture; they
are not file paths and cannot be opened by another page or extension. The private scheme supports
bounded range reads so a body viewer need not copy a multi-megabyte value through JSON. Closing the
capture or revoking the generation drops unpinned transient payloads.

This is not durable large-file storage. The first Traffic release is intentionally ephemeral and
exports through a user-selected host action. A future `storage.blobs` capability can adopt the same
handle vocabulary only after retention, quota, backup, removal and recovery semantics are designed.

## Host gap 4 — proxy and certificate leases

### A proxy lease, not arbitrary settings mutation

Add a high-risk advanced capability such as:

```text
system.network-proxy.configure
```

It is independent from companion `network.listen` and `network.client`. The extension requests a
lease through the Wasm host broker. It cannot supply a remote proxy address: Threading creates an
ephemeral loopback listener, passes the connected listener descriptor only to the authorized
companion generation, and points selected system network services at that endpoint.

The mutation is transactional:

1. enumerate the exact affected services and snapshot HTTP, HTTPS, SOCKS, PAC and bypass settings;
2. write and fsync a recovery journal before changing anything;
3. show the host-owned active-lease indicator;
4. apply only HTTP/HTTPS values required by this lease, preserving unrelated configuration;
5. verify the effective settings;
6. on Stop, companion death, core death, disable, update, uninstall or app quit, restore from the
   snapshot and verify it; and
7. at next launch, complete any journaled restoration before starting an extension.

A narrow Threading-signed privileged helper may perform the system call when required. It accepts
requests only from Threading's pinned designated requirement and implements this fixed
snapshot/apply/restore protocol. It never authenticates an extension, accepts a shell command,
chooses a proxy host, installs an extension helper, or becomes a generic privileged bridge.

The user approves the exact scope at acquisition time. An agent cannot turn on Mac-wide capture
through install-time approval alone. Conflicting VPN/PAC/system-proxy leases fail with an explicit
choice or use Manual proxy; they are never overwritten optimistically.

### Threading owns the development CA

Installing a trusted root is more powerful than changing one network service, so it is a separate
one-time host workflow and never hidden inside Start Capture.

- Threading creates one “Threading Development Inspection CA” root key in its Keychain namespace.
- The private root key never crosses to an extension or companion.
- The user explicitly installs/trusts the public root through a host-owned, system-authenticated
  flow and can remove it from Settings.
- An active, approved capture lease may request a short-lived leaf identity for an exact hostname.
  Threading generates the leaf key, signs it, binds it to the lease/generation and returns only the
  short-lived identity required by the companion's TLS listener.
- Widening the interception host set is visible and permissioned. “All hosts” is never the quiet
  default.
- Simulator trust installation is a separate explicit action naming the selected simulator. A
  companion's generic `process.spawn` is not treated as authority to rewrite every simulator.
- Removing trust invalidates every active decrypting lease first. Removing the extension cannot
  strand a root key owned by that extension, because no extension ever owned the key.

Certificate pinning is an honest terminal state. Traffic reports the handshake failure and suggests
using a debug build without pinning if the developer controls it. Threading does not hook trust
callbacks or patch a binary.

## Host gap 5 — MCP effects and presentation

Extend inspectable MCP metadata with an additive raw-value risk/effect:

```swift
public struct ExtensionMCPToolRisk: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public static let readOnly = Self(rawValue: "read-only")
    public static let sensitiveRead = Self(rawValue: "sensitive-read")
    public static let localMutation = Self(rawValue: "local-mutation")
    public static let systemMutation = Self(rawValue: "system-mutation")
    public static let securityMutation = Self(rawValue: "security-mutation")
}
```

Missing data decodes conservatively to the current ordinary behavior. Threading shows the effect in
Tools settings and install review and supplies it to the provider permission plane. A system
mutation always waits for the user's decision in Threading even if the agent runtime would
otherwise auto-allow an MCP tool. Security mutations such as installing trust or widening the
intercepted host set receive the same mandatory host decision and a more explicit warning. A tool
with mode-dependent behavior declares its maximum possible effect; the broker still records the
smaller effect actually performed. Sensitive-read policy can be scoped to one session/capture.

Add `presentation: ExtensionPresentationIntent?` to `ExtensionMCPToolResponse`, using the same
generic intent as commands/actions. The host can open only a panel registered by the responding
extension, for the invoking session, at an allowed placement. A tool cannot point at another
extension, a raw tab UUID, a window or an AppKit concept.

## Proxy engine scope

The first reference engine is deliberately smaller than Proxyman:

- HTTP/1.1 requests and responses;
- CONNECT tunnels with host metadata;
- opt-in HTTPS interception for approved hosts;
- redirect grouping;
- gzip/deflate content decoding under an expanded-size ceiling;
- WebSocket upgrade and bounded message capture after the HTTP path is solid;
- request/response metadata, timing, body completeness and transport errors; and
- HAR export after the host-owned save route exists.

HTTP/2, gRPC/protobuf schemas, SSE framing, replay, breakpoints, throttling, map local/remote and
scripts are later, independent increments. The upstream and downstream protocol actually used is
always reported. Silently downgrading a client in a way that changes application behavior is a
failed capture, not an implementation detail.

A companion implementation may vendor audited networking packages inside the extension's retained
source rather than adding them to Threading. The likely Swift shape is NIO HTTP/1 + NIO SSL, with
HTTP/2 added only after the capture, backpressure and TLS identity paths are proven. The package
retains dependency source or exact resolved artifacts so the offline rebuild promise remains true.

## Security and privacy model

- **Capture is visible.** Recording and Mac-wide proxy state have host-owned indicators and a Stop
  route outside the workbench.
- **Scope is truthful.** A broad system proxy never masquerades as session attribution. A scoped
  launch is tagged only when Threading launched and configured that client.
- **Trust is separate.** Network client/listener authority, system proxy mutation and local CA trust
  are separately reviewed and separately revocable.
- **Root authority stays host-owned.** An extension receives no reusable CA private key.
- **No ambient web authority.** Workbench content has no network, host bearer, filesystem, cookie,
  pasteboard or permission API beyond declared bridge operations.
- **Generation is the lifetime.** Listener, event channel, payload handles, bridge requests,
  presentation and system lease all fail closed on generation replacement.
- **Raw traffic is local and ephemeral by default.** It is not logged to `EventLog`, included in
  issue reports, sent to extension services, persisted in panel JSON or restored after relaunch.
- **Secrets are not agent defaults.** Agent tools return redacted metadata and optionally redacted
  bodies. Raw reveal/export is a user action.
- **Content is untrusted.** HTML is source; names and headers are bounded; JSON/text is escaped;
  images are decoded in the isolated renderer under size limits; no body becomes instructions.
- **Forwarding wins over inspection.** A full capture store drops/evicts capture data according to
  its stated policy while continuing to proxy. UI backpressure must not stall the developed app.
- **No stealth interception.** Trust widening, system proxy mutation, replay, request edits and
  response edits each require an authority and visible receipt appropriate to their effect.

## Performance contract

Answering the Scaling Gate before implementation:

- **Cardinality.** Expected 50–2,000 exchanges per capture; stress 50,000 summaries. Expected
  0–2,000 messages per upgraded connection; stress 100,000 bounded message summaries.
- **Frequency.** Expected 5–50 completed exchanges/second, burst stress 1,000/second. The companion
  coalesces visible revision notices to at most 10 Hz and hidden notices to at most 1 Hz; forwarding
  itself is never coalesced.
- **Viewport.** The request list and message list realize O(visible) rows. Filter, sort and search
  run against the companion index off-main and return cursor pages. Selection changes fetch one
  detail, never rebuild the collection.
- **Bodies.** Forward chunks without retaining them whole. The default capture keeps at most 2 MiB
  per request direction and states truncation. A setting may choose a smaller or larger bounded
  ceiling up to a host maximum; expansion/compression bombs are capped after decoding as well as
  before it.
- **Aggregate bounds.** Initial proposal: 10,000 full flow records or 256 MiB of captured payload,
  whichever comes first; up to 50,000 metadata summaries; 100 pinned flows within 64 MiB. Oldest
  unpinned payloads evict first and retain a summary saying they were evicted.
- **Wire.** Events contain revisions, not bodies. Structured workbench responses cap at 256 KiB.
  Payload range chunks cap at 1 MiB with one unacknowledged chunk per presentation.
- **Main actor.** It mounts/reuses visible rows, changes selection and applies one revision. Socket
  I/O, TLS, decompression, parsing, indexing, redaction, search and export stay off-main.
- **Visibility.** Hidden tabs do no DOM updates, formatting, detail reads or animation. The proxy
  may continue recording only when its active lease says so.
- **Must remain exact.** Forwarded bytes and ordering, capture completeness labels, selected flow,
  scroll position, active filter, tab placement and proxy restoration. Performance work may drop a
  capture payload under the declared eviction policy; it may not alter forwarded traffic.
- **Fixture.** Deterministic replay with 50,000 summaries, 1,000 completions/second, one 64 MiB
  streamed response, a compression bomb, 100,000 WebSocket messages and repeated drawer
  collapse/session switches. Measure proxy overhead, dropped capture records, event queue depth,
  visible row/view count, filter latency, selection latency, footprint and zero work after stop.

The proxy overhead target for an ordinary loopback HTTP stream should be measured before a number
is promised. The regression boundary is matched direct-versus-proxied throughput/latency at small
and large body sizes, not an ungrounded “under 5%” assertion.

## Implementation order

Each phase leaves a useful proof and does not require shipping the later machine-wide authority.

**Phase 0 — current-primitive proxy spike.** Build a companion using existing
`network.listen`/`network.client`, a manual proxy endpoint, bounded in-memory summaries, operations
and either a temporary semantic status panel or diagnostic remote surface. Prove App Sandbox
networking, CONNECT forwarding, supervisor teardown and MCP dispatch. Do not ship the pixel UI.
*4–6 focused days.*

**Phase 1 — panel placement and generic presentation intent.** Land the host-neutral extension
panel factory, drawer placement/restore/transfer, singleton resolver, allowed-placement validation,
and the shared command/action/MCP open-panel intent already motivated by Project Insights.
*4–7 days.*

**Phase 2 — workbench surface.** Add static declarations, package/resource inspection, isolated
WKWebView host, CSP/network denial, typed core bridge, semantic fallback, theme/text/accessibility
context, visibility lifecycle and adversarial isolation tests. Ship a small gallery workbench before
Traffic uses it. *7–12 days.*

**Phase 3 — companion data and payload plane.** Add declared topics, inherited descriptor,
sequence/ack/backpressure/revocation, revision subscriptions, transient payload handles/range reads
and stress fixtures. Keep remote-surface protocol unchanged. *6–10 days.*

**Phase 4 — useful Traffic extension.** HTTP/1.1 + CONNECT proxy, bounded store/index, redaction,
manual setup, workbench list/detail UI, status/list/get/start/stop tools, settings, rendered evidence
and end-to-end scenario tests. HTTPS remains tunneled unless the development CA phase is complete.
*8–14 days.*

**Phase 5 — host proxy lease and TLS broker.** Narrow privileged helper if measurements require
it, recovery journal, loopback listener handoff, host activity lease, CA Keychain workflow,
short-lived leaf identities, exact-host approval and Simulator trust onboarding. This phase gets an
independent security review and crash/kill/power-loss campaign. *10–18 days plus review.*

**Phase 6 — protocol depth and mutations.** WebSocket messages, HTTP/2, HAR, then replay/rules one
at a time with MCP effects, provenance and receipts. Promote a native semantic collection/table
node only when Traffic and at least one other extension demonstrate the same portable meaning; do
not delay the bounded workbench on a speculative universal table schema.

The estimate excludes implementing a production-quality HTTP/2/TLS proxy from scratch. Dependency
selection and license/security audit are real work, not packaging details.

## Verification gate

- Codable and JSON-Schema round trips for placement, workbench, event, payload, tool-risk and
  presentation-intent values; older-host inspection of unknown raw values.
- Capability denial for drawer placement, workbench body, undeclared bridge method/topic,
  companion event, transient payload, network listener/client, system proxy and TLS identity.
- Cross-extension, cross-session, stale-generation, stale-presentation, replayed cursor and reused
  payload-handle refusals.
- Web adversarial fixtures for remote image/script/font/fetch/WebSocket/form/window/navigation,
  service worker, storage, clipboard, drag/drop, camera/mic/location, oversized resource and CSP
  override attempts. The page receives none.
- Proxy byte-for-byte tests for request/response streaming, chunking, close-delimited bodies,
  cancellation, redirects, CONNECT tunnels, early upstream failure, backpressure and client death.
- TLS tests for exact hostname/SAN, expiry, host widening, CA unavailable/removed, pinning failure,
  identity revocation and proof that the root key never enters companion output or storage.
- System proxy snapshots covering manual HTTP/HTTPS, PAC, bypass lists, inactive services, VPN
  conflicts, failed apply, failed verify, normal stop, SIGKILL of core/companion/app, update,
  uninstall and launch-time recovery. Restoration is verified, not merely attempted.
- Redaction fixtures for headers, URL parameters, fragments, JSON, forms, multipart names, mixed
  case and malformed input; tool output never contains seeded secrets.
- Capture-limit tests at every per-body/aggregate/pin/message cap, with forwarding continuing and
  an exact completeness state.
- Drawer/display transfer, relaunch restore, process-generation reconnect, fallback, focus return,
  Escape, keyboard list/detail navigation, narrow drill-in and host indicator behavior.
- Workbench evidence under light/dark System and two authored themes, text scales, Increased
  Contrast, Reduce Motion and the real drawer host.
- The stated 50,000-flow/1,000-per-second/large-stream stress fixtures with O(visible) rows,
  bounded queues and footprint, and matched direct/proxied network measurements.
- A real Simulator and macOS debug-app product pass before calling automatic setup supported.
- `ThreadingComponentCatalogGenerator --check docs/extensions/generated`, extension package
  inspection, source-bundled offline rebuild, `scripts/ci.sh`, and complete authoring docs/schemas.

## Rejected alternatives

- **Ship the remote pixel surface.** It proves the companion but makes the main product a video of
  text: weak accessibility, no native selection/search, poor theme adaptation, high frame cost and
  no portable fallback beyond a second implementation.
- **Force the inspector into `ExtensionNode`.** A 500-node snapshot can show a page of summaries;
  it cannot be the live source of truth for 50,000 searchable flows or large bodies. More nodes do
  not repair replacement frequency.
- **Add a `networkInspector` semantic node.** It would put proxy-specific records, filters and body
  viewers into Threading before a second extension proves the vocabulary. A generic bounded
  workbench carries more product with a smaller stable semantic promise.
- **Run the proxy inside Threading.** That gives malformed protocol/TLS input the app's process and
  turns an optional development tool into core networking/storage/UI. The companion boundary
  exists for exactly this calibre of work.
- **Allow an in-process native plug-in.** It discards crash containment, capability review,
  generation revocation and the theme/AppKit boundary to avoid designing two missing data paths.
- **Let the companion call `networksetup` and remember what it did.** Generic process authority is
  not transactional machine-state authority, and companion death is the condition restoration must
  survive.
- **Trust an extension-owned root CA.** A reusable signing key plus raw client networking is a much
  broader authority than one active inspection lease. Threading can keep the root and lend bounded
  short-lived identities.
- **Call system-wide capture session-scoped.** The pane context identifies who requested the tool,
  not which local process opened every proxied socket. The UI must tell the truth.
- **Use Network Extension for v1.** Per-app transparent capture would be attractive, but it adds a
  separately provisioned system extension and restricted entitlement to solve a route that manual
  and explicit system proxies already prove. Reconsider only with evidence that proxy-respecting
  development clients are insufficient.
- **Ship replay/breakpoints with capture.** Observation is useful on its own and dramatically safer.
  Mutation deserves its own effects, provenance, receipts and test campaign.

## Evidence behind the setup boundaries

- Apple's `URLSessionConfiguration` exposes per-session proxy configuration and says a default
  session otherwise uses system settings. That supports both manual/scoped and system routes:
  <https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary>.
- Proxyman documents that its reliable Mac-wide route uses a privileged helper to override and
  revert system HTTP proxy settings, and records a past caller-validation vulnerability in that
  helper. The equivalent Threading seam must therefore be host-owned, pinned and narrow:
  <https://docs.proxyman.com/basic-features/proxy-setting-tool>.
- Proxyman documents that HTTPS inspection requires a trusted local CA, including in iOS
  Simulator, while certificate-pinned clients remain intentionally uninterceptable:
  <https://docs.proxyman.com/debug-devices/macos>,
  <https://docs.proxyman.com/debug-devices/ios-simulator>, and
  <https://docs.proxyman.com/troubleshooting/get-ssl-error-from-https-request-and-response>.
- macOS normally bypasses localhost for the system proxy. Traffic must not promise capture merely
  because the destination is a session-attributed local port:
  <https://docs.proxyman.com/troubleshooting/couldnt-see-any-request-from-localhost-server>.

## What this unlocks beyond Traffic

The reusable result is an **extension workbench**, not a proxy exception:

- a simulator/device console with structured logs beside a remote surface;
- a database browser with virtual tables and bounded cell payloads;
- a trace or profiler timeline driven by revision events;
- a build/test explorer with live updates and large artifacts;
- a log tailer whose hidden tab costs no DOM or main-thread work;
- an API client, message-queue inspector or local service dashboard; and
- a notebook or artifact tool whose custom Mac surface still has a semantic mobile fallback.

The lease model also generalizes narrowly: a long-running dev server, recording, port forward or
device bridge can acquire a visible host lease with exact stop/recovery semantics without gaining
arbitrary application injection.

## Rollout rule

Treat the proxy implementation, networking dependencies, timing internals, redaction vocabulary
updates and numeric ceilings as host/reference-extension implementation details. Treat placement
meanings, workbench isolation, bridge schemas, topic/backpressure semantics, payload lifetime,
system-lease recovery, CA-key ownership, MCP effects, privacy defaults and truthful scope labels as
public contract.

Before freezing them, build the Phase 0 proxy with today's companion API and the workbench gallery
with hostile content. If either cannot state a necessary boundary without a special case, version
the generic contract deliberately. Do not promote the spike's pixels, paths, helper commands or
proxy-specific objects into the extension ABI merely because they were convenient to prove.
