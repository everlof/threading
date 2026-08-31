# Native Linux host and UI

> Status: feature draft — gated on making the application/core layers independently compilable,
> proving a structural UI boundary on macOS, and demonstrating acceptable Linux text, input,
> accessibility, and virtual-list behavior in a bounded spike. No Linux backend or toolkit is
> selected.
>
> Measurement snapshot: 2026-08-30. Re-run the repository health and source-shape measurements
> before implementation; the counts below describe that checkout, not a permanent baseline.

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
  a candidate, not a decision.
- **View tree and lifecycle:** introduce narrowly named `Component`/`Screen`-shaped abstractions
  that wrap AppKit today and a Linux implementation later. Architecture checks ratchet down new
  direct `NSView`/`NSViewController` ownership outside the adapter boundary.
- **Drawing:** keep semantic colors, geometry, and component drawing in `UI/Design`; adapt the
  drawing context at the leaf. Most custom drawing is already concentrated there.

Do not name a compatibility module `AppKit`: the macOS build must be able to compile the portable
surface beside real AppKit, exercise both paths against the same fixtures, and use the real product
as the reference implementation.

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
   UI framework. This is useful even if Linux stops here.
3. **Add structural ratchets on macOS.** Prevent growth in direct controller subclasses,
   constraints owned outside the structural seam, and backend-specific drawing. Migrate ordinary
   product work through the seam instead of pausing feature delivery for a rewrite.
4. **Build a dual-render laboratory.** Run the same semantic fixtures through real AppKit and the
   candidate portable path on macOS. Prove layout geometry, theme switching, text truncation,
   pointer/focus behavior, and bounded list mounting before starting a Linux shell.
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
- Is browser automation embedded through WebKitGTK, delegated to CDP Chromium, or unavailable in
  the first slice?
- Which surfaces constitute a useful first release, and which are explicit capability refusals?
- Is the expected Linux audience large enough to fund a permanently maintained platform UI layer?
