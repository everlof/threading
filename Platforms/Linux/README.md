# Linux preview host and AppKit compatibility layer

> **Maintained Linux platform code for an Ubuntu arm64 preview, not a release app.** No Xcode
> target references this directory. Shared portable changes live in the product's `Sources/`
> and `Tests/`, or in local packages; the core slice copies its selected app sources byte-for-byte.
> `docs/feature-drafts/linux-host-runtime.md` records the original architecture and measurements.
> This directory owns the Linux host, compatibility layer, packaging, tests and ongoing findings.

## The question

The Linux draft rejects naming a compatibility module `AppKit`, for a stated reason: the macOS
build must be able to compile the portable surface *beside* real AppKit and use the real product as
the reference implementation. That is an argument about the laboratory, not about whether the trick
works. So: does it work, and what does it cost?

On Linux there is no system AppKit, so a module named `AppKit` is simply ours, and every
`import AppKit` in the repository resolves to it with no edit to any file.

## What it does

`swift build --product Harness` in a `swift:6.3.2-noble` container with `libpango1.0-dev`
installed produces `Harness`, which runs the layout
correctness cases, prints the solver's scaling curve, and renders PNGs into `out/`.
`./analyse.py` groups a sweep's missing symbols into subsystems and reports how many must close
before a file compiles. `./build.sh` runs that build and ranks whatever did not resolve. `./sweep.sh` type-checks
every file in `Sources/Threading/UI/Design/` against the shim alone and classifies each one.
This per-file report is a candidate-gap map: methods supplied by another Design file, such as
`NSTextField.applyFont`, also appear missing until those files are compiled together. Missing
app-owned types can also prevent Swift from inferring an enum member, hiding a genuine shim gap.

`./vendor.sh` copies real Threading sources in; `./vendor.sh --verify` proves they are
byte-identical to the repository. That check is the whole difference between a measurement and a
flattering one, and it is why the vendored file is copied rather than adapted.

`./shim-smoke.sh` builds and runs `Harness` on Linux, checks every layout correctness case and
three rendered PNG specimens, then injects a layout failure to verify that the executable exits
nonzero before rendering. It skips the optional scaling benchmark in this smoke; ordinary
`Harness` runs retain that measurement. Fresh images and logs remain under `out/shim-smoke.*`
for visual inspection.

`tests/glyph_view/typecheck.sh` checks the exact production `GlyphView` and
`TemplateImageDrawing` files together against shim AppKit. Its test-only theme declarations
stand in for macOS policy without supplying any missing platform method.
`tests/glyph_view/render.sh` builds those same source links as `GlyphViewHarness`, checks actual
1×/2× bitmap pixels, template tint, original artwork colours, aspect fit and accessibility, and
keeps fresh PNGs under `out/glyph-view.*` for visual inspection. The same fixture checks the
Linux `NSImageView` shim at 1×/2×, including proportional sizing, translucent template tint,
untinted artwork, intrinsic size and decorative accessibility. The native window now mounts the
unchanged production `GlyphView` for visible provider marks, with the same bounded row slots;
the diagnostic host supplies decoded artwork and tint but has no SF Symbol provider. The
`Harness` specimen also renders a tinted mark inside its retained navigator row and checks its
pixels after layout, guarding the fixed-frame contract used by the native window. Visible
project rows also use the unchanged production `GeneratedProjectIcon` fallback at its Mac 16pt
size; the specimen checks that separate slot and the native X11 capture is compared with Mac
renders of the same two names. The generated-image cache is capped at 256 names.
`tests/stack_layout/run.sh` compares stack geometry and an unchanged production `ControlRowView`
against the Linux shim; `--mac` runs the same fixtures against AppKit. The Linux fixture also
checks rendered control pixels in `out/control-row-stack.png`. Both runs now cover
`NSView.fittingSize` without changing live frames and fixed versus flexible children under
top/leading stack gravity. `tests/subagent_row/run.sh` links the unchanged production
`SubagentNavigatorRowView` in a fixed-palette fixture; `--mac` provides a rendered reference.
The Mac/Linux captures in `out/subagent-row-{mac,linux}/` align the row's title and detail
lines, and the fixture checks selection, unavailable help and transcript reveal actions.
The complete Subagents card remains unmounted in the native window.
`tests/icon_button/run.sh` links the unchanged production `ThemedControl`, `ThemedIconButton`,
`PointerClaims`, `SurfaceDrawing` and `GlyphView` to the Linux shim. It checks hover, pressed,
focus and disabled pixels, cursor-claim precedence, drag cancellation, release after view
detachment, keyboard and accessibility activation. Five fresh PNG states remain under
`out/icon-button.*` for inspection. The native window mounts the production icon control in
its header and as the visible project-row `+`/`⋯` pair, using a bounded Linux symbol/theme
source and the retained SDL pointer route.
`tests/pane_header/run.sh` links the production `PaneHeaderView`, `PaneFooterView`,
`OpticalInsets` and `SeparatorView`; `--mac` supplies the AppKit reference. The fixture
checks the default 41-point band, title compression, optical margins, unchanged control
targets, separator and bounded constraints through a wide/narrow/wide resize. Its five
rendered states and geometry are written to `out/pane-header-{linux,mac}/`. The native
window now mounts that same header with its retained title and `+`/`⋯` controls, and publishes
their actual laid-out bounds to native input and AT-SPI. The native command menus also mount
the production `ThemedMenuRowView` through its shared measurement plan. The installed shell
uses a source-derived light/dark snapshot of `AppThemeStyles.threading`. Ctrl+Shift+T switches the
appearance in the same window, invalidating the retained sidebar, idle pane, terminal header,
open menu and visible terminal grid. `scripts/export_theme_snapshot.py` regenerates the resource;
`LinuxThemeSnapshotTests` compares its values with production theme resolution on macOS. The
Linux AppKit shim only resolves the selected named colors. Full theme configuration and complete
navigator/menu presentation remain open.
`tests/page_title/run.sh` links the production `PageTitleView` with a Linux Pango label adapter
for its Apple-only title animation. The native workspace mounts that title in a separate
41-point right-pane header. Its press reveals the active project or saved runtime in the
navigator. Saved agent pages now show its production Actions control and a retained overlay
of production `ThemedMenuRowView` rows. The scoped Linux menu copies the saved session ID or
owning project path; the host revalidates the active page and project before each command.
Pointer, keyboard and AT-SPI actions reach the same menu and clipboard path. Terminal
paint, PTY grid size, pointer input, IME caret and AT-SPI text geometry share the resulting
82-pixel content inset. The right header is retained separately from terminal frames, so PTY
output does not rerasterize it.

Before a terminal is selected, `--app` now opens the same 320-pixel navigator beside the
production `SessionPlaceholderView`. It shows **No Session Selected** and a **New Session**
button, or **No Projects Yet** and **Add Project** for an empty store. The host supplies the
fixed diagnostic colors, symbol artwork and action admission; the view owns its layout and
button behavior. The idle pane retains one bitmap and republishes it only on resize or
interaction. Its button is available through pointer, keyboard and AT-SPI, and the terminal
node enters the accessibility tree only after a terminal opens.

Visible project slots now mount the same `ThemedProjectRowView` subtree as the Mac
`ProjectRowView`: icon, shaped title, optional count and trailing `+`/`⋯` controls share one
production layout. The Linux host retains project identity, selection, menu admission and PTY
ownership. The shim clips nested views to their bounds and preserves subview ordering so the
count sits behind hover controls. A project with saved runtimes now exposes an inline disclosure
in the same bounded list. Its visible agent rows mount the production
`ThemedSessionRowContentView` used by Mac session cells. Visible saved terminals now mount the
same `ThemedTerminalRowContentView` icon/title subtree as the Mac terminal cell, with a bounded
Linux terminal symbol. Project selection, runtime activation, attention, retained state and
AT-SPI identities stay host-owned. The saved-runtime pickers remain available; the account picker
mounts the production `ThemedMenuRowView` with the same row measurement as command menus while
the host retains exact account identity and launch admission. The shim has a clipped
`NSScrollView`/`NSClipView` viewport and view-based `NSTableView`/`NSOutlineView` with bounded
cell reuse, stable selection and expansion. `tests/outline_view/run.sh` exercises 5,100 roots,
1,024 expanded children, scrolling, resize and detach. The native window's project navigator now
mounts that outline as its visible-row owner: wheel input moves its clip viewport, and visible
project, saved-agent and saved-terminal cells reuse the production row content. The host still
owns exact selection, actions, terminal admission and AT-SPI publication. The installed X11
`native_outline_smoke.py` checks 5,100 projects, expanded children, scrolling, pointer and
keyboard selection, resize and middle/tail project restoration.
`tests/sidebar_visible_rows/run.sh` checks a 5,100-project tree with
bounded child projection; `--session-row-layout-fixture` and `--terminal-row-layout-fixture`
check the shared title/icon stacks at their native slot sizes. The installed X11 smoke captures an
expanded project and verifies
pointer, keyboard, AT-SPI and inline saved-terminal activation.
The table and outline shims now mount each visible cell inside a reusable `NSTableRowView`,
with row-view delegate hooks and selection state tied to stable row identity. The focused
outline fixture bounds row chrome allocation while scrolling a 5,100-project tree and checks
that moving selection clears the previous visible row. Cached row offsets support the production
28-point runtime and 30-point project heights without scanning the catalogue on pointer movement
or viewport changes. The native navigator mounts the unchanged production
`SidebarHoverRowView` for hover and selected-row chrome, including live Threading theme colors
and native-window selection strength. The Linux snapshot does not yet carry a verified working
state, so its activity beam remains inactive.
`tests/text_label/run.sh` checks the Linux-only, Pango-backed `NSTextField` label against
Unicode shaping, clipping, ellipsis, intrinsic size, baseline behavior and shared neutral-ink
contrast on eight grounds, then renders that
unchanged `ControlRowView` with real Latin and Arabic labels to
`out/text-label-control-row.png`. It also renders an upright label inside a flipped parent to
`out/text-label-flipped.png`. It also checks `preferredMaxLayoutWidth`: plain and attributed
wrapping measurements respond to the width, line limit and a reset to natural size. The
same fixture links the unchanged production
`ThemedMultilineTitleLabel`, checks authored line breaks, bounded intrinsic measurement and
accessible text, and renders it inside a constrained host to
`out/text-label-multiline-title.png`. It also checks bounded Pango attributed drawing across
mixed Unicode, color, underline and alpha runs, then links the unchanged production
`CompoundValueLabel` to verify whole-segment fitting, painted pixels and accessible text in
`out/text-label-compound.png`. Bounded `NSString` drawing also supports measured point text and
rectangle wrapping, clipping, truncation and alignment. The fixture links the unchanged
production `SimulatorRecordingBadge`, verifies its title, pixels and accessibility action, and
renders recording and finishing states. Pango-backed `NSFont.boundingRectForFont` and the typed
accessibility group role also let the fixture link the unchanged production
`StorageProposalOutlineView`. It checks a 170-row cleanup proposal at the first and last scroll
viewport, its full accessible value, and remeasurement when fonts change; see
`out/text-label-storage-first.png` and `out/text-label-storage-last.png`. In Release,
`THREADING_LABEL_CONFIGURATION=release tests/text_label/run.sh --benchmark` compares 170 and
1,700 rows in a 180-pixel viewport. The same fixture links the unchanged production
`ThemedBarSparklineView` and checks inherited light/dark appearance changes, pixels and
accessibility in `out/text-label-sparkline-light.png` and
`out/text-label-sparkline-dark.png`. Its colour roles are fixture values. The same fixture retains
named `NSColor` recipes while switching appearance and renders their alpha variants with measured
system label and window ink in `out/text-label-dynamic-light.png` and
`out/text-label-dynamic-dark.png`. The shim scopes `NSAppearance.currentDrawing()` by render
thread through layout and drawing; the system appearance bridge and full colour catalogue remain
open. The fixture also links unchanged production `NativePluginPresentationBoundaryView` and
checks that its system-chrome permission follows only the installed plugin subtree, even after
reparenting; the shim now answers AppKit's descendant and inherited-hidden queries. Editing,
text selection, advanced paragraph layout and IME remain
outside this label implementation. The native window mounts visible navigator fragments through
this leaf.
`tests/search_match/run.sh` links unchanged production `SearchMatchLabel` through the same
Pango-backed label path and checks highlighted attributed pixels, a one-line ellipsis, cell
truncation behavior and the full accessibility value. `out/search-match.png` is its inspected
render; editing and IME remain separate gaps.

The text-label fixture also checks the shim's bounded `NSWindow.contentView` ownership and
`NSView.window` lifecycle against callback order measured with macOS AppKit. It covers subtree
attachment and removal, same-window and cross-window reparenting, moving a content root between
windows, and assigning the same root twice. `NSWindow` provides content ownership and
`layoutIfNeeded()` here; SDL still owns the native window. The native preview attaches one
root for the SDL window's lifetime. Its project outline reuses visible cells; the remaining
picker and empty-state paths retain bounded row and label slots across frames.
It still assembles some diagnostic rows rather than a complete production screen. See `FINDINGS.md`
§§124–125. The content owner now also keeps AppKit first-responder state and offers key
equivalents down the retained view tree. The focused fixture links the unchanged production
`KeyEquivalentScopeView` and checks that its shortcut runs only while its subtree owns focus,
including a field editor delegate. Native project-row presses enter the retained tree through
`NSView.hitTest` and `mouseDown`; the outline's stable item resolves through the host's selection path.
Production menu rows receive hover and press/release through that tree while the host retains
command admission. Navigator Up/Down keys advance selection, while sidebar wheel turns move the
outline's clip viewport. Terminal input and other keyboard commands keep their native routes.
The production pane header and Add Project/Actions controls are mounted and interactive in
this preview; broader production chrome remains outside the diagnostic shell. See
`FINDINGS.md` §§126–129, 131, 136–139, 147.

`tests/wayland_smoke.sh` installs the current `.deb` into Swift-free Ubuntu under headless Weston,
checks two distinct rendered project frames, and verifies Wayland toplevel/buffer commits. Its
separate `--actions` mode checks AT-SPI Actions open/close and changed pixels. The package
selects Ubuntu's Cairo libdecor plugin for its Wayland window, preserving the custom Actions
accessibility tree alongside client decorations. The default installed package passes both
smoke modes under headless Weston. Its compositor-injected seat verifies header and project-row
pointer actions, right-click, Shift+F10 and menu drag release. Physical devices and IME behavior
remain unverified.

## Runner checks

Run `python3 -m unittest discover -s Platforms/Linux/tests` without Docker to check the
runner failure contracts. The UI build and sweep mount the repository so local package paths
resolve, and select `Harness` independently of the core slice. Both refuse failed builds;
`sweep.sh` takes modules from the selected build directory rather than searching old artifacts.

`coreslice.sh` verifies the vendored sources before starting Docker, saves complete build/run
logs under `out/`, and runs the already-built executable only after a successful build. It requests
`linux/arm64` explicitly and prints the actual architecture. Without arguments it builds the full
project-graph slice and runs the on-disk contracts below:

| Group | Checks | FINDINGS section |
|---|---:|---:|
| Graph reopen, incremental updates, stale writers, receipts and corrupt rows | 5 | 31 |
| Commit rollback, probe retry and required model reload | 3 | 32 |
| Historical authority migration, rollback and constraints | 3 | 33 |
| Future-schema refusal for checkpointed and live-WAL stores | 2 | 34 |
| Pinned-WAL move refusal and relocation of healthy/damaged project stores | 2 | 35 |
| Fresh-session capabilities, defaults and handoff admission | 1 | 41 |
| Shared session row identity, title precedence and host presentation boundaries | 1 | 99 |
| Shared terminal launch recording | 1 | 72 |
| Shared saved-terminal start directory and typed ownership | 1 | 102 |
| Bounded project navigation, selected identity and partial-read write fence | 1 | 74 |
| Shared Unix connector modes, descriptor inheritance and path refusals | 1 | 43 |
| Shared session binding, typed identity and attempt-scoped rollback | 1 | 44 |
| Shared hello-batch ordering, compatibility perspective and aggregate buffer bound | 1 | 45 |

The 47 production files are byte-identical to their sources. Fresh-session record assembly,
terminal launch recording, launch values, account command routing, bounded Codex rollout checks
and Claude transcript paths are shared with the app.
Live account discovery remains outside the slice, which includes neither RemoteKit nor a full
agent runtime. The debug harness uses
`@testable import CoreSlice` without widening the production APIs. Commit-refusal fixtures use
the existing preflight injection seam; no test fills the host disk. StateManager's quarantine and
recovery policy remain outside this executable.

`./coreslice.sh --navigation-stress` makes a disposable 5,100-session store and compares the
complete graph read with bounded navigation, new-agent creation and terminal project reads on
that same store in a Release build. Fixture creation is reported separately. This is an opt-in
scaling check, not a launch-time measurement of the native window or a replacement for the
behavioral contracts.

`python3 tests/raster_bounds/run.py --output /tmp/threading-raster-bounds` compares the native
navigator's raster leaf with its frozen reference. It checks raw RGBA and quantized-mask equality
for fractional geometry, offscreen paths, holes, nested clips, translucent strokes and the actual
navigator chrome at three viewport sizes, then reports repeated render timings. The context now
stores clip alpha only within a path's device-pixel bounds; the fixture still compares all eight
raw artifacts with its frozen raster oracle. Add
`--optimization O --cpu-timings` for optimized code with process CPU measurements alongside elapsed
time, or `--profile-mask` to also attribute clip-mask CPU in scratch copies of each implementation.
Each comparison keeps its images in a fresh directory identified by `report.json`, so reusing an
output path cannot let an older image satisfy a missing output in the current run.
This measures drawing in isolation; native startup remains covered by
`THREADING_LINUX_STARTUP_ONLY=1 ./window-smoke.sh`. Add `THREADING_LINUX_STARTUP_TRACE=1` to
that command for first-frame phase timings, including SDL, raster, Pango and presentation.

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

On a Linux machine with Swift 6.3.2, SQLite, SDL2, Pango/Cairo, ATK/AT-SPI, Zenity,
and `flock` installed:

```bash
./run-app.sh /absolute/path/to/an/existing/project
./run-app.sh
```

The first command imports the canonical project directory into a local store and opens that
project even when the store contains others. The no-argument command follows a saved selected
agent or standalone terminal to its project; with no selected runtime, it opens the saved project
list, including from a clean profile. In an empty list, activate **Add project folder** with
Enter or a click; Ctrl+Shift+P opens the same native folder dialog from any project list.
Choosing an existing directory imports and selects it without starting a child. Cancellation
leaves the list unchanged; choosing an already imported directory selects its existing row.
The header `+` opens **Add Project** with **Start New Project…**, **Use an Existing Folder…**,
and a separated **New Scratchpad** choice. New Project asks for a folder name and place;
Scratchpad creates or reopens `~/Threading/Scratchpad` without a chooser. Both select their
durable project row without starting a child.
The two launcher commands build the two host executables
and `threading-ptyd` when needed, and start or reuse one background daemon.
If the saved selected runtime belongs to the chosen project, the window checks the daemon after
releasing the store lock. It attaches only to that exact live child. A held agent exit is saved
to its row; an absent or exited standalone terminal opens the project list. A failed daemon query
still attempts attach and surfaces its failure. Startup never spawns a child. A selected agent
older than the recent window is fetched by identity; a selected terminal older than the recent
window is found in its owning project payload. Both appear within their 512-row picker limits.
Otherwise the project list opens without starting a child. Enter opens a shell; the saved-agent
and saved-terminal pickers can reattach other runtimes. Explicitly opening an exited or absent
saved terminal starts a fresh shell under that same terminal identity, using its stored directory
when available or its owning project as fallback. The saved name, settings and creation date stay
unchanged. A failed ownership query does not authorize a start, and a lost spawn reply does not
authorize a retry. A definitive refusal permits another explicit activation and fresh survey.
Newly created shells enter the saved-terminal picker as soon as their record is saved. Project
and saved-row navigation share one retained runtime, including after a same-ID restart.
Saved shells remember their live working directory through local OSC 7 reports and a one-second
Linux root-process sample. Sampling requires the daemon's original PID/start-time identity;
older replies still permit live OSC updates. Reopening uses the remembered directory, with the
owning project as fallback when it is gone. Busy storage does not interrupt the shell. Close/exit
attempts a final write, and app shutdown waits at most two seconds. A shell without OSC 7 can
change directory and exit between samples, leaving the previous directory saved.
It keeps data under
`${XDG_DATA_HOME:-$HOME/.local/share}/threading-linux-spike` and its socket under
`${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/threading-linux-spike`; the directories are
private to the user. If `codex` or `claude` resolves to an absolute executable, the window also
offers its managed agent action. Set `THREADING_LINUX_CODEX=` or `THREADING_LINUX_CLAUDE=` to disable
that provider, or set either to an absolute executable to choose a particular CLI. Clear both for
terminal-only mode. Closing the window leaves running children with
the daemon; running the command again opens the same stored projects and can reattach them.

`THREADING_LINUX_RESTART_ONLY=1 ./window-smoke.sh` checks explicit saved-shell restart with the
same record and a new PID, live reuse, stored-directory fallback, exact argv/initial grid and
attach-only startup. Controlled peers cover definitive refusal, lost spawn replies and unavailable
ownership. The installed Release package runs these same fixtures in `./bundle-smoke.sh`.
Native AT-SPI coverage also checks immediate saved-row admission and project/saved-picker runtime
reuse without duplicate records or terminal counts, the 512-row/eight-runtime limits, and counts
after folder import.
The directory fixtures exercise plain bash without OSC 7, Unicode paths, same-ID restart,
live reattachment, original project ownership and deleted-directory fallback. Controlled peers
cover missing/wrong process start times, unrelated PIDs, historical and fragmented replay OSC 7,
and valid live directory reports when process sampling is unavailable.
In a Codex-enabled project list, Ctrl+Shift+I opens the native login chooser; Up/Down and Enter
select the login used by the next Ctrl+Shift+A launch. It lists the standard home and up to 31
marker-backed `HOME/.codex-*` homes, with a one-time worker scan when the window opens. An explicit
`THREADING_LINUX_CODEX_ACCOUNT` chooses the initial handle, including one that is unavailable;
the chooser can replace it. The selection lasts for this window only. Saved sessions retain their
own account handle, so opening one never follows a later chooser change.

`./package-app.sh` builds a static-Swift archive and installable `.deb` for Ubuntu 24.04 arm64;
`./bundle-smoke.sh` builds both in the pinned Swift container, then exercises the extracted
archive and installed package in a fresh Ubuntu runtime container with no Swift toolchain or
source checkout. It also runs the packaged project-row layout fixture through an 800/320/800
pixel sidebar resize. The outputs are `out/threading-linux-preview-ubuntu24.04-arm64.tar.gz` and
`out/threading-linux-preview-ubuntu24.04-arm64.deb`; usage is in `BUNDLE_README.md`. The package
adds a desktop entry and icon, but has no updater or distro-wide compatibility claim. Its host
binaries currently require Swift's `-enable-testing` build flag because the
experimental host imports the core slice with `@testable`; product modularization remains open.

The project list's
import action is deliberately host-only: Threading owns directory identity, duplicate detection,
store locking and import; Zenity owns the platform folder dialog. It publishes no new extension
presentation surface. The native UI and provider limitations below still apply.

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
LinuxHost /path/to/experimental-store /path/to/ptyd.sock codex /path/to/project /bin/sh /absolute/path/to/codex 'Inspect this project' [codex-work]
LinuxHost /path/to/experimental-store /path/to/ptyd.sock claude /path/to/project /bin/sh /absolute/path/to/claude 'Inspect this project' [claude-work]
LinuxHost /path/to/experimental-store /path/to/ptyd.sock resume-claude SESSION_UUID /bin/sh /absolute/path/to/claude
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
account. An optional legacy handle such as `codex-work` routes through the matching
`HOME/.codex-work` only when it has an `auth.json` marker. `attach-agent` reconnects that
persisted agent identity. The smoke uses an explicit
argument recorder, not an authenticated Codex installation: it verifies flags, prompt quoting,
storage and daemon identity, not provider execution. The headless `codex` command does not discover
a provider ID or offer resume; the graphical `--app-codex` path below does. No macOS credentials
are copied; Threading-managed credentials, MCP and hook integration are unavailable in this
experiment.

`claude` creates a durable Claude Code session record with the same portable command pair used by the
macOS remote host. It records its UUID as the provider session ID before spawning, passes the
shared Manual permission flag, and clears an inherited `CLAUDE_CONFIG_DIR` so the standard
handle means `HOME/.claude`. An optional legacy handle such as `claude-work` routes through
`HOME/.claude-work` only when it contains `.claude.json` or `settings.json`; an unavailable
handle refuses before writing a session. `resume-claude` takes a saved session UUID, reads only
that row and its owning project, then checks the recorded account and exact transcript before
starting `--resume` under the same session identity. It refuses an unavailable named account or
transcript without creating another conversation. `attach-agent` reconnects a daemon-held child. Its
recorder smoke verifies the child arguments, environment, durable selection and exact-row writes,
not an authenticated Claude installation.

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
| `NSColor.swift` | sRGB with straight alpha, retained named/dynamic ink, and `setFill`/`setStroke` naming the current context |
| `NSBezierPath.swift` | Construction, flattening, and AppKit's independent per-axis corner clamp |
| `NSGraphicsContext.swift` | The state stack, the CTM, clip masks, `current` |
| `NSView.swift` | Frames, retained tree and containment queries, `draw(_:)`, alpha, hit testing, and layout hooks |
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

## Current platform gaps

The installed preview runs a native window, project and session navigation, terminal and provider
journeys, text shaping, and an accessibility tree. Visible project, agent and terminal rows mount
shared production content, the idle pane mounts the production placeholder, and command menus use
production rows. Account rows remain diagnostic;
a complete production screen is not mounted.
Editing and IME, full table and outline behavior, animation,
system services, and the remaining AppKit shims need work. The layout solver still solves a whole
subtree at a time and can pay a cold cubic cost on structural changes; see FINDINGS sections 8
and 11. The later sections of FINDINGS record the implemented host and shim slices.

## Working in the maintained platform tree

Portable `Sources/` and `Tests/` changes are ordinary macOS product changes and must pass their
Mac checks. The Linux host and shim live here; the package's production-source copies are checked
against the repository by `./vendor.sh --verify`.

`./refresh.sh` re-vendors, rebuilds, re-sweeps, and reports per-file changes against
`baseline/sweep.tsv`. It does not change Git history. Run it after product UI changes that could
affect Linux compatibility. `./refresh.sh --accept` updates the baseline for a reviewed change.

### Native Linux window experiment

`./window-smoke.sh` builds `WindowHarness`, opens a real SDL2/X11 window under Xvfb,
loads three projects from a disposable production store, and drives keyboard selection, pointer
selection, resize and dismissal through X events. The captured window is `out/window-native.png`.
With a Linux display and `libsdl2-dev` installed, run:

```sh
swift run WindowHarness /path/to/existing/experimental/store
```

The window is a platform-transport experiment, using the existing specimen views for row chrome
and mounted shim `NSTextField` labels for bounded Unicode navigator text. It is not the shipping sidebar or a selected final Linux
backend. Up/Down move selection, the wheel scrolls the outline viewport, clicking a row selects
it, and Escape closes. The
native title names the selected project's full path. Selection is local to the window; it does
not change the store in this store-only diagnostic mode. Store open/recovery runs on a worker under the same exclusive lock as
`LinuxHost`, then releases the lock and returns an immutable snapshot. No live reload is claimed.

Only visible rows are mounted, and project labels are bounded to 80 Unicode scalars before drawing. The
software-rendering experiment limits windows to 1280×900 pixels. The project-list mode does not provide terminal rendering/input. The separate terminal mode
below adds the initial runtime surface; neither mode provides complete IME or AT-SPI coverage or
extension composition. Navigator title and mounted rows retain Unicode through
Pango shaping; the native window title retains the original path.
Customization classification: this diagnostic harness is host-only and defines no durable product
component or public API. Product navigation must still use the existing semantic component IDs,
with identity, selection, commands, lifecycle truth and input authority retained by Threading.

Launch environment policy is shared with macOS: `AgentEnvironment` strips the launching agent's
run identity while retaining account-directory exceptions and other caller values such as `PATH`
and `HOME`. Host preference/tool-directory discovery lives in `AgentEnvironmentHost.swift` on
macOS; Linux does not read those preferences or forward a Mac environment. The CLI host retains
its caller's terminal colour/pager claims because it does not yet own a graphical emulator.

### Full production PTY client on Linux

The host smoke also builds `PortablePTYClientHarness`, which drives the shared
`ThreadingPTYClient` package against the real Linux daemon: spawn, disconnect, replay/reattach to the same
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

The Mac journal/diagnostic/availability adapter is `PTYHostClientHost.swift`; client limits are portable.
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
and labels cut history. The project browser's saved-terminal picker uses that attachment path
for a live child; explicit activation can start an exited or absent saved shell again.

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
modes for those keys. Complete enhanced printable-key, keypad and Insert support remains
outstanding; this is not full keyboard-protocol parity. SDL editing events now keep IME preedit
off the PTY, and Pango draws a bounded Unicode preview beside the terminal cursor; committed
text enters the same ordered input path as other text. `THREADING_LINUX_IME_ONLY=1
./window-smoke.sh` checks X11/IBus Pinyin composition and the exact `你好` commit in a real child.
Other IMEs and Wayland are unverified. Pango shapes individual cell graphemes; cross-cell joining,
complete accessibility and a theme/profile settings UI remain outstanding.

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
source text before the host can reject an oversized selection. Rich clipboard types remain
unimplemented.

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
WindowHarness --app-claude /path/to/experimental-store /path/to/ptyd.sock /bin/bash /absolute/path/to/claude
WindowHarness --app-agents /path/to/experimental-store /path/to/ptyd.sock /bin/bash /absolute/path/to/codex /absolute/path/to/claude
```

Select a project with Up/Down or a click, then press Enter to open its shell. Click the disclosure
before a project name, or press Space on its selected row, to show saved agents and terminals
under that project. Up/Down selects an inline child and Enter opens that exact saved runtime.
The navigator stays beside the idle pane or terminal in a 320-pixel leading pane. The idle
button opens the selected project's session menu, or the Add Project menu in an empty store.
Ctrl+Shift+P focuses navigation without hiding
the terminal; from the focused project list it opens the folder dialog. Tab returns keyboard
focus to the terminal. Clicking either pane focuses it. Enter revisits
that project's existing terminal, including its child and
emulator state. Right opens the selected project's saved terminals, newest first. Up/Down or a
click selects one and Enter opens it, attaching a live child or starting the same saved terminal
again after confirmed exit/absence; Left or Escape returns to projects. A star marks a
runtime retained by this window. Left from projects opens saved agent sessions, also newest
first; Enter attaches the selected agent through its own persisted identity. Both pickers retain
their selection when returning from a terminal with Ctrl+Shift+P. Alt+F4 closes the window.

Project rows reserve a trailing numeric slot for a nonzero collapsed agent-plus-terminal count;
expansion subtracts the visible children from that count, and zero leaves the slot empty. The
AT-SPI row name keeps both complete totals. The source and
installed smoke suites check this with a real native window; see `FINDINGS.md` §133.

Escape moves out of an account/saved picker, then returns from Projects to the visible terminal;
before any terminal is opened, Escape closes the project window. Escape and Tab remain terminal
input while the shell has focus. The sidebar and terminal retain separate frame textures, so
shell output does not rebuild navigation. Attached grids retain their terminal dimensions when
the window grows to include navigation; the combined window is capped at 1600×900 pixels.
Agent rows use the same title precedence as macOS: a user rename wins, then the agent's title,
then the prompt title, then **New Session**. The preview follows agent titles by default; it has
no title-preference control yet. Saved agent rows show the bundled provider mark when available
and a textual provider fallback otherwise; named accounts keep their separate suffix. The shared
row value
preserves typed session/provider/account identity; Linux retains its bounded native labels and
AT-SPI presentation. The accessibility lane checks persisted Unicode names and fresh admission.
In `--app-codex` mode, Ctrl+Shift+A on a project creates a fresh managed Codex session with the
shared Manual permission and read-only sandbox defaults, opens it in the same terminal window,
and adds its saved identity to the agent picker. The picker reattaches daemon-held children and,
when the daemon no longer holds one, resumes the exact stored provider ID after finding its
rollout under the recorded Codex account. It refuses an unavailable login or a missing or
known-broken rollout before spawning. `env -u CODEX_HOME` prevents an inherited alternate login
from silently taking over a standard-account record. Ctrl+Shift+I opens the account picker in
the project list; it can choose a legacy login such as `codex-work` after finding
`HOME/.codex-work/auth.json`. `THREADING_LINUX_CODEX_ACCOUNT=codex-work` can still select the
initial handle without opening the picker. Selection affects new sessions only.
Ctrl+Shift+L starts a fresh Claude session when a Claude executable is configured. Ctrl+Shift+O
opens its account picker, which offers the standard home and at most 31 verified legacy homes;
`THREADING_LINUX_CLAUDE_ACCOUNT=claude-work` can also set the initial choice. Its caller-minted
UUID and chosen handle are stored before spawn. The standard route clears an inherited
`CLAUDE_CONFIG_DIR`; a named route sets that variable to its exact `HOME/.claude-*` directory.
The saved-agent picker reattaches a live daemon-held child; when the child has exited or is absent,
it resumes the same UUID only when the exact transcript exists in the recorded project's saved
account. A missing login or transcript refuses the resume without creating another chat. Hooks and authenticated-provider
execution are not yet covered by this Linux experiment. The native action uses the same host-owned
session and PTY
paths as Codex; it adds no public extension presentation component.
The initial project-window snapshot reads indexed session counts and at most 512 recent session
payloads per project. A selected agent outside that window adds one indexed read and replaces
one picker entry. Selected-agent attach, rollout-ID persistence, resume, and opening an agent
read only its indexed session and owning project. Saved-terminal identity lookup reads project
rows without decoding unrelated sessions; each project's embedded terminal array is decoded for
the startup snapshot.

With a session accessibility bus, the native window publishes an AT-SPI application, frame and
the currently mounted project/saved-runtime rows. Rows carry their durable IDs and retain Unicode
names in both native drawing and accessibility; selection state and `select`/`open` actions use the same native
navigation route as pointer and keyboard input. The list describes its visible range and never
materializes offscreen accessibility rows. `THREADING_LINUX_A11Y_ONLY=1 ./window-smoke.sh`
checks shared session names and deep selection, the empty list's Add project action and dialog
cancellation, then queries a populated
tree with an AT-SPI client, scrolls a 15-project list, and opens a Unicode-named
project into a real PTY through the row action. The terminal node exposes the current visible
screen through the read-only ATK Text interface. Unicode character and caret offsets come from the
same bounded grid as rendering; concealed cells are blanked, hidden scrollback is omitted, and
text-change events carry only changed spans. SDL window focus now marks the selected mounted row
or the terminal as focusable and focused, and removes that state when the window loses focus.
The frame, list, mounted rows and terminal expose ATK Component bounds in window, screen and
parent coordinates. One row layout supplies drawing, native pointer hit testing and AT-SPI
publication; point lookup follows those drawn bounds, and unmounted nodes report no
geometry. The text projection is capped at 64 KiB, with an explicit overflow message. This is
an initial accessibility path, not screen-reader parity: visible terminal characters now report
the rendered cell rectangle and resolve a point back to a Unicode offset. Wide cells cover two
columns, combining scalars share their cell, and newlines have zero width. The navigator list
exposes AT-SPI single selection: a remote child selection follows the same native route as a
pointer click, while clear and multiselect requests are refused. Terminal text selection,
bounds-change notifications, full focus/event coverage, and native screen-reader inspection
remain open.

The populated accessibility fixture enables `THREADING_LINUX_NAVIGATION_TRACE=1` to distinguish
queued accessibility actions, SDL delivery, selected row indices and drawing phases. Direct
launcher runs may opt into the same flag. Each C scope emits at most 64 records and the navigator
at most 256; traces contain timing and numeric state, without user text. Runner cleanup preserves
`out/accessibility-window.log` and `out/accessibility-empty-project.log` on success or failure.
The tests identify their own application/window process, and wait for GTK dialogs to become
visible before attempting focus.

This host-only diagnostic mode retains at most eight runtimes total across fresh and restored
terminals and agents, and requests frames only for the visible terminal. It saves each new
terminal through the production store before spawning through the production PTY client. The
fixed initial snapshot projects at most 512 agents and 512 terminals per project
into their pickers and constructs only viewport rows. New agents created by this window join
its in-memory catalogue after persistence; creation asks for zero standing session payloads and
checks the new UUID by indexed lookup. Both normal and project-targeted launches attempt
attach-only restoration of the saved agent or standalone-terminal selection in the chosen
project. Opening either persists its selection and clears the other in one transaction on a
worker before entering its terminal. The generic `--app` mode follows the saved runtime's project;
an explicit different project wins. An absent or exited standalone child returns to projects.
`--attach` and `--attach-agent` remain available below.

Run `THREADING_LINUX_AGENT_ONLY=1 ./window-smoke.sh` for focused native agent selection, Codex
account routing, and Claude create/reattach/resume journeys. `THREADING_LINUX_NAMED_ONLY=1
./window-smoke.sh` isolates named Codex and Claude creation and exact resume. The ordinary
`./window-smoke.sh` runs the complete Xvfb suite.

Saved Claude and Codex rows show the production provider artwork beside the session title.
The PNGs are byte-identical to the Mac asset catalogue (`./vendor-marks.sh --verify`), and the
production `TemplateImageDrawing.swift` compiles unchanged against the shim. Selected marks use
selection ink; an unavailable asset falls back to a neutral mark. Provider, account
and stable session identity remain in the accessible label even when a long title is truncated.
The production title occupies one line; provider, short ID and account remain in the accessible
name. A reserved status region
shows durable wake/snooze attention or `Retained` for a cached runtime; it does not claim agent
activity. Visible snooze deadlines refresh even before a terminal is opened. The native wait
keeps accessibility responsive while waiting for the next deadline.
Two bounded PNGs decode once on a worker, and mounted rows reuse their cached images.
`tests/image_shim/run.py` checks the narrow compositing contracts in an isolated Swift build.
The same image fixture now compares real macOS AppKit and the shim for interpolation hints,
source-rectangle cropping, saved graphics quality and `.copy` alpha replacement; its Linux
arm64 runner is `tests/image_shim/run_linux.sh`. Nearest and copy cases match exactly; high
filtering remains visually smooth but is not pixel-identical to AppKit at every scale.
For cross-platform evidence, run `tests/provider_image_lab.py render-macos NEW_MAC_OUTPUT`,
run the `ImageHarness` product on Linux with `Sources/WindowHarness/Resources/ProviderMarks`
and a new output directory, then use `tests/provider_image_lab.py compare MAC_OUTPUT LINUX_OUTPUT
NEW_REPORT`. The report checks invariants and records exact sampling differences. The resource
folder beside `WindowHarness` must travel with the binary. Theme choice, custom account badges
and extension icon overrides are not part of this diagnostic surface yet.

The project catalogue is an initial snapshot plus this window's newly created terminal counts
and agent sessions. Fresh agents publish their committed row and full project count once, so a
folder-import refresh cannot count the same admission twice, including outside the recent
512-row window. A later spawn refusal retains the saved row, and insertion preserves the
currently selected session identity. External store changes are not live-synchronized. Closing the window
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

### Project actions

The header's Actions button and Ctrl+Shift+Space open nine bounded command values through the
production `HostCommandPlane`. The same existing host operations serve keyboard, pointer and
AT-SPI invocation; disabled rows keep their reason and refuse execution. Escape restores the
previous pane and picker. Menu interactions do not become terminal input.

This contextual command surface remains host-owned diagnostic UI, mounting the unchanged
production `ThemedMenuRowView` with the same column and height plan as the Mac presenter.
Threading owns project identity, availability, launch, persistence, account routing, focus and
accessibility. It introduces no Linux extension API and does not yet mount the production
floating menu presenter, command search or shortcut editor. Only visible rows mount,
and refreshing the nine descriptors performs no file or process work. The installed
`tests/actions_smoke.py` exercises the real button, command admission and terminal lifecycle.

Each visible project row also mounts the unchanged production `ThemedIconButton` pair: `+`
opens **New in Project** for that row's exact project, and `⋯` opens its actions. The create
menu offers **New Chat…**, **New Manager…**, and **New Terminal**. New Chat opens a bounded
Codex/Claude choice using the existing session path; Escape returns to the create menu.
New Terminal creates a persistent terminal in the targeted project even when another project
is selected. New Manager remains disabled with an accessible reason until its runtime is
available. The row controls and their AT-SPI IDs are reused only for the mounted viewport.
`tests/project_create_menu_smoke.py` checks pointer and AT-SPI entry, exact project routing,
the nested choice, disabled Manager, and terminal creation.


### Shared surface painting

The native navigator's selected project row plates use the production `SurfaceDrawing`
leaf, copied unchanged by `vendor.sh`. Mac `ThemedSurface` delegates its flat fill/border path to
that same source and keeps its existing `Shape` API. Fitted radii, concentric inset/outset and
welded plate portions therefore have one implementation. Mac theme resolution and hard/soft
bevels remain in the Mac wrapper; the preview still supplies its diagnostic colors and spacing.
The retained header controls, mounted menu rows and project row content are production
components on that fixed palette. The selected plate and other navigator row kinds remain
diagnostic.
