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
