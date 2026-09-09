# The native plugin tier

Status: **it runs, and it carries a real feature.** Threading `dlopen`s a code bundle whose
principal class conforms to a protocol vended by `Packages/ThreadingPluginKit`, hosts the `NSView`
it returns in a pane of its own, and hands it the host's whole theme so the pane draws with the
same components the application does. `Packages/ThreadingDesignKit` compiles the application's own
design system a second time for that purpose. `Plugins/DeviceLogsPlugin` is the first tenant: it
shipped 2026-09-02, it is built with the app into `Contents/PlugIns`, and the Device Logs pane it
replaced left the application entirely.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Read this before changing `Packages/ThreadingPluginKit`, `Packages/ThreadingDesignKit`,
`Sources/Threading/UI/Plugins/`, `scripts/build_plugin.sh`, or anything under `Plugins/`. The
delivery plan and the rejected alternatives stay in
[`native-extension-tier.md`](../feature-drafts/native-extension-tier.md); the durable decisions are
here.

## The problem this solves

Two features wanted the same thing and could not have it: a dense, live, structured view inside an
extension. Traffic wants a searchable request table with a body inspector; logs want a filterable
stream at up to ~5,800 rows/sec.

The safe extension vocabulary is `text`, `image`, `button`, `textInput`, `picker`, `scene`,
`media`, `status`, `disclosure`, `proceed`, `overlay`, `customSurface`, `divider`, `spacer`,
`flexibleSpacer`, `stack`. There is no table, list or stream; panels update by whole replacement
over JSONL; `customSurface` is Metal-shader-only; and `ExtensionRemoteSurface` is BGRA pixels
across a boundary the contract says accessibility never crosses. So the answer to "I want a
native-feeling extension surface" was that you could not have one.

This tier is the answer **for code we sign**. It is not a route for arbitrary installed
extensions, and it does not replace the semantic node tier or the planned sandboxed web surface —
those remain the answer for untrusted code and for anything that has to render on the iPhone.

| tier | for | crash isolation | status |
|---|---|---|---|
| semantic nodes on a Wasm core | most extensions | full | shipped, API v1 |
| companion remote surface (BGRA8 frames) | pixels from a companion app | process | shipped, advanced tier |
| web/canvas body | rich, untrusted, cross-platform | full | proposed, `network-inspector-extension.md` Host gap 2 |
| **native plugin** | **first-party, maximum fidelity** | **none** | **shipped** |
| ExtensionKit appex | rich, native, third-party | process | proposed, not started |

## The operating system enforces nothing here

This is the load-bearing fact and everything else in the trust section follows from it.
`Threading.entitlements` carries `com.apple.security.cs.disable-library-validation` in both
configurations — [`permissions.md`](permissions.md) records why, and Sparkle relies on it too — so
`dlopen` will map a bundle signed by any team, or ad-hoc, with no complaint. Measured against a
host built with Threading's exact entitlements and identity:

| host signing | plugin signing | `dlopen` |
|---|---|---|
| Developer ID, `-o runtime`, Threading's entitlements | ad-hoc | **loads** |
| Developer ID, `-o runtime`, Threading's entitlements | different team | **loads** |
| Developer ID, `-o runtime,library` | different team | refused: different Team IDs |

So this is not "less safe than the sandbox". It is *no enforcement at all unless we write it*.
**Every check in `PluginLoader` is ours, and the user's recorded decision is the whole policy.** A
team allowlist stood here first and is gone: it closed the tier to everyone but us, and a platform
only its author can build on is not one.

### Library validation is not what would stop a first-party plugin

Worth separating, because "the OS enforces nothing" reads like a fragility and it is the opposite.

Library validation, when it is enforced, permits code signed by **Apple or by the same team as the
main executable**. `DeviceLogsPlugin` is signed `SMQ3E8Y57T`, which is Threading's own team, so a
bundled first-party plugin loads *even under fully enforced library validation* — the same reason
the embedded Sparkle and WebRTC frameworks load, both re-signed with our team. Enabling SIP on a
user's Mac changes nothing here: SIP has never been what permits this, and the entitlement ships on
the signed binary.

Where the entitlement is genuinely load-bearing is the **third-party** half: a plugin signed by
somebody else's team. That is the tier with no install flow yet, so dropping the entitlement in a
signing tidy-up would foreclose a planned tier rather than break a shipped one — still a conscious
trade, and a smaller one than it first looks.

The measurement that stays unresolved is the *negative control*: the draft's third row asked what
happens with no entitlement at all, and it loaded — on a Mac with SIP disabled, where AMFI is
relaxed. So that row cannot distinguish "the entitlement was unnecessary" from "AMFI was lenient",
which is exactly why it must be re-run on a stock Mac before anyone reasons from it. See
[`permissions.md`](permissions.md).

### Four rules the loader gets wrong if you rewrite it

**Trust cannot be reached by leaving something out.** `PluginLoader` used to take a
`Set<String>` of teams and read the *empty* set as "accept anything, skip the signature". That was
written as a probe convenience and it was also the shipping configuration — `allowedTeams` was
empty until a first-party team existed, and the host's own comment said empty meant load nothing.
Two documents stated opposite policies and the loader won, so any bundle dropped into the plugins
folder would have been mapped into the process unsandboxed.

There is now no `init` at all. A loader is `signatureAndDecision()`, `sealedByHostBundle()` or
`uncheckedForProbesAndTests()`, so omitting something does not compile rather than producing the
dangerous one, and the dangerous one has to be typed out. A tier that runs unsandboxed code in this
process **opens by refusing, not by trusting**.

**`SecCodeCopySigningInformation` needs `kSecCSSigningInformation`.** Called with no flags it
succeeds and simply omits `kSecCodeInfoTeamIdentifier`, so every correctly signed bundle read back
as "team none" and was refused. An allowlist that cannot see a team refuses everything, which looks
exactly like a plugin that will not load — and it hid the empty-allowlist bug above, because the
tests only ever fed the loader unsigned fixtures. **Test a loader with a signed fixture or it is
not tested.**

**Order matters, and it belongs to the loader.** Readable, then validly signed, then approved,
then `principalClass`. Forming a `Bundle` validates the path and metadata without mapping the
executable, so an absent path reports as absent rather than as a corrupt signature; reading
`principalClass` is what maps and runs the bundle's code, so it stays below all three.

The order was `NativePluginCatalog`'s to sequence for a while, which is how the middle two came to
be swapped once already — every absent plugin reported `signature_invalid`. It is now a property of
`load(bundleAt:approving:)`, and the decision is a parameter of that call rather than something a
caller is trusted to have made first. Asking without one refuses; it does not default to yes.

**A bundled plugin is trusted by location.** Code inside the app bundle is sealed by the app's own
signature, so altering it invalidates the app the system already validated. That is a stronger
guarantee than anything a prompt could add, and it is why a first-party pane can ship as a plugin
without the user installing anything.

It is **not a first-party privilege**, and the distinction is the whole product argument for this
tier: anyone shipping an app that loads plugins has the same thing for the plugins inside their own
bundle, and a plugin of *ours* installed the ordinary way is refused until approved exactly as
anyone else's is. `NativePluginParityTests` installs Device Logs signed by our own team and asserts
the refusal, so the claim is tested rather than asserted.

A refusal is a **state, not an absence**. `PluginLoadFailure` names six of them and carries a
stable `code` token with no path or identity in it, because "the plugin did not appear" is not a
diagnosis and this is the one tier where the operating system offers no error of its own.

## The contract is one linked artefact

`ThreadingPluginKit` is a real dynamic framework that **both sides link**. Compiling the same
protocol source into the host and into the plugin does not work: two `@objc protocol` declarations
in two binaries are two protocols, and the loader correctly refuses with "principal class does not
conform" for a class that plainly conforms. `Probes/NativePluginTier` found this from one
direction and the first bundle build found it from the other; see *Install names* below.

Three consequences shape the contract:

- **The payloads are classes.** `NSBundle` can only vend an Objective-C principal class, so the
  entry point is an `@objc` protocol, and an `@objc` signature cannot carry a Swift struct. Making
  `PluginTheme` and `PluginContext` classes is what buys a *typed* contract without giving up the
  runtime matching the loader depends on.
- **The context is narrow and versioned.** A plugin never receives a session, a project, a store or
  a window — `arguments` is a string dictionary. If a plugin needs to know something, that thing
  gets a name in the contract first.
- **The framework builds with library evolution**, so host and plugin can be built at different
  times against different versions of the package without recompiling the plugin.

`ThreadingPluginAPI.version` is compared before `init()`. Bump it whenever a member is added,
removed or re-typed; `PluginLoaderTests` asserts the current value as a deliberate tripwire, so a
version change is something you do on purpose rather than something that happens to you.

## The design system crosses by symlink, and the theme crosses encoded

### Why the directory could not simply be lifted

The obvious plan — make a module out of `UI/Design/` and have the app import it — was measured and
is wrong twice over. 441 declarations live there, 323 used elsewhere in the app, so a module means
annotating those *and* adding an import to roughly four hundred application files. And the
directory is not separable as it stands: it reads `AppThemePalette` 136 times, `L10n` 343 times,
and a set of application models — concentrated in files that are **features filed under `Design/`**
rather than design primitives.

Two measurement traps cost real time and are worth naming:

- A whole-app dependency closure computed by matching capitalised identifiers reported that 91% of
  the application was reachable from `Design/`. **That number is an artifact.** Doc comments name
  application types constantly, and nested type names (`Surface`, `Role`, `Status`, `Text`) collide
  with unrelated declarations. **The compiler is the only instrument that resolves a qualified
  name.**
- Subtractive convergence — build, drop whatever the errors point at, repeat — does not work:
  errors cascade onto the support files a broken file needed, so the loop evicts exactly the wrong
  ones. Adding files to a set that already builds is the shape that converges.

### What was built instead

`Packages/ThreadingDesignKit/Sources/ThreadingDesignKit/Shared` holds **symlinks into
`Sources/Threading`**. There is one copy of every component in the repository and no possibility of
drift; the application is untouched — no import churn, no access-level annotations, no risk to a
working target. The set grows by adding a symlink and rebuilding.

It is a **static** product. A plugin carries its own copy of the design system, the host has one
compiled into the app already, and the two never exchange a component — only an encoded theme — so
there is nothing to share and a self-contained bundle is the simpler artifact.

`Seam/HostSeam.swift` supplies the handful of things the application owns because they read stores
a plugin has no business touching: `AppThemePalette`, the five `DesignSettings` values,
`AppThemeLibrary`, `ThemeAssetStore` and `ThemeManager`. `PaneHeaderDefaults` is *stated* rather
than copied — both members are expressions over types the kit already has, so two numbers cannot
drift apart.

**`-strict-concurrency=complete` is load-bearing, not hygiene.** The application builds these same
files with complete checking, and a component inherits main-actor isolation from its AppKit
superclass only under it. Anything weaker rejects source the app compiles happily.

### The public surface is decided by a compiler, not by taste

`Sources/ThreadingDesignKitExample` is a **separate module in the same package** that writes what a
plugin writes — a header, a control row, a button, a spinner, on the themed ground. A symbol is
`public` because that module could not be written without it. `ExamplePluginPane` therefore stops
compiling the moment any component stops being reachable from outside the kit, and
`PluginViewThemingTests` asserts the part a compile cannot: that the view a plugin built paints the
*host's* ground.

Publishing is mechanical — one keyword per line, verified by stripping `public` back out and
diffing against `HEAD`. Three things the publisher has to know, each of which cost a round:

- **`private(set)` is not private.** The setter is restricted; the getter is still API. A scan for
  the word `private` skips exactly the properties a plugin needs to read.
- **Members of a `private` type must not be published.** Harmless, but it reads as API that is not.
- **A declaration wrapping onto a second line hides its opening brace** from a line-oriented scope
  tracker, so everything inside the type looks like a function body and silently goes unpublished.

Two symbols are deliberately unpublished: `TerminalProfile`'s initializer, whose default argument
names the application's own `PreferenceStore`, and `UsageFormat.forecast`, which takes a forecast
only the application can compute.

### Handing the theme across

The host and a plugin each compile their own `AppTheme` — the same source, two types in two
binaries — so the value cannot be passed. It travels **encoded**, as opaque `Data` on
`PluginTheme.encodedTheme`, and a plugin linking the design system hands it to
`HostThemeHandoff.install(encoded:)`.

**Opaque is the point.** `ThreadingPluginKit` is the narrow contract both sides link and must not
learn what a theme is in order to carry one. The seven tokens beside it — background, surface,
text, secondary text, accent, monospaced font, row height — remain the floor for a plugin that
links nothing, and are enough to draw something that belongs. They are not enough for the real
components, which resolve nineteen roles, a material, radii, bevels and fonts.

**The crossing is exact to 8 bits, not to the bit.** A role travels as a colour hex, so a catalogue
colour of `0.878433` arrives as `0.878431` and the wide-gamut marker does not survive. Every role
resolves to the same colour and no display resolves the difference, but a struct-equality assertion
on `AppTheme` fails on the seventh decimal. `HostThemeHandoffTests` therefore asserts identity and
material exactly and colour to 1/255, which is the precision the format actually promises — the
first version of that test claimed the stronger thing and was wrong.

The host calls `apply(theme:)` once after the pane is built and again on **every live theme
change**, and `AppThemePalette.color(_:)` returns a dynamic `NSColor` that re-resolves through the
theme in force rather than capturing a value, so a plugin's views follow a theme change for the
same reason the application's do.

`isDark` is read from the theme's own ground, not from `NSAppearance`: a Threading theme is not an
aqua/darkAqua pair, and an authored light theme under a dark system appearance exists.

## Building, embedding and installing

The recipe lives in the SDK, at `Packages/ThreadingPluginKit/Tools/build-plugin.sh`: it builds a
package, wraps it as a `.bundle` with an `NSPrincipalClass`, and signs it — ad-hoc by default,
which Threading accepts. `scripts/build_plugin.sh <package-dir> [--install]` is a thin wrapper that
supplies the two things that are ours rather than anyone's, our reverse-DNS identifier and our
Developer ID, and it exists in that shape deliberately: `NativePluginParityTests` then exercises
*the script we hand out*, so a private copy cannot rot while the published one breaks.

Two things the recipe does are not optional:

**Install names have to be reconciled.** SwiftPM links the contract as
`@rpath/libThreadingPluginKit.dylib`; the host embeds it as
`ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit`. dyld would map a *second* copy — and
two `@objc` protocol declarations in two images are two protocols, so the plugin is refused for not
conforming to the protocol it plainly conforms to. The script rewrites the dependency to the name
the host already has loaded.

**The framework has to be embedded in the app.** It was resolving through DerivedData's
`PackageFrameworks` rpath, which works in development and fails in a shipped app. The app has an
Embed Frameworks phase for it.

Two approaches were tried before the bundle target and both look obviously right until they are
not:

- **Linking the package into the app** is wrong: the app compiles the design system and the package
  links its own copy, so `Design` exists twice in one binary and every use is ambiguous — app-wide,
  not only in the files that import it. `@_implementationOnly` silences the compiler and leaves two
  design systems and two `AppThemePalette`s in one process. **`dlopen` is what keeps the copies
  apart**, which is why a first-party plugin has to load like any other.
- **A build-script phase** running `swift build` cannot work: the app target sets
  `ENABLE_USER_SCRIPT_SANDBOXING = YES` and a SwiftPM build writes outside anything a phase can
  declare. Turning the sandbox off for a whole target to gain a build step is a bad trade when a
  native target needs neither.

A first-party plugin is therefore a **native bundle target in `Threading.xcodeproj`**, built with
the app and copied into `Contents/PlugIns`.

## Hosting, and the scaling contract

`NativePluginPaneViewController` owns placement, lifetime, trust and the theme; the plugin owns
everything inside the rectangle it is given. That is the same split `.media` already uses for
content whose pixels move on their own. The tab and approval prompt use the name read from the
*verified bundle*, not from the loaded plugin or mutable install path, so a refusal is still a
named tab and its name cannot drift away from the build being approved.

Installed bundles cross a two-phase loading boundary. Copying, bundle inspection and signature
validation run on a detached worker; only the already verified candidate reaches the main actor to
map its principal class and construct UI. Verification uses a read-only process-private staging
copy, so changing the ordinary install path after approval cannot change the bytes the host maps.
That staging directory is deliberately **not** described as a sandbox: another malicious process
already running as the same Unix user remains outside the native tier's protection. Code needing
that threat boundary belongs in the isolated extension tier.

A mapped installed build is pinned by its full signed identity for the process lifetime. Reopening
it reuses the same verified bundle image; a replacement with the same plugin identifier is offered
after restart rather than mapping a second set of process-global Objective-C classes. Threading
also caps the process to 32 distinct installed native candidates. Their staging resources are
removed on normal process exit; candidates refused before the mapping edge are removed when their
verification object is released. Those recursive removals run through one serial utility queue,
because the last reference is often released by a main-actor pane and bundle size is external.

`NativePluginCatalog.installedBundles` caps both the bundles it returns **and the directory entries
it inspects**. A plugins folder is externally writable, so a limit applied after
`contentsOfDirectory` has materialized everything bounds the result and not the scan — the
distinction the [Scaling Gate](../../CLAUDE.md#scaling-gate) names.

Throughput is settled for this tier. Replaying a real 24,546-row device capture through the pane:

| asked | sustained | dropped | worst tick | CPU | RSS |
|---|---|---|---|---|---|
| 6,000/s | 4,560/s | 0 | 31.5 ms | 53% | 199 MB |
| 12,000/s | 9,120/s | 0 | 31.9 ms | 53% | 202 MB |
| 30,000/s | **22,800/s** | 0 | 31.2 ms | 57% | 207 MB |

`dropped` is 0 at every rate, so the replay thread was the limiter and the pane consumed everything
offered — about four times the ~5,800 rows/sec a real device produces unfiltered. Memory stays flat
because the ring is capped. The 31 ms worst tick is `Array.removeFirst(n)` at that cap rather than a
rate effect: it appears when the ring first fills and does not grow across another 250,000 rows.

**A render found what no assertion would.** The first working pane drew every cell as its own
rounded plate, because a table of themed fields is a table of wells and the row's ground belongs to
the table. The message column was clipped and the filter field had collapsed to its magnifier. All
three were plain in a picture and invisible to every passing assertion — the reason
`NativePluginLoadingTests` renders the loaded pane to a PNG.

## Device Logs is the first tenant

`DeviceLogPaneViewController` and its sources left the application; `Plugins/DeviceLogsPlugin`
holds them, and the host loads it through the same `NativePluginCatalog` path a third-party bundle
takes. The app is ~1,500 lines lighter and the tier carries a feature rather than a probe.

**Nothing about the user's route changed.** Device logs is still an entry in the panel's new-tab
menu, still one pane per session, and `device_log_prepare` still reveals it. `activateDeviceLog`
opens the bundled plugin, and the persisted `.deviceLog` tab kind restores as that plugin so an
older row opens the pane it always did.

Two things stayed in the application deliberately. The **tap consent** is a security grant about
the user's own product, so it belongs to the host and is asked by the agent command rather than by
the pane; `DeviceLogTap` stays with it, because compiling the tap is the agent's build step.

The feature's own decisions — the four sources, what each one redacts, the predicate pushed into
the log daemon, and `DeviceRelayReclaim` — stay in
[`device-and-simulator-logs.md`](../feature-drafts/device-and-simulator-logs.md).

## Publishing the kit: not yet, but ready whenever

`ThreadingPluginKit` is the one package here meant to leave this repository. The decision today is
**not to publish it**, and that is a decision about timing rather than about shape — so the shape
is kept ready, and `PluginKitPublishabilityTests` enforces it rather than trusting anyone to
remember.

Ready means the directory is a thing somebody else could clone: no symlink or path dependency
reaching outside it, no import of a module that would not travel with it, the build recipe inside
it, and a worked example (`Examples/HelloPanePlugin`) that depends on the kit and nothing else. The
split is then a copy, not an untangling.

Three things were fixed *because* they are cheap now and expensive after publication:

- **The public surface stated a policy we had abandoned.** `allowedTeams`, `init(allowedTeams:)`
  and `.untrustedTeam` were still public after the approval model replaced them, and nothing in
  `Sources/` used them. Removing a public symbol after publication is a breaking change; removing
  one now is a rename.
- **The version rule would have broken every third-party plugin on our next feature.** It read
  "bump whenever a member is added, removed or re-typed", and the loader refuses a mismatch, so
  adding one hook would have stopped every installed plugin from loading. It is now *removal or
  re-type only*: `ThreadingNativePlugin` is an `@objc protocol`, so an added `@objc optional` member
  breaks no conformer, and a new field on a payload class is additive under library evolution. That
  is the difference between an SDK and a moving target.
- **The isolation lived in a doc comment.** The protocol deals in `NSView`s and is called on every
  theme change, but was not `@MainActor`, so a conforming class storing a view was a Swift 6 error
  waiting for its author. It carries `@MainActor` now, `load` with it, and the example compiles
  clean under `-strict-concurrency=complete`. The host needed no change, which says the isolation
  was always real and merely unstated.

**`ThreadingDesignKit` cannot follow, and that is recorded rather than hoped away.** It is 80
symlinks into `Sources/Threading` plus dependencies on ThreadingDomain, ThreadingRemoteKit and
SwiftTerm; publishing it means exporting the app's UI layer and dragging two more of our layers
behind it. So Device Logs links something a third party cannot get, and the honest line is
**convenience, not capability**: nothing in the design kit reaches the host, and a plugin without
it is refused nothing, offered nothing less, and called by the agent identically. What it buys is
appearance. The floor for everyone else is `PluginTheme`, kept current across live theme changes.

The cheap way to close even that gap is to let `PluginTheme` decode the full palette out of
`encodedTheme` through this package alone, so a third party draws their own controls in our exact
colours. That is additive under the rule above, and is the next thing worth doing here.

When the time comes: its own public repository, consumed back at `Packages/ThreadingPluginKit` as a
submodule the way ThinkingOrbs, LabelMorph and BorderBeamKit already are, so the path does not move
and `Threading.xcodeproj`'s `XCLocalSwiftPackageReference` needs no edit. Tag the major version to
equal `ThreadingPluginAPI.version` literally, so an author reading a tag knows which host will
accept them. A licence still has to be chosen.

## Tests

| What | Where |
|---|---|
| Every refusal by name; the ordering; that a missing decision refuses; the API version tripwire | `PluginLoaderTests` |
| Bundled-by-location and installed-by-decision, as two halves | `NativePluginCatalogTests` |
| The signed bundle loads, its ground matches the host's, renders to a PNG, and is refused without a decision | `NativePluginLoadingTests` |
| Our own plugin, built and installed the third-party way, offering the same tools — and refused until approved | `NativePluginParityTests` |
| The kit is still a directory somebody else could clone: no escaping symlink or path dependency, recipe and example inside it | `PluginKitPublishabilityTests` |
| A token follows the installed theme; the same `NSColor` re-resolves on a change; text size comes from the host | `HostSeamTests` |
| A plugin-built view paints the host's ground | `PluginViewThemingTests` |
| Identity and material exactly, colour to 1/255 | `HostThemeHandoffTests` |
| The plugin's own decode, render and reclaim contracts | `DeviceLogsPluginTests` |

`NativePluginLoadingTests` skips when no plugin is installed, so a green run on a machine without
one is not mistaken for coverage.

## Still open

- **No install flow for a third-party plugin.** A bundle is placed in `~/Library/Application
  Support/Threading/Plugins` by hand, and the approval prompt is the whole review surface. It says
  which tier the thing is and cannot be suppressed, but it is a dialog rather than a flow: nothing
  yet lists what has been approved or offers to revoke it, though `NativePluginApprovalStore`
  supports both.
- **No crash quarantine yet.** A plugin crash is the app's crash. `pluginIdentifier` exists so the
  policy can name a plugin rather than point at a path, and
  [`crash-recovery.md`](crash-recovery.md) already has the launch ledger and crash-loop machinery
  to hang it on.
- **Gatekeeper still runs at `dlopen`** for a bundle carrying a quarantine attribute, and refuses
  with its own dialog rather than an error we control. An install flow has to own the attribute.
  This — not library validation, and not SIP — is the real requirement a third-party plugin faces:
  it must be Developer ID signed **and notarized**, which also means signed with a secure timestamp.
  `build_plugin.sh` passes `--timestamp=none`, which is correct for a bundled first-party plugin
  sealed by the app's own signature and would have to change for a distributable one.

  **We can check notarization ourselves, and should.** The `notarized` code requirement is
  available and works (verified 2026-09-03 against notarized applications, which satisfy it, and
  against our own locally signed plugin, which does not). `PluginLoader.identity(of:)` today calls
  `SecStaticCodeCheckValidity(staticCode, [], nil)` with no requirement, so it validates the
  signature and nothing about its provenance. Compiling a `SecRequirement` for `notarized` and
  passing it there would let the prompt say *whether Apple has seen this code*, which is a far more
  useful thing to put in front of someone than a team identifier they have no way to evaluate. It
  is the one addition that would make the decision better informed rather than merely recorded.
- **The theme boundary cannot be linted into a plugin.** `check_theme_boundaries.sh` cannot reach
  code that is not in the tree, so the published facade is the enforcement: a plugin gets its
  scaffold, table and controls from the kit and constructs no chrome-drawing AppKit control of its
  own. A missing component is reported as an SDK requirement, the same rule
  `AGENT_AUTHORING.md` already gives for the semantic node vocabulary.
- **The ExtensionKit appex tier** (crash-isolated, third-party, `EXHostViewController`) is proposed
  and not started. It would link the same `ThreadingDesignKit`, which is the majority of the work in
  either plan and is now done.
