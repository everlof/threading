# In-panel iOS Simulator

Threading adopts an iOS Simulator **device**, not another application's window. The selected
device is rendered inside the session's trailing display pane so an agent and a person share one
stable surface without launching Apple Simulator or Device Hub as the default workflow. The
public fallback is view-only; the default direct backend supplies live pixels and device-local
interaction without a Simulator.app window.

Part of the [CLAUDE.md](../../CLAUDE.md) index. Read
[`mcp-and-display.md`](mcp-and-display.md) for session routing and tab ownership and
[`design-system.md`](design-system.md) before changing the AppKit surface.

## Why this is not view reparenting

AppKit has no supported general operation that moves another process's `NSView` tree into this
process. A foreign window can be captured and input can be replayed to screen coordinates, but
that requires Screen Recording and Accessibility, inherits the other application's window state,
and becomes ambiguous across Spaces, scaling and occlusion. The existing Simulator Relay example
is intentionally proof of the generic extension remote-surface contract, not this product path.

The Claude-style route talks to CoreSimulator directly. A simulator can run headlessly; the
framebuffer belongs to the device service rather than to Simulator.app, and device HID is distinct
from global macOS input. Threading therefore owns the panel and adopts the device stream.

## Backend boundary

`SimulatorControlling` is the Foundation-only application capability consumed by UI and agent
tools. Its first implementation, `SimctlSimulatorControl`, uses Apple's public `xcrun simctl`
surface for:

- bounded iOS device discovery;
- boot-and-wait, with explicit boot ownership;
- application install and launch on one exact UDID;
- device-only PNG screenshots; and
- shutdown of a device Threading itself booted.

Every command runs outside main on one named serial queue, in its own process group, under a
deadline and caller cancellation. Output and device counts have named ceilings. Values crossing
the queue are `Sendable`, and an invalid CoreSimulator response is a typed failure rather than an
empty inventory. Screenshot fallback uses an explicit, unique file inside a private temporary
directory because current `simctl io screenshot` help documents `-` as stdout, but the command
treats it as a literal filename. Threading bounded-reads the PNG and removes the whole capture
directory on every success or failure path.

The pane does not overlap those public device transactions with its private framebuffer client.
Before an agent install/launch or public screenshot, it stops the current direct transport; after
the bounded command completes or fails, it establishes a fresh stream for the same live lease.
CoreSimulator otherwise can leave `simctl` waiting while the old helper remains connected but
receives no frames. This is one serialization rule owned by the pane, not a retry budget.

The public path is the fallback and lifecycle plane, not the intended live renderer. The direct
backend is a first-party signed helper using the CoreSimulator framebuffer and device HID seams:

```text
session / MCP tool
        ↓
Simulator workspace coordinator     identity, consent, leases, pane placement
        ↓
SimulatorControlling                public lifecycle and fallback screenshots
        ↓
first-party helper                  direct framebuffer + device HID
        ↓
CoreSimulator device                no Simulator.app window required
```

The helper speaks a versioned, length-bounded protocol over an inherited Unix socket. It opens no
listener and accepts no arbitrary executable or path command. The app verifies the embedded
helper's exact location, signing identifier and team before launch; the helper verifies its direct
Threading parent and Apple signatures before loading CoreSimulator and the active Xcode's
SimulatorKit. The hello exchange binds the process to one exact UDID and refuses incompatible
protocol or private API versions. Extension companions do not gain this authority:
safe-extension sandboxing and ExtensionKit v1 remain unchanged.

The default live codec is real-time H.264 through VideoToolbox at 30 fps with two-second keyframes;
JPEG is negotiated as a compatibility fallback. The helper permits one unacknowledged frame and
one replaceable pending frame. A slow consumer therefore gets the newest state rather than a
queue, and a hidden tab stops its capture timer and drops an encode already in flight. Decode and
conversion stay off main. One decoder-owned serial queue orders frame submission, H.264
reconfiguration and teardown; teardown waits for asynchronous VideoToolbox callbacks before it
invalidates the session, so a stream stop cannot race an in-flight decode or strand its retained
frame context. The app admits at most four live helpers across all sessions, while the public
one-frame-per-second screenshot fallback remains available for unsupported Xcode versions.

### Shared-memory transport (prototype)

For the in-panel pane the helper and app are always on the same machine, so encoding video to move
pixels between two local processes is wasted work — the codec path's real cost is H.264's
inter-frame dependency (a dropped frame waits up to a keyframe interval) and the 30 fps
capture/decode pipeline, not the encode itself. The **shared-memory transport** removes the codec:
the app advertises `supportsSharedMemory` in the hello; when the device surface is BGRA the helper
maps a small pool of shared buffers (`SimulatorSharedMemoryProvider`), copies each captured surface
into a free buffer, and sends a `sharedFrameReady(bufferIndex:)` control message instead of an
encoded frame; the app maps them read-only (`SimulatorSharedMemoryConsumer`), builds a CGImage with
one `memcpy` and no decode, and answers `releaseSharedFrame(bufferIndex:)`. A `SimulatorSharedFrameRing`
tracks which buffers the app still holds so the helper only writes a free one and drops the capture
(latest-frame-wins) when the app is behind — the shared-memory analogue of the codec path's frame
window. The status tooltip names this **"Live shared memory"**; H.264/JPEG stay as the automatic fallback
(non-BGRA surface, or a peer that does not offer shared memory), and remain the transport a future
*remote* viewer would use, since shared memory is same-machine only. Wire protocol is v2, decoded
back-compatibly so a v1 peer stays on the codec path.

This is an honest prototype, not the finished design: it is shared memory with one bounded copy on
each side (no codec, no keyframe stalls), not literal IOSurface/mach zero-copy — that needs a
mach-capable channel the current inherited Unix socket cannot carry. The buffers are `mmap`ed temp
files (Swift cannot call the variadic `shm_open`) whose path prefix is exchanged over the
already-signature-verified socket; they are same-user readable, and the helper removes them on every
exit path (a SIGTERM/SIGINT handler breaks the read loop and a `defer` runs teardown, because the
client stops a stream with `process.terminate()`). Passing the buffers as inherited file descriptors
(closing the path-guess surface and the leak-on-SIGKILL window) and then true IOSurface/mach
zero-copy are the planned next increments. **Because this widens the direct-helper boundary
(`SimulatorHelperTrust`, this document's [Backend boundary](#backend-boundary)), it needs the trust
review completed before it ships.** Runtime-verified through the hidden compatibility probe, whose
report carries a null `codec` when the stream went through shared memory.

**The encoder must emit every frame before it is handed the next one.** The helper keeps exactly
one frame inside the encoder and captures again only when that frame's callback has returned.
VideoToolbox's hardware H.264 encoder defaults to frame reordering for the Main profile and
reports a frame delay of three, so left at its defaults it emits the IDR frame at once and then
holds the second frame waiting for lookahead that never comes. That shipped: every direct stream
delivered one picture and then idled, the pane kept showing it under a green "Live H.264" label,
and every process involved sat at zero CPU. The stream restarted around each install, launch and
screenshot, which advanced the picture by one frame and made it look intermittent. The encoder
session now disables frame reordering, sets a maximum frame delay of zero, and reads both back
after preparation; a session that would still hold frames is refused so codec negotiation falls
through to JPEG rather than adopting an encoder the one-frame-in-flight helper cannot drive.
`SimulatorFrameEncoderTests` drives the shipped encoder the way the helper does, one frame in
flight, and fails on the frame that never comes back.

**A visible stream that goes quiet is a failure, not a still screen.** The helper captures at a
fixed rate whenever the tab is visible, so silence means the helper, its encoder or the
framebuffer stopped. The ready state used to rest on the handshake alone, which is why a helper
hanging after one frame kept the live label indefinitely. `SimulatorFrameLivenessMonitor` gives a
visible stream four seconds to deliver a frame, re-armed by every decoded frame and disarmed by
hiding the tab; a stall ends the stream through the same path as a lost helper, so the pane shows
the reason, falls back to public screenshots and offers retry. The compatibility probe, the
opt-in live integration test and the release matrix all require two decoded frames in sequence
order rather than one, because one is exactly what a frozen stream produces. The client also
counts the frames it decoded itself and logs that beside the helper's own statistics, which only
arrive every few seconds of sent frames and never for a stream that froze early.

## Device and session ownership

One simulator tab has one stable session-owned identity and one selected UDID. The initial product
limit is one device per session and four active live streams app-wide; the model must not encode
one as the permanent maximum.

Preparing a device returns `SimulatorDeviceLease`:

- `.user` means it was already booted and Threading must leave it running; and
- `.threading` means Threading booted it and may shut it down when the lease is deliberately
  released.

An agent process exiting is not a lease release. Archive, session deletion, explicit detach or app
quit may release after the coordinator's grace period. A user-adopted device is never shut down by
that cleanup. This distinction is a domain value because inferring ownership from current boot
state would eventually stop somebody's separately running device.

The lease also carries an opaque capability identity. If helper loss is followed by a failed
public screenshot, the pane has evidence that its device snapshot is stale. Retry refreshes that
capability through the shared lease manager before reconnecting. Existing panes can still release
their older capability identity, the reference count does not grow during refresh, and original
`.threading` boot ownership is preserved even if the refreshed catalogue now sees the device
running. This prevents both an endless stale-lease retry loop and ownership laundering.

## Agent route

The built-in **iOS Simulator** tool group is session-scoped. Its preferred sequence is:

1. `simulator_prepare` chooses or adopts a device and reveals the stable in-panel tab.
2. The agent runs `xcodebuild` through its ordinary shell permission flow, using the returned UDID
   and a session-specific DerivedData directory.
3. `simulator_install_launch` installs the resulting `.app` and launches it in that same device.
4. `simulator_screenshot` reads the current pixels from that lease.
5. `simulator_tap`, `simulator_swipe`, `simulator_type_text` and `simulator_press_button` address
   that same visible lease with normalized coordinates and a closed, bounded input vocabulary.

`xcodebuild` is deliberately not hidden inside a pre-approved MCP call. The MCP group makes the
in-app surface easy to discover and reuse; it does not broaden permission to execute an arbitrary
project build. While the built-in iOS Simulator group is enabled, server discovery text tells
agents to prefer `simulator_prepare` over launching Simulator/Device Hub directly. Disabling that
group removes both the tools and the preference guidance from discovery.

Read-only screenshots are available while the built-in group is enabled and the session's exact
lease is alive. Device HID requires one explicit user decision per exact device. **Approval is
durable across launches** — a granted UDID stays controllable without another sheet the next time
the app runs, because re-asking every relaunch was the app's most-repeated permission prompt and
taught nothing new each time; the grants are a bounded list of UDIDs in `PreferenceStore` (so a
hosted test writes a scratch suite, not the developer's own preferences). A **denial is
deliberately not persisted**: it is remembered only for the current launch so repeated gestures do
not turn the sheet into pressure, while a fresh launch asks cleanly rather than a stray dismissal
silencing the device forever. Pointer and keyboard interaction in the pane and all agent input
tools converge on that decision and the same live session. The screen component distinguishes a
ready input route from a recoverable preview: a click on a fallback frame is allowed to express the
intended tap and request one direct-stream reconnection, but the tap is held until the matching
direct session exists and consent succeeds. It is never replayed through global macOS coordinates
or sent over screenshot fallback. A denied gesture remains denied without another sheet; the
ordinary Control button is the only route that deliberately clears that decision — forgetting the
durable grant with it — and asks again, and enabling control there spends no device tap. Becoming
visible after the stream dropped while the pane was hidden reconnects the direct transport up
front, so a returning pane taps on the first click instead of spending it to reconnect. Input
otherwise fails closed whenever the lease, consent, device identity or stream generation no longer
matches. This control/recovery truth remains host-owned even though its button, status and screen
invitation use shared Design components.

## Presentation and customization boundary

This is a durable host-only surface. Threading owns device identity, lease lifecycle, consent,
availability and error state, agent routing, tab persistence, and the direct-helper security
boundary. Those behaviours cannot be delegated to an extension without granting private device
authority and making session guarantees depend on third-party process uptime.

Presentation still uses the shared host vocabulary from `Sources/Threading/UI/Design/`: the pane
header, tab chip, controls, status rows, placeholder and interactive screen surface are themed
components. A future public extension component may embed a semantic device status or explicit
remote surface, but it cannot replace the host-owned lifecycle or consent rules. The deliberate
host-only decision is recorded in `docs/extensions/CUSTOMIZATION_SURFACE_AUDIT.md`.

**The status line is quiet by default.** The device chip already names the device and a live
stream under granted control is the expected state, so the line then carries only the runtime, in
tertiary text. It adds a word only for something that needs the person — a permission hint,
"Connecting…", or **Disconnected** in `Design.Status.negative` on the screenshot fallback or a
failed control request. The transport (H.264, JPEG, shared memory) is a diagnostic and lives in
the tooltip. A green "Live" label was removed: it made the default state the loudest thing in the
pane, and it is what kept a frozen stream looking healthy.

**Annotations have an explicit mode and a one-note gesture.** Option-click pins a note through
exactly the same bounded editor without enabling the persistent annotation mode or emitting device
HID. The persistent mode selects its toolbar button, claims a crosshair over the image, and shows
an explicit finish control. Escape cancels the editor first, then exits the mode; focus returns to
the device. Palette/menu enable and disable commands share the toolbar's setter and accept user
shortcut overrides. Pending pins remain visible outside the mode, so quick notes can be sent.
Successful or queued delivery removes only exact acknowledged note values from the captured device's
store; failed sends and notes edited/added in flight survive. Notes are capped at twenty, and
modifier/pointer handling never discovers devices or rebuilds a growing view tree. These remain
host-owned actions and presentation, using the existing Design controls.

**Control changes snapshot capture to copy.** The presented pane observes modifier changes
without taking keyboard focus, updating the capture glyph, tooltip, accessibility title and
action together. The button freezes the chosen action at mouse-down. Right-click retains
the capture menu, and recording always takes precedence. Hidden/terminated panes remove
the event monitor. Clipboard and recording behavior remain host-owned.

**Keyboard follows Apple Simulator.** The pane root is a `KeyEquivalentScopeView`, so chords apply
only while focus is inside the pane: ⇧⌘H Home, ⌘L Lock, ⇧⌘B Side Button, ⌘↑/⌘↓ volume and
⇧⌘A Toggle Appearance, taken from Simulator.app's own menus (`SimulatorPaneShortcuts`). A chord
presses the matching button, not the action beside it, so enabled state, consent and fail-closed
input stay one path. A focused pane claims its chords even while the button is disabled, so ⇧⌘B
never falls through to Browser mid-reconnect. Rotate, Shake, Siri and App Switcher have no route
in `SimulatorBridgeInput` and are absent until the helper can send them.

The enabled built-in tool group is the current agent preference: **Threading right panel**. Apple
Simulator / Device Hub is an explicit workflow fallback, not an automatic reaction to a
recoverable helper error; a failed backend stays in the panel with a reason and retry. A future
user-facing fallback setting may offer one visible "Open in Apple Simulator" action, but the app
never opens that external window silently.

## Delivery increments

1. **Control foundation:** typed device catalogue, bounded/cancellable simctl runner, lease
   ownership, install/launch/screenshot/release, and deterministic tests.
2. **Native pane:** persisted simulator tab, device chooser and state surface through Design,
   backed first by public screenshots and a fake live stream for deterministic tests.
3. **Agent tools:** one authored declaration per built-in, catalogue/discovery projection,
   session coordinator and structured results over the same lease as the pane.
4. **Direct helper:** versioned inherited-socket protocol, compatibility probe, framebuffer and
   HID, H.264/JPEG negotiation, signature policy, input consent and fallback state.
5. **Hardening:** multi-session stream budget, lifecycle grace, support diagnostics, performance
   spans, targeted real-shell evidence and the broad non-interactive gate.
6. **Dogfood and compatibility:** deterministic restart, helper-loss, stale-device, Xcode-refusal
   and device-switch recovery; a real agent-tool build/install/launch/inspect/input lane; and a
   hidden one-shot probe of the exact signed host/helper pair across selected Xcodes and runtimes.

Each increment ships as a coherent fallback-capable slice. The direct helper does not replace the
public lifecycle path, and the MCP tools do not create a second simulator state model beside the
pane. All six increments are implemented. Deterministic tests cover protocol compatibility,
framing bounds, 60 fps replacement pressure, hidden visibility, the four-stream budget, lease
grace and refresh, input routing, backend recovery, the encoder's immediate-output contract, the
liveness deadline, the probe's two-frame evidence and content-free support diagnostics.

`scripts/simulator_dogfood.sh` is the complete opt-in lane. For every selected Xcode it requires
an already-booted available iOS device, builds `ThreadingMobile` for the exact UDID, and drives the
shipping `AgentToolCoordinator` commands through one visible right-panel tab: prepare,
install/launch, screenshot, a normalized tap, and a harmless Home-button input. It then launches
the exact macOS app bundle in a pre-workspace, activation-prohibited probe that verifies the
embedded helper handshake and two decoded frames in sequence order using that Xcode's private
frameworks. The probe is read-only; it cannot
prepare, boot, install into or control a device.

The dogfood, connectivity-test and iOS UI-evidence runners take the same host-wide advisory
CoreSimulator lane before reading or driving a device. A second Threading worktree therefore
refuses immediately instead of cloning, rebooting or testing the adopted device midway through
another lane. The lock is held through cleanup and released by the kernel when the owning script
exits.

The runner also gives its own catalogue and fixture-cleanup `simctl` process groups explicit
deadlines. A CoreSimulator service that stops answering therefore produces failed evidence and a
released lane rather than an indefinitely wedged test process.

The runner records a versioned JSON matrix and requires Simulator/Device Hub to be absent before
and after the lane, so activating an existing GUI cannot masquerade as headless behavior. It also
requires the user-owned device to remain booted with the same `lastBootedAt`, catching both a final
shutdown and a hidden shutdown/reboot cycle. Cleanup terminates and uninstalls only a unique
dogfood mobile bundle. It never opens, boots or shuts down Apple Simulator:

```bash
scripts/simulator_dogfood.sh --udid <already-booted-udid>

scripts/simulator_dogfood.sh \
  --xcode /Applications/Xcode.app \
  --xcode /Applications/Xcode-beta.app

scripts/simulator_dogfood.sh \
  --app build/release/export/Threading.app \
  --require-notarized
```

`scripts/release.sh --simulator-matrix` applies the same lane to the exported Developer ID bundle;
with `--notarize`, it runs after stapling and requires Gatekeeper acceptance. A colon-separated
`THREADING_SIMULATOR_MATRIX_XCODES` selects the release matrix. The active Xcode is the default.
`scripts/ci.sh` also tests `ThreadingSimulatorKit` as one of the shipping protocol packages, so its
wire contract cannot be omitted from the ordinary non-interactive gate.
