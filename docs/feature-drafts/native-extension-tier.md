# Native Extension Tier

> **Plan A shipped 2026-09-02.** The durable decisions are in
> [`docs/architecture/plugins.md`](../architecture/plugins.md) — read that before changing the
> tier. This file remains as the delivery plan and the decision record: the platform facts measured
> 2026-09-01, why Plan B is worth keeping, and the implementation record appended as it was built.
> **Plan B, the crash-isolated ExtensionKit appex, is still proposed and not started**, and the
> third-party install flow is still open.
>
> Read Host gap 2 of [`network-inspector-extension.md`](network-inspector-extension.md) alongside
> this: it proposes a *different* answer to the same problem — sandboxable for untrusted code and
> renderable on the iPhone — and this draft argues they coexist rather than compete. Shipping Plan A
> did not answer it.

## The problem, stated once

Two independent features now want the same thing and cannot have it: a dense, live, structured
view inside an extension. Traffic wants a searchable request table with a body inspector. Logs
want a filterable stream at up to ~5,800 rows/sec.

The complete extension node vocabulary is `text`, `image`, `button`, `textInput`, `picker`,
`scene`, `media`, `status`, `disclosure`, `proceed`, `overlay`, `customSurface`, `divider`,
`spacer`, `flexibleSpacer`, `stack`. There is no table, list or stream. Panels update by whole
replacement over JSONL. `customSurface` is Metal-shader-only. `ExtensionRemoteSurface` is BGRA
pixels, and the contract is explicit that accessibility never crosses it: *"Never pass view,
layer, Metal, IOSurface, accessibility, or system-event objects across this boundary."*

So the current answer to "I want a slick native-feeling extension" is that you cannot have one.

## Measured platform facts

These decide what is available. One of them was measured on a machine whose security posture is
not a user's, and the text says so.

`Sources/Threading/Resources/Threading.entitlements` carries
`com.apple.security.cs.disable-library-validation` in both configurations.
[`permissions.md`](../architecture/permissions.md) records why it is there: extension bundles are
signed by other identities, and [`releasing.md`](../architecture/releasing.md) notes the embedded
Sparkle framework relies on it too. The shipped app:

```
$ codesign -d -vvv /Applications/Threading.app
CodeDirectory ... flags=0x10000(runtime)
Authority=Developer ID Application: MJUKIS AB (SMQ3E8Y57T)
```

`ENABLE_HARDENED_RUNTIME = YES` produces the `runtime` flag; the project never sets
`ENABLE_LIBRARY_VALIDATION` or `OTHER_CODE_SIGN_FLAGS`. Apple documents the hardened runtime as
enabling library validation by default, with this entitlement as the opt-out. Measured by
building a host with Threading's exact entitlements and signing identity:

| host signing | plugin signing | `dlopen` |
|---|---|---|
| Developer ID, `-o runtime`, Threading's entitlements | ad-hoc | **loads** |
| Developer ID, `-o runtime`, Threading's entitlements | different team (Festina Lotus) | **loads** |
| Developer ID, `-o runtime`, no entitlements at all | ad-hoc | loads **on this machine**; see below |
| Developer ID, `-o runtime,library` | different team | **refused**: `mapping process and mapped file (non-platform) have different Team IDs` |

**The third row is not yet a platform fact.** The Mac it was measured on has System Integrity
Protection disabled (`csrutil status`), which relaxes the AMFI posture library validation is
enforced under. That row contradicts Apple's documented default and the reason `permissions.md`
gives for the entitlement, so until it is re-run on a stock Mac or a VM, treat the entitlement as
load-bearing. The first two rows are what a user's Mac runs, because the entitlement ships.

Three consequences, and the third is the important one:

1. **A native in-process tier is available today.** No entitlement change, no signing change:
   the entitlement Threading already ships is exactly the one that permits it.
2. **The entitlement is load-bearing until proven otherwise.** It is not decoration for the Wasm
   runtime. `permissions.md` says it was added for other-identity extension bundles, Sparkle
   relies on it, and removing it in an entitlements tidy-up would plausibly break this tier too.
3. **The OS enforces nothing for this app as shipped.** Threading.app will load a bundle from any
   team, signed by anyone, with no check. So this is not "less safe than the sandbox"; it is *no
   enforcement at all unless we write it*. Trust is entirely our policy, and the policy has to
   exist before the loader does.

## What "use our lib" costs

`Sources/Threading/UI/Design/` is 146 files. Coupling to application internals is far lighter than
its position in the app target suggests:

| | count |
|---|---|
| files importing only AppKit and the vendored packages | 134 |
| files touching any app model type | **12** |
| total references: `SessionID` 13, `AppSettings` 12, `MainWindowController` 2, `AgentKind` 2, `ProjectID` 1 | 30 |

The 12 are `Design.swift`, `PromptView.swift`, `ThemedMenu.swift`, `MorphingTitleLabel.swift`,
`PaneTransition.swift`, `SidebarBackdropView.swift`, `WindowTitleBandView.swift` and five others.
`ThreadingDomain` already exists as a package and already owns `SessionID`/`ProjectID` in
`Identifiers.swift`, so most of the work is injecting an `AppSettings`-shaped protocol instead of
reaching for a singleton.

`ThreadingDesignKit` is therefore a bounded refactor, not a rewrite. Its dependencies include the
three vendored packages (ThinkingOrbs, LabelMorph, BorderBeamKit), which must also build for
distribution.

## What the extension documents already say

This tier is not new to the tree; it is reserved and unfilled. Three statements bound it:

- [`API_V1.md`](../extensions/API_V1.md) lists "in-process native plug-ins" under **Outside v1**,
  beside direct AppKit/SwiftUI and sandboxed web/canvas panel bodies. Nothing here changes the
  safe API; a plugin is a different contract, not a v1 feature.
- [`SANDBOX_RUNNER.md`](../extensions/SANDBOX_RUNNER.md) leaves "whether a trusted native tier
  ever exists" undecided and says what it would be: "a native extension loads into the app and
  has no sandbox at all, which is exactly why it is a separate tier." Plan A is that tier.
- The [extensions README](../extensions/README.md) fixes the ladder: UI returns "through semantic
  nodes or a bounded remote surface rather than an in-process `NSViewController`; a sandboxed
  web/canvas body remains a future middle tier." The remote surface already ships for advanced
  companion extensions, so a tier table that omits it misdescribes today.

The full ladder, with what exists and what this draft adds, is the table under
[Why both](#why-both-and-how-they-differ).

## Plan A: in-process native plugin

A code bundle Threading `dlopen`s, whose principal class conforms to a protocol vended by a
curated `ThreadingPluginKit`.

```
Threading.app
  └─ dlopen(Plugin.bundle) ─▶ principalClass: ThreadingNativePlugin
                                 makePaneView(context:) -> NSView
     links ThreadingPluginKit ──▶ ThreadingDesignKit (themed components, tokens)
```

**Gets:** real AppKit, real `NSTableView` virtualization, real accessibility, text selection,
`⌘F`, drag, live theme following for free because it *is* the theme system. Zero IPC, so a
5,800 rows/sec stream is an ordinary array append rather than a wire protocol.

**Costs, in order of how much they will actually hurt:**

1. **ABI.** Every exposed component becomes a contract. `BUILD_LIBRARY_FOR_DISTRIBUTION` across
   ThreadingDesignKit and three vendored packages, and `Design.swift` stops being ours to refactor
   freely. *Mitigation:* do not expose 146 files. Ship a curated facade of the ~20 components a
   plugin needs (pane scaffold, themed table, themed controls, tokens) and keep the rest internal.
   The facade is the versioned surface; Design behind it stays free.
2. **A crash is the app's crash.** *Mitigation:* `crash-recovery.md` already has a launch ledger
   and crash-loop policy. A plugin that crashes gets quarantined and the app returns without it.
   The loader records which plugin was live at the time.
3. **Trust, which the OS will not help with.** *Mitigation:* the precedent is in
   `simulator-pane.md`, which verifies its helper's "exact location, signing identifier and team"
   before launch. Same policy, allowlisted teams, refuse otherwise.
4. **Gatekeeper still runs at load.** A bundle that arrived with a quarantine attribute is
   assessed when `dlopen` maps it, and an unnotarized one is refused by Gatekeeper's own dialog
   rather than by a loader error we control. *Mitigation:* the install flow states the
   notarization requirement, pins the signature the way companion apps are pinned today, and owns
   the quarantine attribute so the user never meets that dialog from inside Threading.
5. **The theme boundary cannot be linted into a plugin.** A plugin building a stock
   `NSTableView` is exactly what `check_theme_boundaries.sh` refuses in-tree, and the lint cannot
   reach code that is not in the tree. *Mitigation:* the facade is the enforcement. A plugin gets
   its pane scaffold, table and controls from `ThreadingPluginKit` and constructs no
   chrome-drawing AppKit control of its own; the probe's raw table is a probe-only shortcut.

**Honest scope:** this tier is for first-party and explicitly-trusted extensions. It is not a
route for arbitrary installed extensions, and the install review must say so in plain words.

## Plan B: ExtensionKit appex

`EXHostViewController` hosting an `.appex` out of process, macOS 13+, which matches the deployment
target. There is no precedent for Apple's ExtensionKit in the tree: the "ExtensionKit v1" that
[`simulator-pane.md`](../architecture/simulator-pane.md) names in the helper's security boundary
is ThreadingExtensionKit's API v1, a different thing with a confusable name.

**Gets:** real AppKit or SwiftUI views, and unlike a remote pixel surface, accessibility and event
handling genuinely cross the boundary because it is a real remote view hierarchy. Crash isolated.
The extension can link the same `ThreadingDesignKit`.

**Costs:**

1. **Discovery fights the installer.** An appex must live inside an app bundle registered with
   LaunchServices. Threading installs extensions into its own support directory, so either
   extensions start shipping as `.app`s (the companion model already does this) or this tier only
   serves extensions installed as applications.
2. Remote-view papercuts: drag sessions, some responder-chain and menu behaviour, and first
   responder handoff are all fiddlier than in-process.
3. Theme must be marshalled across the boundary and re-applied, rather than simply being read.

## Why both, and how they differ

| | A: in-process | B: ExtensionKit |
|---|---|---|
| fidelity | identical to the app | very high |
| accessibility | native | native |
| crash isolation | **none** | yes |
| throughput | array append | XPC-bounded |
| discovery/install | any bundle, our policy | LaunchServices app bundles |
| ABI exposure | high | high |
| available today | **yes** | yes, with installer work |

They are not rivals. A is the fidelity/latency tier for things we sign; B is the tier that lets a
third party ship something rich without being able to take the app down. The shared investment,
and the reason to plan them together, is **`ThreadingDesignKit` plus the curated facade**: both
plans need exactly that, and it is the majority of the work in either.

The web surface from `network-inspector-extension.md` Host gap 2 stays valuable and is not
replaced by either: it is the only option that is sandboxable for untrusted code *and* renders on
the iPhone.

So the target is the existing ladder with two rungs added, not a new model:

| tier | for | isolation | status |
|---|---|---|---|
| semantic nodes on a Wasm core | most extensions | full | shipped, API v1 |
| companion remote surface (BGRA8 frames) | pixels from a companion app | process | shipped, advanced tier |
| web/canvas body | rich, untrusted, cross-platform | full | the README's "future middle tier"; Host gap 2 |
| ExtensionKit (B) | rich, native, third-party | process | proposed here |
| native plugin (A) | first-party, maximum fidelity | **none** | proposed here; spike exists |

## A working spike exists

[`Probes/NativePluginTier`](../../Probes/NativePluginTier/README.md) implements steps 1 to 4 of the
slice below and runs today. A host `dlopen`s a bundle, instantiates its principal class, and hosts
its native `NSTableView` streaming real simulator logs, re-themed live from host tokens. It is not
wired into `Threading.xcodeproj`.

**The scaling question is now settled for this tier.** The 332 rows/sec first observed was only the
load the simulator happened to offer. Replaying a real 24,546-row device capture at stated rates:

| asked | sustained | dropped | worst tick | CPU | RSS |
|---|---|---|---|---|---|
| 6,000/s | 4,560/s | **0** | 31.5 ms | 53% | 199 MB |
| 12,000/s | 9,120/s | **0** | 31.9 ms | 53% | 202 MB |
| 30,000/s | **22,800/s** | **0** | 31.2 ms | 57% | 207 MB |

`dropped` is 0 at every rate, so the replay thread was the limiter and the pane consumed everything
offered. 22,800 rows/sec is about **four times** the ~5,800 rows/sec a real device produces
unfiltered. Memory stays flat because the ring is capped. The 31 ms worst tick is
`Array.removeFirst(n)` at that cap rather than a rate effect: it appears when the ring first fills
and does not grow across another 250,000 rows.

Two findings from it that change this draft:

- **The shared framework is the mechanism, not a convenience.** Compiling the same protocol source
  into both sides fails: two `@objc protocol` declarations in two binaries are two protocols, and
  the loader correctly refuses with "principal class does not conform". `ThreadingPluginKit` has to
  be one real linked artefact.
- **A themed component's repaint rules are exactly the knowledge a plugin should not have to
  rediscover.** Setting `tableView.backgroundColor` alone leaves the clip view's old ground
  showing. Every plugin author would hit this. It is a concrete argument for the facade carrying
  real components rather than only tokens.

## Extraction is one move, not a queue of requests

The tempting plan is to move whatever the first plugin needs. Device logs needs 8 themed components
and about 8 tokens, which is small and looks like a cheap start. **It is the wrong shape**, and it
fails on the second plugin: whatever somebody asks for next is not in the facade, so their request
blocks on us migrating more code. A tier whose capability is defined by what previous plugins
happened to use is not a platform.

So separate two things that are easy to conflate:

- **What has moved** is the expensive, blocking, one-time decision. Do it once, wholesale.
- **What is public** is a cheap, reviewable, per-symbol decision. Widening it later is an access
  modifier and a review, not a migration.

Move everything; publish deliberately. Then the answer to "my plugin needs `ThemedScrubber`" is a
review, not a project.

### What moves

`UI/Design/` is 148 files. Only **9** touch an application type at all, and most of those are not
design primitives:

| | files | disposition |
|---|---|---|
| import only AppKit and the vendored packages | 139 | **move as-is** |
| gallery stories (`AgentWorkSummary`, `ConversationHandoff`, `ExecutionAuditEvent`) | 3 | stay: fixtures for app types |
| composite feature views (`UsageDashboardView`, `ConversationHandoffView`) | 2 | stay: features that happen to live here |
| name an app type in a doc comment only (`PaneTransition`, `SidebarBackdropView`) | 2 | move; fix the comment |
| `DesignSettings` | 1 | move: it *is* the seam, and naming `AppSettings` is its job |

The composite views are the useful discovery. `UsageDashboardView` and `ConversationHandoffView` are
features filed under `Design/`, and they are the only remaining users of `AgentKind` there. The
extraction is the moment to put them back with the features, which shrinks the framework and removes
the coupling in the same move.

### What is public, initially

Not "what Device logs needs". A principled core that a pane of any kind can be built from:

- **tokens** — `Spacing`, `Text`, `Status`, `Surface`, `Typography`
- **containers** — scroll view, table view, header, virtual cell, row view
- **controls** — button, icon button, popup, text field, checkbox, menu item
- **presentation** — alert, popover, toast
- **text** — labels, the localisation entry point

Everything else moves but stays `internal`. Device logs' 8 components are a *lower bound and a
sanity check* on that list, never its definition.

### When something genuinely is not there

Same rule the semantic node vocabulary already has, in `AGENT_AUTHORING.md`: report the missing
component as an SDK requirement rather than working around it. A plugin that reimplements a themed
control in raw AppKit is the failure this tier exists to prevent — it is how the probe's plugin
ended up rediscovering that `tableView.backgroundColor` alone leaves the clip view's ground showing.

### Order

1. Wire `ThreadingPluginKit` into the app and prove a plugin loads and hosts a view. **In progress.**
2. Move the 2 composite views and 3 gallery stories out of `Design/`.
3. Extract the remaining ~141 files as `ThreadingDesignKit`, everything `internal` by default.
4. Publish the core list above; `ThreadingPluginKit` re-exports it.
5. Move Device logs into a plugin bundle. It is the first consumer, not the specification.

## Smallest shippable slice

Deliberately not the Design extraction, so the mechanism is proven before the refactor is
committed to.

1. `ThreadingPluginKit`: one protocol, a context object carrying a theme token snapshot and a
   change notification, and a version constant. No Design dependency yet.
   **Done** — [`Packages/ThreadingPluginKit`](../../Packages/ThreadingPluginKit), a real local
   package with library evolution enabled, 9 tests, not yet referenced by `Threading.xcodeproj`.
   It also carries `PluginLoader` and its refusal vocabulary, because the refusals *are* the
   security boundary and they are worth testing without an application around them.
2. A loader: enumerate a directory, verify signing team against an allowlist, `dlopen`, instantiate
   the principal class, refuse and record on any failure.
3. One host pane that hosts a plugin's `NSView`.
4. A sample plugin that renders the simulator log stream from
   [`device-and-simulator-logs.md`](device-and-simulator-logs.md) into an `NSTableView`.
5. Only then: extract `ThreadingDesignKit`, and re-point the sample at real themed components.
   **The decoupling half is done.** `UI/Design/DesignSettings.swift` names the five values the
   design system reads from application settings, and all nine call sites now go through it:
   `grep AppSettings Sources/Threading/UI/Design/` returns nothing. `ApplicationDesignSettings`
   forwards to the exact accessors used before, including which store each one reads, so this is a
   decoupling and not a behaviour change. What remains for a real extraction is moving the three
   presentation enums (`AppTextSize`, `PromptReturnKey`, `ChatNameMorphStyle`, 5 to 7 files each)
   out of `Core/Settings/`, and deciding whether the composite views that happen to live in
   `UI/Design/` (`UsageDashboardView`, `ConversationHandoffView`) belong in the framework at all —
   they are the only remaining users of `AgentKind`.

## Non-goals

- Opening this tier to arbitrary installed extensions.
- Replacing the semantic node tier or the planned web surface.
- Letting a plugin reach Threading's model objects. The context is a narrow, versioned value.

## Tests

- Loader refuses: wrong team, unsigned, missing principal class, wrong protocol version, and a
  bundle that throws in its initializer. Each refusal is recorded and named.
- A plugin crash quarantines that plugin and leaves the app launchable, driven through the
  existing crash-loop policy.
- Live theme switch reaches a hosted plugin view.
- A deterministic stress fixture: a captured NDJSON file replayed through the same decode path at
  a chosen rate, 5,800 rows/sec for the stress case. It measures off-main decode, main-thread
  mutation per drain, live view count and footprint, and asserts the bottom stays pinned only
  when it already was, per the [performance workflow](../architecture/performance.md).

## Recommendation

Plan both; build A's mechanism first because it is available with no platform work and it is the
one that proves whether the facade is the right shape. Do not block the log pane on any of this:
build that host-native beside `ExecutionAuditViewController`, and let it become the first consumer
of the plugin tier once the tier exists.

## How the design system reaches a plugin — measured 2026-09-02

The extraction plan recorded here said "lift `UI/Design/` into `ThreadingDesignKit` and have the
app import it". That was measured and is wrong, in two ways worth writing down so the next attempt
does not repeat them.

**Publishing the module is not the cost; the imports are.** 441 declarations live under
`UI/Design/`, 323 of them used elsewhere in the app. Making a module out of the directory means
annotating those *and* adding an import line to roughly four hundred application files, which is a
very large diff for a rearrangement nobody asked for.

**The directory is not separable as it stands.** `UI/Design/` reads `AppThemePalette` 136 times,
`L10n` 343 times, and a set of application models — `ImageAnnotation`, `KeyboardShortcut`,
`SystemAlert`, `ChartSpec`, `ConversationContextAttachment`, `RunProgress`. Those references are
concentrated in files that are **features filed under `Design/`** rather than design primitives:
the composer prompt, the command palette, the media player, the image-annotation rail, the limit
strip, the agent work summary. Two more of that kind — `UsageDashboardView` and
`ConversationHandoffView` — were moved out first for the same reason.

Two measurement traps cost time here and are worth naming. A whole-app dependency closure computed
by matching capitalised identifiers reported that 91% of the application was reachable from
`Design/`; that number is an artifact. Doc comments mention application types constantly, and
nested type names (`Surface`, `Role`, `Status`, `Name`, `Text`) collide with unrelated
declarations elsewhere, so a token scan cannot tell `Design.Surface` from somebody else's
`Surface`. **The compiler is the only instrument that resolves a qualified name.** Subtractive
convergence — build, drop whatever the errors point at, repeat — does not work either: errors
cascade onto the support files a broken file needed, so the loop evicts exactly the wrong ones.
Adding files to a set that already builds is the shape that converges.

### What was built instead

`Packages/ThreadingDesignKit` compiles the application's own source files a second time. Its
`Sources/ThreadingDesignKit/Shared` directory holds **symlinks** into `Sources/Threading`, so there
is one copy of every component in the repository and no possibility of drift. The application is
untouched: no import churn, no access-level annotations, no risk to a working target.

A plugin gets the real `Design` tokens plus `ThemedButton`, `ThemedControl`, `ThemedIndicators`,
`ControlRow`, `PaneHeader`, `PaneFooter`, `FontRole`, `MorphingTitleLabel`, the optical-alignment
and pointer-claim machinery, and the whole theme model including every stock style — 27 design
files and 42 supporting ones. The set grows by adding a symlink and rebuilding; nothing has to be
designed in advance for a request nobody has made yet, which was the point.

Five things the application owns are supplied by `Seam/HostSeam.swift` instead, because they read
stores a plugin has no business touching: `AppThemePalette` (the host installs its theme and the
plugin's tokens resolve through it), the five `DesignSettings` values, `AppThemeLibrary`,
`ThemeAssetStore` and `ThemeManager`. `PaneHeaderDefaults` is stated rather than copied — both its
members are expressions over types the kit already has. `HostSeamTests` proves the part that could
silently be wrong: a token follows the installed theme, the same `NSColor` re-resolves when the
theme changes rather than capturing a value, and text size comes from the host.

One setting is load-bearing and non-obvious: the package builds with
`-strict-concurrency=complete` because the application does. A component inherits main-actor
isolation from its AppKit superclass only under complete checking, and without it the shared
sources fail on default arguments the application compiles happily.

### The public surface

The kit's symbols were `internal` at first, which compiles and tests but does not let a plugin in
another package link them. They are now `public`, decided by the compiler rather than by taste:
`Sources/ThreadingDesignKitExample` is a **separate module** in the same package that writes what a
plugin writes — a header, a control row, a button, a spinner, on the themed ground — and a symbol
was exported because that module could not be written without it.

Publishing is mechanical and the diff is exactly one keyword per line: 71 files, verified by
stripping `public` back out and diffing against `HEAD`, which reproduces the original byte for byte
in 70 of them. The 71st is `TerminalProfile`, whose initializer is deliberately *not* published
because its default argument names the application's own `PreferenceStore`. `UsageFormat.forecast`
is unpublished for the same kind of reason: it takes a forecast only the application can compute.

Three of the application's own enums — `AppTextSize`, `PromptReturnKey`, `ChatNameMorphStyle` —
became public too, because a published component's signature names them and the seam supplies the
same three to a plugin.

`public` on an application target is otherwise a no-op, which is what makes this safe: the app
builds unchanged, and nothing about its own layering moved. Two things are worth knowing before
running the publisher again. Members of a `private` type must not be published — harmless, but it
reads as API that isn't. And a type whose declaration wraps onto a second line (`public final class
ThemedButton: ThemedControl,` … `{`) hides its opening brace from a line-oriented scope tracker, so
everything inside it looks like a function body and silently goes unpublished; that one cost a full
round of override errors.

### What a plugin gets today

80 shared files. Beyond the tokens and the theme model: `ThemedButton`, `ThemedControl`,
`ThemedIconButton`, `ThemedPopUp`, `ThemedTextField`/`ThemedSearchField`/`ThemedSecureField`,
`ThemedTextView`, `ThemedMenu`, `ThemedPopover`, `ThemedTableView` with its virtual cell and
grouped variant, `ThemedScrollView` with its themed scroller and clip view, `ThemedIndicators`,
`ChipView`, `GlyphView`, `ControlRowView`, `PaneHeaderView`, `PaneFooter`, `FontRole`,
`MorphingTitleLabel`, and the optical-alignment, pointer-claim and symbol-metric machinery.

`ExamplePluginPane` assembles the shape a log pane needs out of those — header, source chooser,
filter field, follow button, spinner, and a virtualised table on the themed ground — from a
separate module, so it stops compiling the moment any of them stops being reachable from outside
the kit. `PluginViewThemingTests` then asserts the part a compile cannot: that the view a plugin
built paints the *host's* ground.

### Handing the theme across

The host and a plugin each compile their own `AppTheme` — same source, two types in two binaries —
so the value cannot simply be passed. It travels **encoded**: `PluginTheme.encodedTheme` carries
the host's whole theme as opaque `Data`, and a plugin linking the design system hands it to
`HostThemeHandoff.install(encoded:)`. `ThreadingPluginKit` stays free of any dependency on the
design system, which is the reason the field is opaque rather than typed. The seven tokens beside
it remain the floor for a plugin that links nothing.

That took the contract to version 2, which the loader enforces — an installed plugin must be
rebuilt. The version test is a deliberate tripwire and was updated deliberately.

**The crossing is exact to 8 bits, not to the bit.** A role travels as a colour hex, so a
catalogue colour of `0.878433` arrives as `0.878431`, and the wide-gamut marker on the original is
not carried. No display resolves that difference and every role resolves to the same colour, but a
struct-equality assertion on `AppTheme` fails on the seventh decimal — so `HostThemeHandoffTests`
asserts identity and material exactly, and colour to `1/255`, which is the precision the format
actually promises.

### It runs

`Plugins/DeviceLogsPlugin` is a real bundle: built by `scripts/build_plugin.sh`, signed with
Threading's Developer ID, installed to `~/Library/Application Support/Threading/Plugins`, and
opened from the panel's new-tab menu like any other pane. It streams `log stream --style=ndjson`
from this Mac or a booted simulator, decodes off the main thread, hands rows to a virtualised
`ThemedTableView` on a timer, and drops the oldest when the stream outruns the table — saying how
many rather than hiding it. Measured on first run: 6,854 rows in four seconds, no drops.

Everything visible in it is a real Threading component compiled into the bundle, resolving the
host's theme through `HostThemeHandoff`. `NativePluginLoadingTests` loads that signed bundle,
asserts the pane's ground matches the host's, renders it to a PNG, and checks the same bundle is
refused when no team is trusted. It skips when no plugin is installed, so a green run on a machine
without one is not mistaken for coverage.

Three things this cost that are worth knowing:

**Install names have to match.** SwiftPM links the contract as `@rpath/libThreadingPluginKit.dylib`;
the host embeds it as `ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit`. dyld would have
mapped a *second* copy, and two `@objc` protocol declarations in two images are two protocols — the
plugin would have been refused for not conforming to the protocol it plainly conforms to, which is
the same trap the probe hit from the other direction. `build_plugin.sh` rewrites the dependency to
the name the host already has loaded.

**The framework has to be embedded.** It was resolving only through the DerivedData
`PackageFrameworks` rpath, so it worked in development and would have failed in a shipped app. The
app now has an Embed Frameworks phase.

**A render found what no assertion would.** The first working pane drew every cell as its own
rounded plate, because a table of `ThemedTextField`s is a table of wells; the row's ground belongs
to the table. The message column was also clipped and the filter field had collapsed to its
magnifier. All three were obvious in a picture and invisible to every assertion that passed.

### Device Logs is the tier's first real tenant

`DeviceLogPaneViewController` and its four sources left the application. `Plugins/DeviceLogsPlugin`
is a native bundle target in `Threading.xcodeproj`, built with the app and copied into
`Contents/PlugIns`, and the host loads it through the same `NativePluginCatalog` path a third-party
bundle takes. The app is 1,400 lines lighter and the tier carries a feature rather than a probe.

A **bundled** plugin is trusted by location rather than by allowlist: code inside the app bundle is
sealed by the app's signature, so altering it invalidates the app the OS already validated. The
team allowlist still governs everything installed outside the app, and a test asserts both halves.

Two approaches were tried and rejected before the bundle target, and both are worth recording.

*Linking the package into the app* looked simplest and is wrong: the app compiles the design system
and the package links its own copy, so `Design` exists twice in one binary and every use is
ambiguous — app-wide, not only in the files that import it. `@_implementationOnly` silences the
compiler but leaves two design systems and two `AppThemePalette`s in one process. `dlopen` is what
keeps the two copies apart, so a first-party plugin has to load like any other.

*A build-script phase* that ran `swift build` cannot work either: the app target sets
`ENABLE_USER_SCRIPT_SANDBOXING = YES`, and a SwiftPM build writes outside anything a phase can
declare. Turning the sandbox off for the whole target to gain a build step is a bad trade when a
native target needs neither.

### A plugin can offer the agent tools

Contract version 3 adds two optional members: `pluginTools`, read once when the plugin loads, and
`invokeTool(named:argumentsJSON:completion:)`. Both are optional because a plugin that only draws is
a complete plugin. Schemas and arguments travel as JSON *text* for the same reason the theme payload
is a class — the entry point is an `@objc` protocol, and the Objective-C runtime the loader depends
on cannot carry a Swift enum tree. The host parses at its own edge, so `ThreadingPluginKit` still
depends on neither side's model.

Nothing in the MCP core changed to allow this, which is what the seam promised.
`NativePluginMCPToolProvider` is a second `MCPExternalToolProvider` beside the extension tier's, so
plugin tools reach the catalogue, the wire format, the Settings tool groups and the dispatcher by
the same path the built-in tools use. The registry now holds a *list* of providers rather than one;
`invokeTool`'s existing "false when this provider does not own the name" was already the mechanism
for asking each in turn.

Names are namespaced by the plugin's identity — `plugin__devicelogs__search` — so two plugins
offering `search` are two tools, and a name in a transcript says which one ran.

Two things are deliberate in the failure paths. A tool call for a plugin whose pane is **closed**
answers with a reason rather than reporting no such tool: the tool exists, it has nothing to act on,
and the agent can ask for the pane to be opened. And the reply hops to the main actor rather than
assuming it — a tool answers when its own work does, a store query completes on the queue that owns
the store, and `assumeIsolated` off the main thread is a trap rather than a check.

Device Logs offers five: `search` over everything recorded, `focus` to fold the rest away,
`clear_focus`, `time_range`, and `visible` for what is on screen now. `focus` moves the pane's own
controls rather than holding a second invisible state, because the person watching has to be able to
see what the agent did to their view and undo it.

### Still open

The third-party path still has no install flow, and opening the allowlist to other teams needs a
review surface and a crash-quarantine policy. A plugin's tools are also read once at load: a plugin
whose tool list changed while running would be a tool that sometimes exists, so that is stated
rather than supported.

## Reopen / revisit triggers

- Apple ships a supported in-app plugin view story that beats `EXHostViewController`.
- The web surface lands first and turns out to be good enough for logs, which would demote A to a
  first-party-only convenience.
- Any decision to turn library validation on, or to drop the `disable-library-validation`
  entitlement. This originally read "would break A entirely", which is too strong and is corrected
  in [`plugins.md`](../architecture/plugins.md): library validation permits same-team code, and the
  first-party plugin is signed with Threading's own team, so it would survive. What it forecloses is
  the third-party half. Still a conscious trade rather than a signing tidy-up.
- A re-measurement of the third row above on a SIP-enabled Mac. Either answer belongs in
  `permissions.md`, because it decides whether that entitlement is documentation or a dependency.
