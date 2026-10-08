# Multiple simulators in the display pane

Date: 2026-10-07. Status: implemented first slice in the working tree.

A session now has one Simulator workspace containing one to four exact devices. Auto compares
rows, columns and a grid against the actual viewport and confirmed framebuffer aspects: portrait
pairs normally sit beside each other and landscape pairs stack. Row, Column, Grid and Focus are
persisted overrides. The shared controls follow selection and keyboard input follows the focused
member. Agent operations require an exact device ID when several members are adopted.

The durable decisions are in [simulator-pane.md](../architecture/simulator-pane.md), with the
[viewport measurements](../architecture/performance.md#simulator-workspace-viewport-contract-2026-10-07)
and the host-only customization boundary in
[CUSTOMIZATION_SURFACE_AUDIT.md](../extensions/CUSTOMIZATION_SURFACE_AUDIT.md).

## Verification

Deterministic tests cover distinct membership and reuse, admission before construction, saved
layout migration, manual/automatic geometry, stable controller identity, exact agent targeting,
ambiguous/stale target refusal, keyboard routing, geometry renegotiation and shared-device public
transaction exclusion. The production-shell evidence entry covers portrait and landscape pairs,
mixed orientations, three and four devices, Focus, a narrow viewport, System light/dark,
Cyberpunk and Swiss Minimalist. Hardware controls preserve their full 40-point targets and wrap
in a narrow pane.

The opt-in four-device lane now uses dedicated iPhone 17 Pro, iPhone 17, iPhone 16e and iPad mini
guests with an animated UIKit fixture. It verified actual portrait/landscape transitions, upright
pixels, landscape accessibility taps, continuous-contact handling around rotation, Focus and
restoration of four direct streams. All four stayed live for a 30-second workload; no public
screenshot fallback, stream failures or replacement device leases occurred. A fifth stream was
refused. The devices and fixture remain installed and booted for manual exploration.

The live test caught the earlier size-only assumption: UIKit can rotate inside a native-sized
framebuffer. The helper now observes screen UI orientation, rotates mapped pixels directly into
the bounded destination buffers, maps input back to native digitizer coordinates and avoids
double rotation of already-upright UIKit accessibility trees. Input from a public fallback frame
also preserves its native target when the recovered helper uses different axes.

This verifies the active Xcode 26.5/iOS 26.5 Debug path, with bounded fixture workloads. It does not
claim a Release energy result, unrestricted concurrent capacity or every guest workload. UI
baselines retain their existing hashes; generated evidence has not been approved as references.

The broad fast suite completed 10,424 tests with 84 opt-in/environment skips and zero failures.
The SimulatorKit orientation/protocol suite completed 26 tests with zero failures. The dedicated
live workspace case passed in 51.3 seconds, with six sampling intervals and inspected real-shell
portrait, landscape, mixed-grid, four-portrait and narrow-Focus captures. The remaining slower
on-screen UI scenarios and Release/energy lanes were not part of this verification.

Reproduce the focused checks with:

```bash
THREADING_STRESS=1 scripts/test.sh fast \
  -only-testing:ThreadingTests/SimulatorWorkspaceTests \
  -only-testing:ThreadingTests/SimulatorPaneRecoveryTests \
  -only-testing:ThreadingTests/SimulatorAgentToolTests

scripts/ui-evidence.sh --only simulator-pane

# Reuses this checkout's dedicated-device manifest, retaining the guests and fixture afterward.
scripts/simulator_workspace_verify.sh
# Or explicitly supply four already-booted dedicated devices:
scripts/simulator_workspace_verify.sh --devices <uuid>,<uuid>,<uuid>,<uuid>

# Holds the host-wide CoreSimulator lane; the first device is already booted.
# The second installed device is prepared and its exact boot lease is released by the test.
(
source scripts/coresimulator_lane_lock.sh
threading_acquire_coresimulator_lane 'multiple-simulator live verification' || exit
THREADING_SIMULATOR_INTEGRATION_UDID=<first-udid> \
THREADING_SIMULATOR_INTEGRATION_SECOND_UDID=<second-udid> \
  scripts/test.sh fast \
    -only-testing:ThreadingTests/SimulatorLiveIntegrationTests/testTwoExactDevicesDeliverIndependentLiveFrames
)
```

## Review of the first slice

A review pass before landing changed the presentation and fixed seven correctness defects; the
durable rules are in [simulator-pane.md](../architecture/simulator-pane.md).

- **Presentation.** One header row instead of two (no layout row or "N Simulators" chooser; the
  layout chooser appears with a second device and moves into the options menu below 340 points).
  Members hug their device: aspect-fitted screens, the name above and the status line under each,
  with the selected name on a plate. Alone, the chooser switches the device again rather than
  adding one; removal moved into the options and screen menus and selects the neighbour.
- **Correctness.** An Xcode without screen orientation now streams in native axes instead of being
  refused. A hidden helper notices rotation on input and element reads. Portrait element trees no
  longer depend on their root covering the display, and landscape matching tolerates non-integral
  point scales. A cancelled touch lifts where it is held, not at a corner. Public screenshots
  (fallback and hidden-pane agent captures) are turned upright. The fallback poll no longer
  suspends other sessions' direct streams of the same device every second. Selection and layout no
  longer re-brief the agent.

## Remaining increments

The four-helper app-wide budget is unchanged. A higher concurrent limit needs measurements of
helper and guest CPU, frame-buffer copies and footprint; thumbnail sizing does not reduce those
costs. Larger N should use paging or virtualization with identified paused members, or a measured
capacity increase. Reopen this when five or more simultaneous live devices are needed.

A Rotate-device operation is separate from following confirmed geometry and remains in the
[controls draft](../feature-drafts/simulator-pane-controls.md). Stream pooling across sessions is
worth revisiting if duplicate adoption measurably consumes capacity. Freeform nested splits,
input broadcast, combined recording and physical iPhone tiles remain separate product choices.
