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
conversion stay off main. The app admits at most four live helpers across all sessions, while the
public one-frame-per-second screenshot fallback remains available for unsupported Xcode versions.

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
lease is alive. Device HID requires one explicit user decision per exact device per app launch;
both approval and denial are remembered so repeated calls do not pressure the user. Pointer and
keyboard interaction in the pane and all agent input tools converge on that decision and the same
live session. Input fails closed while screenshot fallback is active or whenever the lease,
consent, device identity or stream generation no longer matches.

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

Each increment ships as a coherent fallback-capable slice. The direct helper does not replace the
public lifecycle path, and the MCP tools do not create a second simulator state model beside the
pane. All five increments are implemented. Deterministic tests cover protocol compatibility,
framing bounds, 60 fps replacement pressure, hidden visibility, the four-stream budget, lease
grace, input routing and content-free support diagnostics. The opt-in
`SimulatorLiveIntegrationTests` lane adds signed-host verification, a real framebuffer decode and
a harmless Home-button HID round trip against an already-booted device:

```bash
THREADING_SIMULATOR_INTEGRATION_UDID=<udid> xcodebuild test \
  -project Threading.xcodeproj -scheme Threading -destination 'platform=macOS' \
  -only-testing:ThreadingTests/SimulatorLiveIntegrationTests
```
