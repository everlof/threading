# Spike: an `AppKit` module of our own, on Linux

> **An experimental Linux host, not a packaged app.** No Xcode target references this directory,
> and no standard Mac build gate runs it. Shared portable changes live in the product's `Sources/`
> and `Tests/` and are copied here byte-for-byte. `docs/feature-drafts/linux-host-runtime.md`
> remains the decision record; this directory holds the measurements and Linux host prototype.

## The question

The Linux draft rejects naming a compatibility module `AppKit`, for a stated reason: the macOS
build must be able to compile the portable surface *beside* real AppKit and use the real product as
the reference implementation. That is an argument about the laboratory, not about whether the trick
works. So: does it work, and what does it cost?

On Linux there is no system AppKit, so a module named `AppKit` is simply ours, and every
`import AppKit` in the repository resolves to it with no edit to any file.

## What it does

`swift build --product Harness` in a `swift:6.3.2-noble` container produces `Harness`, which runs the layout
correctness cases, prints the solver's scaling curve, and renders PNGs into `out/`.
`./analyse.py` groups a sweep's missing symbols into subsystems and reports how many must close
before a file compiles. `./build.sh` runs that build and ranks whatever did not resolve. `./sweep.sh` type-checks
every file in `Sources/Threading/UI/Design/` against the shim alone and classifies each one.

`./vendor.sh` copies real Threading sources in; `./vendor.sh --verify` proves they are
byte-identical to the repository. That check is the whole difference between a measurement and a
flattering one, and it is why the vendored file is copied rather than adapted.

## Runner checks

Run `python3 -m unittest discover -s Spikes/linux-appkit/tests` without Docker to check the
runner failure contracts. The UI build and sweep mount the repository so local package paths
resolve, and select `Harness` independently of the core slice. Both refuse failed builds;
`sweep.sh` takes modules from the selected build directory rather than searching old artifacts.

`coreslice.sh` verifies the vendored sources before starting Docker, saves complete build/run
logs under `out/`, and runs the already-built executable only after a successful build. It requests
`linux/arm64` explicitly and prints the actual architecture. Without arguments it builds the full
project-graph slice and runs fifteen on-disk contracts:

| Group | Checks | FINDINGS section |
|---|---:|---:|
| Graph reopen, incremental updates, stale writers, receipts and corrupt rows | 5 | 31 |
| Commit rollback, probe retry and required model reload | 3 | 32 |
| Historical authority migration, rollback and constraints | 3 | 33 |
| Future-schema refusal for checkpointed and live-WAL stores | 2 | 34 |
| Pinned-WAL move refusal and relocation of healthy/damaged project stores | 2 | 35 |
| Fresh-session capabilities, defaults and handoff admission | 1 | 41 |
| Shared Unix connector modes, descriptor inheritance and path refusals | 1 | 43 |
| Shared session binding, typed identity and attempt-scoped rollback | 1 | 44 |
| Shared hello-batch ordering, compatibility perspective and aggregate buffer bound | 1 | 45 |

The 45 production files are byte-identical to their sources. Fresh-session record assembly,
launch values, account command routing and bounded Codex rollout checks are shared with the app.
Live account discovery remains outside the slice, which includes neither RemoteKit nor a full
agent runtime. The debug harness uses
`@testable import CoreSlice` without widening the production APIs. Commit-refusal fixtures use
the existing preflight injection seam; no test fills the host disk. StateManager's quarantine and
recovery policy remain outside this executable.

`./coreslice.sh --sqlite` builds and runs nine independent storage contracts against the unchanged
production `SQLiteDatabase` and logger, symlinked from the verified core copies. They cover bound
values surviving close/reopen, statement lifetime and reset, transaction and commit rollback,
foreign keys, migration atomicity, future-schema refusal, pinned-WAL file moves, and typed
`SQLITE_FULL` recovery. Every test uses a disposable directory; the full-disk test limits SQLite's
page allocation rather than filling the host disk. Logs are `out/sqlite-build.log` and
`out/sqlite-run.log`. Passing these contracts verifies the wrapper, not `ProjectDatabase`, project
model encoding, or the complete application's recovery path.

## Experimental Linux host

### Start the native window from a clean Linux profile

On a Linux machine with Swift 6.3.2, SQLite, SDL2, Pango/Cairo, and `flock` installed:

```bash
./run-app.sh /absolute/path/to/an/existing/project
```

The development launcher builds the two host executables and `threading-ptyd`, imports the
canonical project directory into a local store, starts or reuses one background daemon, and opens
the native project window. It keeps data under
`${XDG_DATA_HOME:-$HOME/.local/share}/threading-linux-spike` and its socket under
`${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/threading-linux-spike`; the directories are
private to the user. If `codex` resolves to an absolute executable, the window also offers the
managed Codex action. Set `THREADING_LINUX_CODEX=` to run the terminal-only mode, or set it to an
absolute executable to choose a particular CLI. Closing the window leaves running children with
the daemon; running the command again opens the same stored projects and can reattach them.

This is a source-tree development entry point, not a packaged Linux release. The startup command,
project import, store lock, daemon rendezvous and process ownership are host-owned; it publishes
no new extension presentation surface. The native UI and provider limitations below still apply.

`./host-smoke.sh` builds `LinuxHost` and the production `threading-ptyd` in an arm64 Linux
container, then exercises a real shell through a PTY with an isolated store and daemon. Full
output goes to `out/host-smoke.log`. It checks terminal input/output, working directory, the initial
80×24 grid, child exit status, durable project/terminal records across host invocations, and
refusal of concurrent store ownership or a missing daemon. It also kills and replaces a watcher,
reattaches the same child PID with output replay, and checks raw keyboard input, live resize and
caller terminal-mode restoration through a real outer PTY.

Inside Linux, with a daemon already running:

```bash
LinuxHost /path/to/experimental-store /path/to/ptyd.sock list
LinuxHost /path/to/experimental-store /path/to/ptyd.sock run /path/to/project /bin/sh -c 'pwd; stty size'
LinuxHost /path/to/experimental-store /path/to/ptyd.sock attach TERMINAL_UUID
LinuxHost /path/to/experimental-store /path/to/ptyd.sock login-run /path/to/project /bin/sh python3 --version
LinuxHost /path/to/experimental-store /path/to/ptyd.sock codex /path/to/project /bin/sh /absolute/path/to/codex 'Inspect this project'
LinuxHost /path/to/experimental-store /path/to/ptyd.sock attach-agent SESSION_UUID
```

This is the first executable storage-to-runtime connection, not the native UI. It uses real
`Project`, `ProjectTerminal`, `ProjectDatabase`, typed terminal identities and the production PTY
wire kit. No shell is represented as an agent session. The store stays locked for the invocation;
a new terminal record is saved before spawn, so a failed launch may leave a dormant record.
The Linux transport adapter streams bounded chunks without accumulating a transcript.
Fresh agent sessions use one exact session-row insertion; the first agent in a new project and
its selected identity commit with that project in one transaction. Project terminals update only
their owning project row, and Codex-ID discovery updates only the standing session. Launch work
does not reconcile every saved conversation in the store.

Interactive callers enter raw keyboard mode while attached; the child starts at the caller's
terminal size and receives resize requests on SIGWINCH. Pipes use an 80×24 fallback. Linux signal
descriptors join the same input loop, allowing ordinary termination signals to restore the
caller's mode before returning. SIGKILL cannot run cleanup. Attach accepts only a terminal stored
in this database, reuses its identity and reports replay completeness; it does not claim exact
screen restoration from a cut history.

`login-run` uses the same `AgentLaunchPlan.inLoginShell` and `ShellCommand` as the shipping
macOS launcher. The shell path is explicit, and the executable can be resolved by that shell's
login PATH. This shares command composition, not provider flags, account routing or permission
policy; a manually invoked CLI remains a project terminal, not a managed agent session.

`codex` creates a genuine Codex agent record and uses the shared production command builder with
explicit Manual/read-only permission flags. It preserves the Linux caller's environment through
the shared inherited-identity filter and clears an inherited `CODEX_HOME` for the stored standard
account. `attach-agent` reconnects that persisted agent identity. The smoke uses an explicit
argument recorder, not an authenticated Codex installation: it verifies flags, prompt quoting,
storage and daemon identity, not provider execution. The headless `codex` command does not discover
a provider ID or offer resume; the graphical `--app-codex` path below does. No macOS credentials
are copied; Threading-managed credentials, multi-account routing, MCP and hook integration are
unavailable in this experiment.

Current CLI-host limits: incomplete provider/account launch policy, no graphical presentation,
and no app-level recovery. EOF sends the terminal's
conventional Ctrl-D byte. Closing the host disconnects it; the daemon owns the child lifetime.
This is a debug target using `@testable` access to the source slice, not a release distribution.

Customization gate: this experimental command-line host is deliberately host-only. Store ownership,
process execution, identity, protocol compatibility and persistence remain host responsibilities;
there is no new public extension component or appearance surface.

## What is in the shim

About 1,870 lines:

| File | What it answers |
|---|---|
| `Exports.swift` | `@_exported import Foundation` — the single line that makes 816 `NSRect` sites resolve |
| `Geometry.swift` | `CGAffineTransform` and the C-style constructors Linux Foundation lacks |
| `NSColor.swift` | sRGB with straight alpha, `setFill`/`setStroke` naming the current context |
| `NSBezierPath.swift` | Construction, flattening, and AppKit's independent per-axis corner clamp |
| `NSGraphicsContext.swift` | The state stack, the CTM, clip masks, `current` |
| `NSView.swift` | Frames, the subview list, `draw(_:)`, alpha, hit testing, the layout hooks |
| `Layout/NSLayoutConstraint.swift` | Constraints, priorities, the common-ancestor rule, `NSLayoutGuide` |
| `Layout/NSLayoutAnchor.swift` | The anchor family, generic exactly where AppKit is |
| `Layout/LayoutEngine.swift` | Constraints to a linear program, and frames back out |
| `Layout/Simplex.swift` | Two-phase simplex that retains `B⁻¹`, so a constant edit warm-starts through dual simplex |
| `Raster.swift` | Scanline fill, analytic horizontal coverage, 4× vertical supersampling |
| `PNG.swift` | Stored-deflate PNG, so the container needs no system library |
| `Stubs.swift` | `NSAnimationContext`, `NSEvent`, `NSFont`, `NSAppearance` — named, not implemented |

## What Linux Foundation already gave us for free

`NSPoint`, `NSSize`, `NSRect`, `NSEdgeInsets`, `NSCoder` and `CGFloat` are real types in
swift-corelibs-foundation, with `insetBy(dx:dy:)`, `integral`, `intersection(_:)`, `isNull` and the
rest already implemented. They are the first, fourth and seventh most-referenced symbols in
`UI/Design` and the shim owes them nothing but a re-export.

## Results

See `FINDINGS.md`.

## What this spike deliberately does not touch

Text shaping, IME, accessibility, layers, the window server, the event loop, and virtualization.
Auto Layout is present. Its solver is dense and solves a whole subtree at a time; it warm-starts a
constant edit but still pays a cold cubic cost for any structural change. See FINDINGS sections 8
and 11. Each is a real item in the draft's platform-leaf list, and none
of them is made smaller by the shim compiling.

## Working on this branch

This lives on `linux-appkit`, a long-lived branch, which is the arrangement that usually rots. The
three things that keep it from rotting here:

**The spike stays separate from the product.** This directory is not an Xcode target. Portable
`Sources/` and `Tests/` changes made while proving a Linux seam are ordinary macOS product changes:
test them through the shipping Mac build and bring them back to master promptly. Leaving those
changes only on this branch would turn a useful experiment into a product fork.

**It re-copies rather than remembers.** `./vendor.sh` re-reads the real files from the working
tree every time, and `./vendor.sh --verify` fails the moment a copy and its original disagree. So
drift is detected, not assumed.

**Every catch-up produces a number.** `./refresh.sh` rebases onto master, re-vendors, rebuilds,
re-sweeps, and prints the delta against `baseline/sweep.tsv` — by file name. That is the branch
paying rent: it reports whether ordinary macOS work is moving `UI/Design` towards or away from
portability, which nothing on master measures. `./refresh.sh --accept` adopts a new baseline, and
the baseline is committed alongside the change that earned it.

A reasonable cadence is a refresh whenever master has moved meaningfully — after a batch of
`UI/Design` work, or monthly, whichever comes first. Rebase rather than merge: the branch has one
author's worth of history and no published ref, so keeping it a clean stack of spike commits on top
of master is cheaper than a merge trail.

**Do not push it.** `submodule.recurse` is true in this repository and `master` stands a long way
ahead of `origin`; see the push rules in `CLAUDE.md`. This branch is local.

### Native Linux window experiment

`./window-smoke.sh` builds `WindowHarness`, opens a real SDL2/X11 window under Xvfb,
loads three projects from a disposable production store, and drives keyboard selection, pointer
selection, resize and dismissal through X events. The captured window is `out/window-native.png`.
With a Linux display and `libsdl2-dev` installed, run:

```sh
swift run WindowHarness /path/to/existing/experimental/store
```

The window is a platform-transport experiment, using the existing specimen views and the
byte-identical production bitmap font. It is not the shipping sidebar or a selected final Linux
backend. Up/Down and the wheel move selection; clicking a row selects it; Escape closes. The
native title names the selected project's full path. Selection is local to the window; it does
not change the store. Store open/recovery runs on a worker under the same exclusive lock as
`LinuxHost`, then releases the lock and returns an immutable snapshot. No live reload is claimed.

Only visible rows are mounted, and labels are bounded to 80 characters before drawing. The
software-rendering experiment limits windows to 1280×900 pixels. The project-list mode does not provide terminal rendering/input. The separate terminal mode
below adds the initial runtime surface; neither mode provides complete IME, AT-SPI, production
theme switching or extension composition. Unsupported
bitmap-font characters visibly become `?`; the native title retains the original path.
Customization classification: this diagnostic harness is host-only and defines no durable product
component or public API. Product navigation must still use the existing semantic component IDs,
with identity, selection, commands, lifecycle truth and input authority retained by Threading.

Launch environment policy is shared with macOS: `AgentEnvironment` strips the launching agent's
run identity while retaining account-directory exceptions and other caller values such as `PATH`
and `HOME`. Host preference/tool-directory discovery lives in `AgentEnvironmentHost.swift` on
macOS; Linux does not read those preferences or forward a Mac environment. The CLI host retains
its caller's terminal colour/pager claims because it does not yet own a graphical emulator.

### Full production PTY client on Linux

The host smoke also builds `PortablePTYClientHarness`, which drives the byte-identical
`PTYHostClient` against the real Linux daemon: spawn, disconnect, replay/reattach to the same
child, input, drain and authoritative exit. It checks write-queue overflow, a stalled socket's
write deadline, a closed peer without a process-global SIGPIPE override, and queued-write
cancellation. The CLI now uses this same production client; its former synchronous socket,
codec and handshake loop has been removed. A bounded `HostEventInbox` wakes the CLI's poll loop
and preserves stdout, stderr, controls and close order. It refuses more than 4 MiB of queued
payload/encoded controls or 1,024 events, including empty events. One drained batch can coexist
with the pending batch. Tests cover wakeup rearming, byte/count overflow and a 100,000-event
flood with no consumer. The real-daemon smoke also checks an exact 2 MiB live output stream.
The graphical terminal mode consumes the same event interface on its serial worker. CLI stdout
may still block its consumer, and libdispatch's internal read buffering has not been measured.

The Mac journal/availability adapter is `PTYHostClientHost.swift`; client limits are portable.
macOS retains DispatchIO writes. Linux uses a serial socket writer with a separately owned
descriptor, per-send SIGPIPE suppression and a whole-frame deadline. The production client
retains its aggregate queue bound. Many-client Linux throughput and shutdown latency remain
unmeasured; the transport probe is not a release readiness claim.

### Shared terminal emulator

`TerminalRuntime/PTYEmulator.swift` embeds the existing vendored SwiftTerm package directly.
It exposes immutable visible-cell snapshots (grapheme text, cell width, attributes, cursor and
bounded title) and sends terminal-query replies through a host callback. The serial worker owns
feed/resize/snapshot operations under SwiftTerm's lock. Grids are limited to 240×100 cells and
scrollback to 2,000 lines; snapshots copy the visible grid only. A window consumer must request
snapshots at display cadence with one outstanding request, rather than copying per output chunk.

The portable harness verifies byte-fragmented UTF-8, wide and combining characters, SGR color,
alternate-screen restoration, cursor replies, resize and local viewport navigation. It also connects this emulator to the
production client and a real Linux PTY child: the child validates the cursor reply, accepts a key,
reads its new 100×30 grid and exits 7. These are cell/runtime checks, not text-shaping or rendered
window evidence. The native terminal mode below consumes these snapshots and forwards keyboard input.
The emulator can parse historical feeds with query replies suppressed. The real-daemon harness
reconnects it using the additive `attached.replayByteCount` boundary and verifies that replay does
not answer an old cursor query again. The graphical `--attach` mode below uses the same boundary
and labels cut history. The project browser's saved-terminal picker uses that attachment path too.

SwiftTerm's transitive Linux dependencies are recorded in this spike's `Package.resolved`.
The host smoke also exercises its build-info generator against disposable unavailable, clean,
tagged and dirty Git metadata. The generator waits on its registered termination callback:
Swift 6.3.2 Linux Foundation's `waitUntilExit()` was observed hanging after Git had exited and
been reaped when this Docker mount could not resolve the worktree's host-side `.git` pointer.


### Native terminal mode

```sh
WindowHarness --terminal STORE SOCKET DIRECTORY /absolute/executable [ARG ...]
```

This mode opens a native SDL window, creates a durable project-terminal record in the production
SQLite store, and spawns through `PTYHostClient`. SwiftTerm parses on a serial worker; Pango/Cairo
rasterizes visible cells on a separate worker. The UI presents completed RGBA frames and handles
native events. One snapshot/render request may be outstanding and one completed frame is retained.
The window remains open after child exit and reports its authoritative status in the native title.
Closing the window ends its client connection; the daemon owns the child lifetime.

The diagnostic terminal uses a fixed 10×22 cell grid, a 16px DejaVu Sans Mono face with Pango font
fallback, and the emulator's current colors. Its current window bounds imply at most 128×40 cells.
UTF-8 committed text and legacy Ctrl-letter input are wired. Functional keys (Return, Tab,
Backspace, Escape, Delete, arrows, Home/End, Page Up/Down and F1–F12) use SwiftTerm's live encoder,
including modifiers and press/repeat/release. This honors application-cursor and negotiated kitty
modes for those keys. Complete enhanced printable-key, keypad, Insert and IME support remains
outstanding; this is not full keyboard-protocol parity. Pango shapes individual cell graphemes;
cross-cell joining, full IME composition, accessibility and live profile/theme configuration
remain outstanding.

The native pointer sends button presses, releases and bounded wheel steps through SwiftTerm's
live DEC mouse mode and encoding. X10 sends presses only; VT200-style modes send releases too.
With tracking off, button events do not reach the child. On the normal screen, wheel input
instead moves through the retained 2,000-line history, holding the viewed rows as new output
arrives and hiding the live cursor until the viewport returns to the end. The alternate screen
turns wheel steps into cursor keys when its alternate-scroll mode is enabled. Shift bypasses
mouse reporting unless the child requested shift capture; Alt requests local wheel scrolling.
Project-list clicks and wheel navigation keep their own route. A local left-button drag selects
text through SwiftTerm's selection service; Ctrl+Shift+C copies up to 1 MiB of selected UTF-8
to the native clipboard, including held scrollback and output from a child that has exited.
Pointer motion is coalesced to one pending worker operation and the snapshot paints only selected
visible cells. Mouse-tracking programs still own ordinary clicks; Shift permits local selection
unless they request shift capture. DEC drag/motion reports, double/triple-click selection and a
visible scroll indicator remain absent.

Ctrl+Shift+V pastes UTF-8 text from the native clipboard. The host accepts at most 64 KiB per
gesture, refuses larger or invalid text without sending a prefix, and forwards the accepted bytes
on the ordered terminal worker. The live SwiftTerm mode decides whether to wrap them in bracketed
paste markers; the shortcut key itself is not forwarded to the child. Clipboard retrieval is an
SDL/X11 platform operation on explicit user input, not part of the frame loop; SDL may allocate the
source text before the host can reject an oversized selection. Rich clipboard types and IME
composition remain unimplemented.

Customization classification: this is a host-only diagnostic embedding of the terminal surface,
not a new public extension component. Store identities, launch admission, input authority,
process ownership and exit truth remain host-owned. The renderer is a platform experiment, not
a replacement product theme or a claim of release readiness.


`tests/terminal_stress_child.py` is an opt-in dense-grid workload for this mode: pass
`/usr/bin/python3 /absolute/path/to/terminal_stress_child.py` as the executable/arguments and
resize to 1280×900, press `g` to begin and `p` to probe input during output. It emits 300 full grids
at 60 Hz and then stops. `THREADING_LINUX_TERMINAL_STRESS=1 ./window-smoke.sh` automates that
sequence, verifies exit/idle behavior and reports timing distributions. `TERMINAL_FRAME` logs report
worker rasterization and UI presentation time; frame preparation is admitted at most every
33 ms, with one outstanding request. This fixture is separate from the small interactive
Unicode/input scenario and does not establish a many-session performance budget.


The renderer caches shaped ASCII layouts within each frame (95 printable characters × two
weights at most). Unicode keeps the direct Pango path, including fallback and color fonts.
`tests/terminal_renderer_contract.py` requires cached output to be byte-identical to direct Pango
for its mixed-cell fixture. Set `THREADING_TERMINAL_REFERENCE_RENDERER=1` alongside the stress
flag to measure the direct path with the same native workload and geometry.

The first matched dense-grid measurement reduced worker draw median from 33.90 ms (direct Pango)
to 18.17 ms (cached layouts), with pixel-identical native screenshots. UI presentation tails did
not improve, so this is a renderer-work reduction rather than a latency guarantee. Full results,
the rejected mask experiment and measurement limits are in FINDINGS §50 and `performance.md`.


Text and functional events share the terminal worker's ordered input path and call
`Terminal.sendUserInput`, preserving semantic interaction state alongside transport. Admission
is capped at 256 pending events (plus the executing event), with at most 32 UTF-8 bytes per text
event. Overflow is explicit. `terminal_keyboard_child.py` verifies the actual native key bytes
while the child changes modes; a trailing text marker after keyup separates each mode transition.
`terminal_clipboard_child.py` verifies pasted Unicode and newlines through a real PTY in both
bracketed and plain modes, with a third stage refusing an oversized clipboard.

### Navigate projects, saved agents and live terminals in one window

With an existing experimental store and a running daemon:

```bash
WindowHarness --app /path/to/experimental-store /path/to/ptyd.sock /bin/bash -l
WindowHarness --app-codex /path/to/experimental-store /path/to/ptyd.sock /bin/bash /absolute/path/to/codex
```

Select a project with Up/Down or a click, then press Enter to open its shell. Ctrl+Shift+P
returns to projects; Enter revisits that project's existing terminal, including its child and
emulator state. Right opens the selected project's saved terminals, newest first. Up/Down or a
click selects one and Enter attaches it; Left or Escape returns to projects. A star marks a
runtime retained by this window. Left from projects opens saved agent sessions, also newest
first; Enter attaches the selected agent through its own persisted identity. Both pickers retain
their selection when returning from a terminal with Ctrl+Shift+P. Alt+F4 closes the window,
Escape closes from projects, and Escape remains terminal input while in a shell.
In `--app-codex` mode, Ctrl+Shift+A on a project creates a fresh managed Codex session with the
shared Manual permission and read-only sandbox defaults, opens it in the same terminal window,
and adds its saved identity to the agent picker. The picker reattaches daemon-held children and,
when the daemon no longer holds one, resumes the exact stored provider ID after finding its
rollout under the standard Codex account. It refuses a missing or known-broken rollout before
spawning. `env -u CODEX_HOME` prevents an inherited alternate login from silently taking over
that standard-account record.
After the initial full project-window snapshot, selected-agent attach, rollout-ID persistence and
resume read only the indexed session and its owning project row. This validates the target without
decoding every retained conversation again. The initial snapshot and saved-terminal identity
lookup still load the complete graph; a project's own embedded terminal array is still decoded
when that project is the selected agent's owner.

This host-only diagnostic mode retains at most eight runtimes total across fresh and restored
terminals and agents, and requests frames only for the visible terminal. It saves each new
terminal through the production store before spawning through the production PTY client. The
fixed initial snapshot projects at most the newest 512 agents and 512 terminals per project
into their pickers and constructs only viewport rows. New agents created by this window join
its in-memory catalogue after persistence. It does not restore any runtime automatically;
explicit `--attach` and
`--attach-agent` are also available below.

The project catalogue is an initial snapshot plus this window's newly created terminal counts
and agent sessions; external store changes are not live-synchronized. Closing the window
disconnects its clients; the daemon continues to own children that are still running.

A terminal launch or transport failure in `--app` stays on an unavailable view with its cause.
Ctrl+Shift+P still returns to projects, and other retained terminals remain usable. Revisiting a
failed entry preserves the failure rather than retrying automatically. From projects, Ctrl+Shift+N
explicitly replaces an exited terminal or a failed launch proven not to have left a child. Enter still revisits the retained terminal. Live children and failures with
uncertain child ownership refuse replacement; a lost connection is not proof of exit. Standalone
`--terminal` still exits nonzero on failure for use in diagnostic scripts.

### Reopen a graphical terminal by its saved identity

After closing its original window or CLI client, obtain the saved terminal or agent-session UUID
with `LinuxHost STORE SOCKET list`:

```bash
WindowHarness --attach /path/to/experimental-store /path/to/ptyd.sock TERMINAL_UUID
WindowHarness --attach-agent /path/to/experimental-store /path/to/ptyd.sock SESSION_UUID
```

The second command opens a saved agent session created by `LinuxHost codex` in the same native
terminal window. Each command validates that its typed identity belongs to the store, attaches
the existing daemon child and adopts its grid by sizing the window. Neither command creates a
record or sends an initial resize.
Historical terminal queries are parsed without sending replies; input and rendering begin only
after the announced replay bytes have arrived. A cut replay remains marked `[history cut]` in
the window title. A missing/invalid boundary or incomplete replay fails explicitly, with a
five-second attach/replay wait after sending the request.

The current native window supports attached grids up to 128 columns by 40 rows; larger saved
grids are refused rather than resized implicitly. The integrated picker exposes the same attach
path from a project's saved identities. Automatic restoration, exact graphical detach seeds and
full scrollback reconstruction remain unfinished.
