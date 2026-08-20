# In-panel iOS Simulator

Threading adopts an iOS Simulator **device**, not another application's window. The selected
device is rendered and controlled inside the session's trailing display pane so an agent and a
person share one stable surface without launching Apple Simulator or Device Hub as the default
workflow.

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
empty inventory.

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

The helper speaks a versioned protocol over an inherited Unix socket. It opens no listener,
accepts no arbitrary executable or path command, verifies same-team signing before launch, and
exposes only the selected device's framebuffer/input vocabulary. Extension companions do not gain
this authority: safe-extension sandboxing and ExtensionKit v1 remain unchanged.

The default live codec is H.264 through VideoToolbox, with JPEG as a compatibility fallback. The
host permits one unacknowledged frame; a slow or hidden consumer causes replacement, never a
queue. A hidden tab requests zero frames. Active targets are 30 fps expected and 60 fps stress,
with decode and conversion off main.

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
4. Snapshot, screenshot and input tools address the lease rather than accepting another session id.

`xcodebuild` is deliberately not hidden inside a pre-approved MCP call. The MCP group makes the
in-app surface easy to discover and reuse; it does not broaden permission to execute an arbitrary
project build. Server discovery text tells agents to prefer `simulator_prepare` over launching
Simulator/Device Hub directly whenever the in-panel preference is enabled.

Agent input and screenshots require one user decision per device. Manual interaction in the pane
still works when agent control is denied. The consent belongs to the device identity, not to a
pixel tab, and every tool fails closed when the lease or consent no longer matches.

## Presentation and customization boundary

This is a durable host-only surface. Threading owns device identity, lease lifecycle, consent,
availability and error state, agent routing, tab persistence, and the direct-helper security
boundary. Those behaviours cannot be delegated to an extension without granting private device
authority and making session guarantees depend on third-party process uptime.

Presentation still uses the shared host vocabulary from `Sources/Threading/UI/Design/`: the pane
header, tab chip, controls, status rows, placeholder and image surface are themed components. A
future public extension component may embed a semantic device status or explicit remote surface,
but it cannot replace the host-owned lifecycle or consent rules. Record this deliberate host-only
decision in `docs/extensions/CUSTOMIZATION_SURFACE_AUDIT.md` when the visible pane lands.

The General preference offers **Threading right panel** (default) and **Apple Simulator / Device
Hub**. The external choice is an explicit workflow fallback, not an automatic reaction to a
recoverable helper error; a failed direct backend stays in the panel with a reason and retry, and
may offer one visible "Open in Apple Simulator" action.

## Delivery increments

1. **Control foundation:** typed device catalogue, bounded/cancellable simctl runner, lease
   ownership, install/launch/screenshot/release, and deterministic tests.
2. **Native pane:** persisted simulator tab, device chooser and state surface through Design,
   backed first by public screenshots and a fake live stream for deterministic tests.
3. **Direct helper:** versioned inherited-socket protocol, compatibility probe, framebuffer and
   HID, H.264/JPEG negotiation, signature policy and fallback state.
4. **Agent tools:** one authored declaration per built-in, catalogue/discovery projection,
   session coordinator, consent and structured results.
5. **Hardening:** multi-session stream budget, lifecycle grace, support diagnostics, performance
   spans, targeted real-shell evidence and the broad non-interactive gate.

Each increment ships as a coherent fallback-capable slice. The direct helper does not replace the
public lifecycle path, and the MCP tools do not create a second simulator state model beside the
pane.
