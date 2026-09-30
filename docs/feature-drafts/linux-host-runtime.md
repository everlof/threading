# Native Linux host and UI

> Status: feature draft — gated on making the application/core layers independently compilable,
> proving a structural UI boundary on macOS, and demonstrating acceptable Linux text, input,
> accessibility, and virtual-list behavior in a bounded spike. No Linux backend or toolkit is
> selected.
>
> Measurement snapshot: 2026-08-30, with a measured addendum on 2026-09-18 — see
> [What the spike measured](#what-the-spike-measured). Re-run the repository health and
> source-shape measurements before implementation; the counts below describe that checkout, not a
> permanent baseline.

Related current guidance: [`application-structure.md`](../architecture/application-structure.md),
[`design-system.md`](../architecture/design-system.md),
[`performance.md`](../architecture/performance.md), and
[`CUSTOMIZATION_SURFACE_AUDIT.md`](../extensions/CUSTOMIZATION_SURFACE_AUDIT.md).

## The one-sentence version

Build a real Linux Threading from the same product and semantic UI layers as macOS, while keeping
AppKit and Linux platform services as leaf adapters; do not port controllers to GTK one by one,
wrap the existing remote web client, or reimplement all of AppKit before one product surface can
ship.

## Product contract

The goal is a native Linux host and UI, not a thin client connected to a Mac. It should eventually
launch and resume local agents, own local projects and sessions, render the same core Threading
surfaces, and participate in the same extension and remote protocols.

- macOS remains fully supported throughout the migration. A Linux experiment may depend on the
  product kernel; the kernel never depends on either platform's controllers.
- Project, session, provider, account, permission, archive, activity, and persistence truth remain
  one typed product model. A platform renderer cannot invent a second version of them.
- Visual and behavioral parity is measured surface by surface. “Compiles on Linux” is not a claim
  that text, keyboard input, accessibility, virtualization, or browser/terminal integration works.
- The current browser remote client remains useful but does not count as this feature.

## What the measured tree says

The existing theme boundary already owns most widget styling, but assembly is still AppKit. The
2026-08-30 investigation measured the following concentration:

| Area | Lines | Constraint sites | `NSTextField` sites | View/controller subclasses | Table/outline sites |
| --- | ---: | ---: | ---: | ---: | ---: |
| `UI/Design` | 61,749 | 964 | 160 | 267 | 36 |
| `UI/Views` | 74,423 | 1,438 | 220 | 191 | 111 |
| `UI/Preferences` | 16,215 | 310 | 125 | 68 | 27 |
| `UI/Windows` | 25,822 | 336 | 42 | 23 | 13 |

Across the broader app, 13,131 references covered 240 AppKit/Core Animation/Core Graphics types;
the top 60 types represented roughly 93% of those sites. The callback surface was also
concentrated: about 127 distinct overridden members, led by drawing, layout, intrinsic size,
pointer events, and hit testing.

That makes the work bounded enough to investigate, but it does not make it a mechanical port.
Text fields stand on TextKit and the field editor; table/outline behavior carries virtualization;
accessibility is also the UI-test identity layer; and the browser, terminal renderer, IME, and
three AppKit-oriented visual dependencies each need a real platform story.

## What the spike measured

The later native-window probe (`FINDINGS.md` §40) presents the existing rasterizer through
SDL2/X11 and exercises real window input against a production-store snapshot. It is diagnostic
specimen UI, not a backend selection or the product navigator. Later slices share session creation,
launch command assembly, typed command admission, provider artwork and flat surface painting with
macOS, and exercise them in the installed preview (see `FINDINGS.md` §§99–109). The next UI boundary
is shared navigator presentation and assembly; the diagnostic rows still supply their own spacing,
text composition and colors, and do not consume the production theme or extension environment.

`Spikes/linux-appkit/` is a bounded, wired-to-nothing experiment run on 2026-09-17 and 2026-09-18
against `swift:6.3.2-noble` — the same image and Swift as `scripts/test-ptyd-linux.sh`. It is
evidence for this document, not an implementation of it: no Xcode target references it and no gate
runs it. Its full write-up is `Spikes/linux-appkit/FINDINGS.md`; the numbers below are the parts
that should change how this draft is read.

**The UI side is a conjunction, not a queue.** Type-checking all 153 files of `UI/Design` against a
1,048-line drawing shim left 127 with a gap, and 116 distinct missing `NS`/`CA`/`CG`/`CT` symbols.
Adding Auto Layout — the single largest blocker, wanted by 75 of 153 files — moved **three files**
to compiling. A file compiles when its *last* blocker goes, not its first: 23 files are blocked by
one subsystem, 56 by four or more, and closing whole subsystems best-first needs **nine** of them
finished before 82 of 124 build. The order suggested by a frequency table is not the order the work
should be done in.

**The drawing layer is nearly free; everything expensive is structure, text and accessibility.**
About 1,050 lines bought `NSColor`, `NSBezierPath`, `NSGraphicsContext` with a real state stack and
clip masks, and an `NSView` tree — enough that `PlatinumBitmapFont.swift`, vendored byte-identical,
renders its own glyphs with its own metrics. What remained was `NSAccessibility` in 56 files,
`NSTextField` and text drawing in 52, `NSStackView` in 46, `NSImage` in 36.

**The headless core is two-thirds of the way there already.** Type-checking all 636 files of
`Core`, `Models` and `Application` on Linux against Foundation alone: **66% have nothing
platform-specific in the way** (an import-only scan predicted 69%, so the cheap scan is a usable
proxy between sweeps). Of the 211 blocked, 72 are `AppKit`, and most of the rest have known
equivalents — `Darwin` → Glibc, `os`/`OSLog` → swift-log, `CryptoKit` → swift-crypto with the same
API, FSEvents → inotify. **The genuinely hard tail is about twenty files, twelve of them
`Security`.**

Three things the spike found that reasoning would not have:

- `RelativeDateTimeFormatter`, `ListFormatter`, `ProcessInfo.beginActivity` and
  `volumeAvailableCapacityForImportantUsage` are **Foundation APIs swift-corelibs-foundation does
  not have**. No import scan can find these.
- `URLSession` and friends are not in Foundation on Linux; they live in `FoundationNetworking`, so
  every file using them needs a `#if canImport(FoundationNetworking)` import.
- swift-corelibs-foundation *does* already implement `NSPoint`, `NSSize`, `NSRect`, `NSEdgeInsets`
  and `NSCoder` with the real geometry methods — which are among the most-referenced symbols in
  `UI/Design` and cost a shim nothing but a re-export.

**What this does to the estimate: nothing.** The dated figures — two to three months for a
headless Linux-capable core, roughly 1.5 to 3 person-years for a native UI, about one strong
engineer-year for a narrower AppKit-shaped layer — are if anything better supported now, because
nothing in the spike touched a sparse constraint solver, a text and IME stack, or AT-SPI. What it
does change is **ordering confidence**: slice 2 is roughly thirty files of genuine platform
decisions against the UI's nine-subsystem conjunction, which is why this document puts it first and
says it is worth doing even if Linux stops there.

The twelve `Security` files include a product decision: where an agent account's credentials live
without Keychain. They also contain platform TLS adapters. The linked persistence spike initially reached
`RemoteHostPinning` through account appearance preferences in `ThreadingRemoteKit`; substituting
SHA-256 would not supply `SecTrust` or Apple server-trust challenge handling. Moving those values
into `ThreadingDomain`, with public aliases in the wire kit, removed that dependency from local
preferences. Moving live handoff helpers out of the persisted session file then removed account
discovery and its `os` import from the slice. Separating launch environment composition, title
policy, terminal creation, SSH conversion and read-receipt state then allowed the real project
slice to compile and run. Durable actors/scopes stay beside grants; the shared outbox bound no
longer requires runtime delivery types. Credential custody still needs an explicit product decision.

The production SQLite wrapper passes nine on-disk Linux contracts, including close/reopen,
rollback, schema refusal, pinned-WAL moves and typed full-disk recovery. Run
`Spikes/linux-appkit/coreslice.sh --sqlite`. The full persistence slice now separately passes five
contracts on arm64 Linux: project/session save and reopen, incremental updates, stale graph
writer refusal, participant receipt cascade, and refusal of corrupt session payloads without
row loss. Run `Spikes/linux-appkit/coreslice.sh`; [FINDINGS section 31](../../Spikes/linux-appkit/FINDINGS.md#31-the-real-project-database-runs-on-linux)
records the boundaries. This is evidence for `ProjectDatabase` and the exercised stored records,
not a working Linux `StateManager`, recovery system, agent runtime, or application.
Three additional recovery contracts now pin commit rollback, probe refusal/retry, and the mandatory
model reload after a successful SQLite probe. [FINDINGS section 32](../../Spikes/linux-appkit/FINDINGS.md#32-recovery-primitives-preserve-the-graph-across-refusal-and-retry)
details that narrower recovery evidence; host recovery policy remains outside the slice.
Three migration contracts also verify schema-4 upgrade rollback/retry, retained authority history,
new receipt storage and post-upgrade uniqueness/cascades; [FINDINGS section 33](../../Spikes/linux-appkit/FINDINGS.md#33-historical-authority-migration-survives-refusal-and-retry-on-linux)
records the synthetic fixture's scope. Two more contracts verify downgrade refusal through the project-store constructor for
checkpointed and live-WAL future schemas, including unchanged persisted bytes and continued
newer-writer operation; [FINDINGS section 34](../../Spikes/linux-appkit/FINDINGS.md#34-downgrades-refuse-future-project-schemas-including-live-wal)
records their scope. Two further contracts exercise pinned-WAL refusal and single-file relocation for healthy and
damaged project stores, preserving recent records and corrupt-row evidence; [FINDINGS section 35](../../Spikes/linux-appkit/FINDINGS.md#35-project-stores-move-safely-after-pinned-readers-release-wal)
records the boundary. The project executable now passes fifteen contracts.

The experiment now also has a runnable `LinuxHost` connecting real project-terminal records to
the production PTY daemon. Its real-shell smoke lane verifies input/output, cwd, initial geometry,
exit status, persistence across invocations and ownership/refusal behavior. [FINDINGS section 36](../../Spikes/linux-appkit/FINDINGS.md#36-a-linux-host-connects-durable-project-terminals-to-the-real-pty-daemon)
records the evidence and limits. This is an experimental command-line storage/runtime connection;
it does not satisfy the native host-and-UI product contract above.
The host also reattaches stored terminals after watcher termination, forwards raw keyboard input,
tracks terminal resize and restores caller terminal mode on exit. [FINDINGS section 37](../../Spikes/linux-appkit/FINDINGS.md#37-terminal-watchers-reconnect-forward-raw-keys-and-follow-window-size)
records real PTY and same-child-PID evidence. Native rendering remains unfinished.
The production launch command values now compile independently of host settings, and Linux's
`login-run` uses the same login-shell plan factory and argument quoting as macOS. [FINDINGS
section 38](../../Spikes/linux-appkit/FINDINGS.md#38-linux-and-macos-share-the-login-shell-command-plan)
records real-shell evidence. `CodexLaunchCommand` now also shares resolved provider command
assembly. The Linux `codex` operation persists a real agent session with explicit Manual/read-only
policy and spawns its typed identity; [FINDINGS section 39](../../Spikes/linux-appkit/FINDINGS.md#39-managed-codex-sessions-share-production-command-assembly)
distinguishes argument-recorder evidence from an authenticated provider run. Account resolution,
transcript discovery and native UI remain unfinished.
The later Linux host now also creates a standard-account Claude Code session from the same
portable fresh/resume command pair used by the macOS remote host. It stores the caller-minted
UUID and launches through the real daemon; the recorder verifies flags, account environment and
durable exact-row writes. At that point the native Linux window had no Claude creation/resume
path, and no authenticated provider run was claimed ([FINDINGS section 86](../../Spikes/linux-appkit/FINDINGS.md#86-a-linux-host-can-create-a-real-claude-session-without-a-second-command-policy)).
The native experiment now starts standard-account Claude sessions and resumes exited ones only
after finding their exact transcript through the shared project-slug/path policy. This is a
window and real PTY-daemon journey, not yet a packaged Linux app or an authenticated Claude run
([FINDINGS section 87](../../Spikes/linux-appkit/FINDINGS.md#87-the-native-linux-window-now-owns-a-claude-create-attach-and-resume-journey)).
The later native lifecycle check records observed agent exits in the exact saved row and surveys
the daemon before startup restoration. A normal launch follows the selected agent to its project;
an explicit project target takes precedence
([FINDINGS section 94](../../Spikes/linux-appkit/FINDINGS.md#94-normal-linux-relaunch-follows-the-saved-agent)).
A child that exited while the window was closed no longer opens as a false live attachment;
explicit picker selection resumes it after transcript preflight. This still does not provide a
release-grade Linux package or authenticated-provider evidence.
The observed and offline exit cases are recorded in
[FINDINGS section 90](../../Spikes/linux-appkit/FINDINGS.md#90-native-linux-agent-exits-survive-window-restarts).
The source-tree launcher can also reopen the saved project navigator without a directory after
the first import; the explicit-directory route still targets that project. A static-Swift preview
tarball runs this lifecycle on Ubuntu 24.04 arm64 without the Swift toolchain or source checkout.
The same preview now has an installable `.deb` with a desktop entry. Neither artifact makes a
compatibility claim for other Linux distributions or a release-grade provider-integration claim.
The clean-profile and saved-project reopen checks are recorded in
[FINDINGS section 91](../../Spikes/linux-appkit/FINDINGS.md#91-the-linux-development-app-reopens-from-its-saved-project-list).
The archive-only runtime check is recorded in
[FINDINGS section 95](../../Spikes/linux-appkit/FINDINGS.md#95-the-linux-window-runs-from-an-ubuntu-arm64-preview-tarball).
The package installation, non-root desktop launch and reinstall check are recorded in
[FINDINGS section 96](../../Spikes/linux-appkit/FINDINGS.md#96-the-ubuntu-preview-has-an-installable-desktop-package).

## The boundary to build

“Drop AppKit” is three different propositions:

1. **Widget presentation.** Mostly bounded already by `UI/Design` and the themed component
   vocabulary. Continue closing this boundary.
2. **Structure.** View trees, controller lifecycle, constraints, focus, hit testing, and retained
   invalidation are not abstracted today. This is the portability project.
3. **Platform services.** Windows/events, text shaping and IME, accessibility, pasteboard, browser
   embedding, and native file interaction remain platform adapters. Do not pretend one generic
   implementation replaces them.

Preserve the repository's dependency direction:

```text
ThreadingDomain
    -> ThreadingPersistence
    -> ThreadingRuntime
    -> ThreadingApplication
    -> semantic Threading UI
         -> macOS adapter (AppKit and Apple services)
         -> Linux adapter (selected native services)
```

The structural seam should cover three mechanisms rather than copying an operating-system API:

- **Layout:** preserve a constraint-shaped semantic API where that avoids rewriting thousands of
  stable call sites, but own the solver and its invalidation contract. A Cassowary-family solver is
  a candidate, not a decision. The spike built one end of this and measured the other: expressing
  and *correctly* solving our constraints is a small job, while a dense from-scratch re-solve costs
  47 seconds for 160 sidebar rows, and warm-starting it only helps when the active set does not
  change. Read "own the solver and its invalidation contract" as **sparse, scoped, then
  incremental**, in that order.
- **View tree and lifecycle:** introduce narrowly named `Component`/`Screen`-shaped abstractions
  that wrap AppKit today and a Linux implementation later. Architecture checks ratchet down new
  direct `NSView`/`NSViewController` ownership outside the adapter boundary.
- **Drawing:** keep semantic colors, geometry, and component drawing in `UI/Design`; adapt the
  drawing context at the leaf. Most custom drawing is already concentrated there.

Do not name a compatibility module `AppKit`: the macOS build must be able to compile the portable
surface beside real AppKit, exercise both paths against the same fixtures, and use the real product
as the reference implementation.

That rule stands, but its basis is now narrower than it was when written. The trick was tried —
on Linux there is no system AppKit, so a module of that name is simply ours and every
`import AppKit` in the repository resolves to it with no edit to any file — and it works. The
objection is therefore not that the technique is fragile; it is that naming the seam `AppKit`
forfeits the dual-render laboratory, because the two cannot coexist in one process and the
compiler stops being able to say which call sites are already portable. A plausible resolution is
to give the real seam a name of ours and keep an `AppKit`-named typealias layer as a Linux-only
compatibility shim that only vendored third-party code imports — SwiftTerm being the case that
motivates it.

## Toolkit judgement

No backend is selected. The investigation rejected choosing one before the boundary exists:

| Candidate | Why it is not the starting point |
| --- | --- |
| GNUstep/AppKit clone | Missing the modern controller, Auto Layout, animation, and view-table behavior the app relies on |
| GTK/libadwaita rewrite | Replaces constraint layouts and host-owned row chrome with a second product implementation |
| GPUI | A Rust framework without a stable library/C ABI contract; its flex layout and rebuild model do not match retained AppKit semantics, and it does not solve accessibility or web embedding |
| Full custom renderer | Best long-term control, but makes text, IME, accessibility, virtualization, and compositor maintenance permanent product responsibilities |
| Skia + SDL3 or Cairo + Pango | Plausible leaf technologies for drawing, windows, and text, but only a spike may choose between them |

The decision should follow a dual-render spike that measures the hard parts. A backend that makes a
static component gallery look right but cannot mount a virtual outline, edit multilingual text,
or expose AT-SPI semantics has not passed.

## Customization-surface gate

This project does **not** create a parallel Linux extension UI API. Durable semantic surfaces and
their entity contexts keep the component IDs they already have. An extension targets, for example,
`sidebar.session-row@1` or `application.main-window@1`; the host renders the same validated
contribution through the current platform adapter.

Threading retains all behavior already assigned to the host, including product identity and
ordering, selection, drag and drop, activity and lifecycle truth, input/focus routing, permission
decisions, command availability, destructive confirmations, bounded list behavior, accessibility,
and native fallback. Extensions may customize only the existing properties, slots, replacements,
and protected hooks. They never receive AppKit, GTK, Skia, or backend view objects, and no renderer
may perform extension IPC during layout, hover, or input dispatch.

Native, extension-only, invalid, disabled, reloaded, and conflicting contributions must resolve the
same way on every platform. Any genuinely new product surface still passes the ordinary
customization-surface gate independently; Linux support is not blanket authority to publish it.

## Scaling gate

The structural layer must not turn the current virtual surfaces into eagerly built trees.

- Session, project, file, transcript, process, and extension cardinality stays outside the view
  tree; each renderer mounts a bounded viewport and reuses rows.
- Constraint solving and text preparation are incremental and proportional to the visible subtree,
  not the complete model.
- Hidden/collapsed content is not constructed, laid out, shaped, or made accessible until its
  product contract says it is visible.
- Performance fixtures cover deep seeks, live updates, theme changes, and resize storms at the
  repository's existing stress cardinalities. A Linux-specific lower ceiling must be an explicit
  product refusal, not accidental slowness.

## Delivery slices

1. **Refresh the evidence.** Re-run architecture health, count the direct structural sites with a
   committed script, and establish macOS launch/layout/profile baselines.
2. **Make the product layers compilable.** Continue the current Domain -> Persistence -> Runtime ->
   Application extraction until a meaningful local-session operation builds and tests without a
   UI framework. This is useful even if Linux stops here — and the spike measured the starting
   position at 66% of those files already free of anything platform-specific, with about twenty
   files of real decisions left, so this slice is a sequence of substitutions rather than a
   rewrite. Settle the `Security`/Keychain question before starting.
3. **Add structural ratchets on macOS.** Prevent growth in direct controller subclasses,
   constraints owned outside the structural seam, and backend-specific drawing. Migrate ordinary
   product work through the seam instead of pausing feature delivery for a rewrite.
4. **Build a dual-render laboratory.** Run the same semantic fixtures through real AppKit and the
   candidate portable path on macOS. Prove layout geometry, theme switching, text truncation,
   pointer/focus behavior, and bounded list mounting before starting a Linux shell. Two cautions
   the spike paid for: a layout engine that passes a dozen arithmetic cases can still be *visibly*
   wrong, so keep rendered-state evidence beside the assertions — and a picture can accuse layout
   of a bug the drawing has, which is what a label overrunning a correctly compressed frame turned
   out to be.
5. **Prove the Linux platform leaves.** Window/event loop, text shaping plus IME, AT-SPI,
   clipboard/file interaction, terminal drawing, and an out-of-process or embedded WebKitGTK/CDP
   browser path each need an explicit capability and refusal state.
6. **Ship one honest vertical slice.** A local project/session navigator plus terminal is the first
   useful target. It keeps unsupported surfaces visibly unavailable rather than presenting static
   lookalikes. Expand one complete surface at a time with real-shell evidence.

The first structural ratchet is now in the macOS architecture build phase. On 2026-09-25,
`scripts/check_ui_structure.py --report` counted 83 direct controller subclasses, 119 direct
platform view/window subclasses, 2,818 constraint sites and 96 drawing sites outside `UI/Design`.
The script rejects growth and requires reductions to lower its checked-in ceilings. These are
source-level debt counts, not a portable renderer or completion of the macOS visual baselines,
dual-render fixture, IME or accessibility gates above.

The experimental native terminal now has one measured IME path: SDL editing events render a
bounded Pango preedit without PTY input, and a live X11/IBus Pinyin test commits `你好` exactly
once to a child. A captured frame was inspected with the input method's own candidate panel
disabled so its pixels could not stand in for the terminal preview. This proves neither a general
text-control stack nor other IMEs, Wayland, accessibility, or release readiness.

The Linux AT-SPI probe uses ATK's bridge in the native SDL window. It publishes the mounted
project and saved-runtime rows with Unicode names, selection state and actions that enter the
same navigation route as pointer input. A client can discover only the bounded viewport and open
a real project terminal. The terminal now projects its visible grid through read-only ATK Text,
including Unicode character and caret offsets and changed-span notifications. Concealed cells
are masked and hidden scrollback is omitted. The mounted selected row or terminal follows SDL
window focus into AT-SPI state. Mounted rows and the terminal now have ATK Component bounds and
point lookup tied to the native window. Visible terminal text now has fixed-cell character
rectangles and point-to-offset lookup, including two-column glyphs and combining scalars.
The bounded navigator now shapes mounted Unicode labels through Pango, and its ATK list exposes
single-child selection through the native navigation route. Bounds-change notifications,
comprehensive focus behavior, terminal text selection, screen-reader inspection and other product
surfaces remain unproven.

The Linux launcher can now open a clean profile into an empty native project list.
Its Add project row and Ctrl+Shift+P command open a system GTK folder dialog through Zenity;
the selected directory is imported by the host's canonical, locked store operation on a worker.
The dialog is a Linux platform leaf for a deliberately host-only import action. This proves a
first-launch path in the Xvfb shell. The preview archive and installed `.deb` test that path
without a source checkout; broader Linux desktop compatibility remains unproven.

## Evidence required

- The standard macOS build, architecture/theme/localization checks, and focused behavior tests stay
  green throughout the migration.
- Existing light/dark UI evidence renders in the real macOS shell with no unintended drift.
- Dual-render fixtures compare semantic geometry and inspected pixels; compilation or snapshot
  structure alone is not visual verification.
- Linux evidence includes multilingual editing and IME composition, keyboard and pointer focus,
  screen-reader/AT-SPI inspection, high-cardinality virtual lists, terminal resize/input, browser
  integration, live theme switching, and extension fallback/reload/conflict states.
- Profiling records cold mount, warm update, deep seek, resize, and 100,000-event stress behavior
  with the same bounded-work interpretation as `performance.md`.

## Effort and stop conditions

The dated estimate was two to three months for a headless Linux-capable core, with only a few weeks
of that in platform shims. A native UI after the core extraction was estimated at roughly 1.5 to
3 person-years. A narrower AppKit-shaped compatibility layer might reach a visibly useful build in
about one strong engineer-year, but degraded text or accessibility is not a shippable definition
of done, and maintaining the toolkit becomes permanent product work.

Do not start a Linux rendering backend until Linux is a real product priority and the structural
ratchets move under ordinary macOS development. Stop after the dual-render spike if text/IME,
accessibility, virtual lists, or warm layout cannot meet explicit thresholds without forking the
product. The boundary improvements remain valuable even if the backend is abandoned.

Open decisions before implementation:

- Which Linux distribution, compositor, packaging, and update floor is supported?
- Which text/IME/accessibility stack passes the spike, and who owns its long-term maintenance?
  Still open, and still the largest single risk: the spike deliberately did not touch it, because
  a shimmed `NSTextField` would have moved fifty files while proving nothing about shaping or IME.
- **Where do agent-account credentials live without a Keychain?** Twelve files in the core reach
  `Security`, and this is the only slice-2 blocker that is a promise rather than a port. It gates
  the headless core, so it is due first.
- Is browser automation embedded through WebKitGTK, delegated to CDP Chromium, or unavailable in
  the first slice?
- Which surfaces constitute a useful first release, and which are explicit capability refusals?
- Is the expected Linux audience large enough to fund a permanently maintained platform UI layer?
