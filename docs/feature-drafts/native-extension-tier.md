# Native Extension Tier

> **Draft.** Platform facts measured 2026-09-01. Nothing implemented. This is the tier that
> [`device-and-simulator-logs.md`](device-and-simulator-logs.md) and
> [`network-inspector-extension.md`](network-inspector-extension.md) are both gated on. Read Host
> gap 2 of the traffic inspector draft first: it proposes a *different* answer to the same
> problem, and this draft argues they should coexist rather than compete.

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

## Reopen / revisit triggers

- Apple ships a supported in-app plugin view story that beats `EXHostViewController`.
- The web surface lands first and turns out to be good enough for logs, which would demote A to a
  first-party-only convenience.
- Any decision to turn library validation on, or to drop the `disable-library-validation`
  entitlement, which would break A entirely and needs to be a conscious trade rather than a
  signing tidy-up.
- A re-measurement of the third row above on a SIP-enabled Mac. Either answer belongs in
  `permissions.md`, because it decides whether that entitlement is documentation or a dependency.
