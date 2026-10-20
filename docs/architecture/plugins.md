# The native plugin tier

Status: **it runs, and it carries real features.** Threading `dlopen`s a code bundle whose
principal class conforms to a protocol vended by `Packages/ThreadingPluginKit`. A plugin may fill
a pane, the leading workspace navigator, or both. The host owns placement and hands over its live
theme; the plugin owns the native view inside that rectangle. `Plugins/DeviceLogsPlugin` is the
first pane tenant. `Plugins/T3NavigatorPlugin` is the first navigator-only tenant and proves that a
bundle can supply a complete, design-system-native thread hierarchy without changing the default
navigator. Its installed bundle does not add a generic pane command: T3 has no pane factory, so
that command would only open a refusal view. The managed-offer catalogue records whether a
first-party bundle should have such a command; third-party pane bundles retain the normal one.

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

This tier is the answer for **explicitly trusted native code**: Threading's signed plugins and
external plugins whose exact build the user approves. It does not replace the semantic node tier
or the planned sandboxed web surface — those remain the answer for untrusted code and for anything
that has to render on the iPhone. First-party publication and automatic trust are distribution
policies, not extra presentation or command capabilities.

| tier | for | crash isolation | status |
|---|---|---|---|
| semantic nodes on a Wasm core | most extensions | full | shipped, API v1 |
| companion remote surface (BGRA8 frames) | pixels from a companion app | process | shipped, advanced tier |
| web/canvas body | rich, untrusted, cross-platform | full | proposed, `network-inspector-extension.md` Host gap 2 |
| **native plugin** | **approved native code, maximum fidelity** | **none** | **shipped; external installation is manual** |
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

`ThreadingPluginAPI.version` is compared before `init()`. Bump it when a member is removed or
re-typed; additive protocol members are `@objc optional`, and additive payload fields remain
binary-compatible under library evolution. `PluginLoaderTests` asserts the current value as a
deliberate tripwire, so a version change is something you do on purpose rather than something that
happens to you.

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

It is a **dynamic** product embedded once in `Contents/Frameworks`, and only plugins link it.
The host still compiles these sources into its executable and must never link the framework: doing
so makes `Design` ambiguous throughout the application module. Both bundled plugins resolve the
same framework image, rather than carrying a copy of its dependency closure apiece. The host and
the framework still exchange only an encoded theme. The package also vends a static
`ThreadingDesignKitStandalone` product for separately installed plugins: their Swift ABI stays
with their build instead of depending on a private host framework that changes each release.

The package products below DesignKit are explicitly static. With an automatic library product,
Xcode made a separate `*_PackageProduct.framework` for each dependency of the dynamic kit and
copied those frameworks into both plugin bundles and the app. The first build grew each plugin
from roughly 11 MB to about 50 MB before export. Linking the local dependencies statically into
DesignKit keeps that closure in the one shared image. The kit also drops its unused `Syntax.swift`
type aliases, so it does not pull the remote `NativeDiffCore` product into the runtime. The app
keeps its own syntax model unchanged.

Xcode's static-library diamond check sees the app and DesignKit linking those same local
products. That duplication is intentional across these **two images**: the app cannot import the
kit, and the kit cannot use the app's Swift types. It already existed once per plugin before this
change. `DISABLE_DIAMOND_PROBLEM_DIAGNOSTIC` is set at the project level because the hosted test
target and helpers also link these static products into separate binaries. The hosted linkage
test checks the important boundary separately: the app executable never links DesignKit, while
both plugin executables link its one embedded framework.

### First-party archives for an exact host build

`scripts/release.sh` saves every exported, Developer ID signed native bundle before sealing the
app without them. `scripts/package_native_plugins.py` packages those saved bundles as
separate zip assets. A notarized release submits each zip to Apple, staples the resulting bundle,
then zips it again so the download carries its ticket. The script signs a compact manifest with
Threading's Sparkle Ed25519 key. The signature covers the exact payload bytes, including the app
version and channel, SHA-256 hashes of the host executable, DesignKit and PluginKit, and each
plugin archive's URL, byte length, SHA-256 and code-directory hash. The release publisher uploads
the plugin zips before the manifest. A development-signed or unnotarized bundle cannot pass the
managed-install code requirement.

`NativePluginManagedInstaller` downloads with a byte ceiling, checks the signed manifest against
the running host, validates the archive hash, extracts into a private candidate, requires our
Developer ID team **and notarization** through `SecStaticCodeCheckValidity`, with strict recursive
validation of nested code. Only then does it remove quarantine. Activation renames one top-level
symlink to a versioned candidate, leaving the old
target available if any prior step fails. Concurrent requests for the same archive share one
download and activation. The ordinary plugin inventory sees that symlink;
`PluginLoader` copies its resolved destination into its read-only staging area, validates that
copy, and never maps the mutable install path. A local receipt is not an approval: every managed
load rechecks the signed manifest, host build, notarized code and staged code-directory hash.
Only that managed first-party path skips the manual approval prompt. An old managed build reports
`build_changed` instead of falling back to a prompt. Previously installed identifiers are bounded
and retained for a background re-fetch after the host build changes; offline failure leaves the
refresh pending for the next launch.

The release app embeds no first-party native plugin. The current four are offered through the
virtualized Extensions Settings page. Device Logs' existing host commands create a pane at its
stable installed URL.
Devices carries the separately signed Simulator helper. Its host route verifies the managed
receipt and nested code before launching the helper from the resolved version path; the app's
direct helper copy is removed. A missing Devices bundle leaves the public screenshot fallback.
Proxy carries the separately signed portable `threading-proxyd` helper and certificate setup
script. The host verifies its managed receipt and both signatures before a capture launch, pins
the resolved version path, and reports the install action when the bundle is absent. Capture
leases, client approval and certificate authority custody remain host-owned.
Any first-party pane in `NativePluginManagedOffer` uses that same missing-bundle view to explain
its size and install it on request; a stale managed version offers the same repair path. The
catalogue supplies the exact reserved path, display name and size hint to Settings and the pane.
The Settings row reports whether code is included in
a development build, installed for this app version, needs an update, or has a conflicting manual
copy, and gives an approximate download size while offline. The first-party identifiers and
install filenames are reserved: a manually approved bundle cannot claim the Device Logs host tool
path or masquerade as a managed first-party release. The release flow was exercised against a
local Developer ID export, including independent Apple notarization of Device Logs and T3. The
Devices pilot repeated the local export with all three bundles, notarized and stapled each, and
checked the signed manifest and nested Simulator helper against the exact release-shaped host
after removing its native plugins. These were local probes; a clean-tree published release remains
to be exercised.

The launch ledger brackets each first-party native plugin constructor with start/finish checkpoints naming
the bundle identifier and exact code build. On the next launch, an unclean exit with an unmatched
start pauses only that build before its principal class can be mapped. The Extensions row explains
the pause and offers an explicit Retry; a successful retry writes a finish, clearing the pause in
later launches. The plugin's own code has no way to skip this host gate.

`Seam/HostSeam.swift` supplies the handful of things the application owns because they read stores
a plugin has no business touching: `AppThemePalette`, the six `DesignSettings` values,
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

**Opaque is the point for material, not for colour.** `ThreadingPluginKit` is the narrow contract
both sides link and must not learn how the design system implements a theme in order to carry one.
The seven original tokens — background, surface, text, secondary text, accent, monospaced font,
row height — remain the compatibility floor. `PluginTheme.semanticColors` is the complete set of
named colours resolved by the host for the appearance currently drawing; a custom component asks
for a `PluginThemeColorRole` and never invents a literal or reaches for an unrelated AppKit system
colour. The opaque `encodedTheme` remains necessary for the real components, which also resolve
material, radii, bevels, control anatomy and fonts.

That produces three deliberate lanes rather than one ambiguous freedom:

- safe Wasm extensions declare meaning and the host renders it, so the active design system is
  automatic;
- a native extension seeking first-party fidelity links `ThreadingDesignKit`, installs
  `encodedTheme`, and composes the published pane, field, table, row-selection, button, menu and
  popover components;
- a native extension with its own component geometry still reads every colour through
  `PluginTheme.color(_:)`. Custom means custom composition, not a parallel palette.

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
the host already has loaded. The standalone plugin manifests link
`ThreadingDesignKitStandalone` statically; only bundled Xcode targets use the dynamic product.

**The frameworks have to be embedded in the app.** The contract once resolved through
DerivedData's `PackageFrameworks` rpath, which worked in development and failed in a shipped app.
The app's Embed Frameworks phase copies and signs both `ThreadingPluginKit` and
`ThreadingDesignKit`; only the contract appears in the app executable's link dependencies.

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

### Native pane sections and commands

A native bundle can declare `ThreadingPaneSections` in `Contents/Info.plist`. This static
declaration is read on a bounded worker after signature validation, without mapping the plugin's
executable. `ThreadingPluginKit.PluginBundleMetadata` publishes the keys. Version 1 has this form:

```xml
<key>ThreadingPaneSections</key>
<dict>
  <key>schemaVersion</key><integer>1</integer>
  <key>sections</key>
  <array>
    <dict>
      <key>id</key><string>overview</string>
      <key>title</key><string>Overview</string>
      <key>command</key>
      <dict>
        <key>title</key><string>Open overview</string>
        <key>symbol</key><string>rectangle.grid.1x2</string>
        <key>detail</key><string>Optional palette detail</string>
      </dict>
    </dict>
  </array>
</dict>
```

The first section is the primary pane returned by `makePaneView(context:)`; additional sections
come from `makePaneSectionView(identifier:)`. `command` is optional. A declared command appears
in the panel menu and command palette and opens that section for the current session. The host
owns its shortcut, route, tab lifetime and placement. Up to eight sections are accepted; an
unknown version, duplicate ID, invalid field or oversized plist rejects the whole declaration.
Manually installed bundles need a valid signature and the user's approval of that exact build
before code is loaded; managed first-party downloads instead prove the signed release manifest.
`Tools/build-plugin.sh --metadata PaneMetadata.plist` merges this declaration into the bundle
before signing; `Examples/HelloPanePlugin/PaneMetadata.plist` is an independent author example.

Device Logs declares these sections in its own `Info.plist` and uses the same discovery and pane
registry when installed. The host retains its two existing command aliases before the managed
bundle has been downloaded. The managed catalogue also retains contextual `from-device` routing;
that route and the managed iPhone executable broker are separate public API work.

### Native workspace navigators

A navigator is declared in static `ThreadingWorkspaceNavigators` bundle metadata. Discovery reads
that bounded plist without touching `principalClass`; only selection crosses the ordinary
signature, approval and mapping boundary. The declaration names a plugin-local navigator ID, its
menu title and an optional preferred width. The persisted route is the pair of the verified bundle
identifier and navigator ID, so a mutable path or display label is never identity.

After loading, the plugin receives `PluginWorkspaceNavigatorContext`: an initial bounded snapshot,
one-row content updates, structural replacements, typed project/session/terminal identities, and
host-validated activation, pin, unpin and archive intents. It receives no `ProjectStore`, window,
paths or model objects. The default `WorkspaceNavigatorSelection.native` remains the default; a
plugin navigator is an explicit View → Navigator choice and falls back to Native if its build is
removed, replaced or refused.

API v5 adds one expensive-fact interest loop. A plugin reports at most 128 realized session
identities; the host discards unknown/non-session values, deduplicates the set, and loads the shared
provider-neutral change-request summary only for that viewport. Success is cached for 60 seconds,
failure for 15, in-flight checkout reads deduplicate, and the whole app admits four provider
pipelines. A row can ask for `openChangeRequest`, but the host opens only its current cached and
validated URL. Credentials, provider payloads, checkout paths, diagnostics, and mutations never
cross the plugin contract. See
[`SOURCE_CONTROL_PROVIDERS.md`](../extensions/SOURCE_CONTROL_PROVIDERS.md).

`T3NavigatorPlugin` is the reference for the component lane. It links `ThreadingDesignKit`,
installs the exact encoded host theme on every delivery, and builds its custom T3 information
architecture from `PaneHeaderView`, `ControlRowView`, `ThemedSearchField`, `ThemedTableView`,
`ThemedTableRowView`, `ThemedIconButton`, `ThemedMenuPresenter` and `ThemedPopover`. Its own row
composition uses only `Design` typography, spacing, symbol and semantic colour roles. The model
retains row objects across title and activity deltas; an ordinary content edge reloads only the
named virtual table row, while search and structural edges rebuild the lightweight index. A
2,000-thread fixture asserts fewer than 100 live cells.

The proof offers title search, a virtualized project filter, stable Pinned/Active/Archived
sections, and T3-shaped three-band rows: project with the live status or the thread's age at its
far edge, the title, then the branch plus a compact provider-neutral change-request receipt.
Colour is spent only where it changes what the reader does next. A working, ready, input,
attention or limit state is a coloured word (working carries the spinner, ready a check mark);
a quiet thread shows how long since it was active ("now", "5m", "2h", "3d") in tabular digits on
the tertiary ramp, re-read once a minute for the rows on screen; a dormant thread's title recedes
to the secondary ramp the way T3 dims a read card. The words "Idle" and "Dormant" were tried
first and read as dead weight on every row. The branch carries no decorative glyph; the
change-request receipt follows T3's meaningful mark-and-number shape instead: a pull-request
glyph plus its number in monospaced digits, coloured by the most urgent lifecycle/check/review
condition. Spelling out "Draft" beside "Checks running" was tried and crowded the branch at that
width. The complete normalized reading stays in the receipt's tooltip and the row accessibility
value. A selected row's accent fill overrides every status hue with the selection's label ink.
The plugin asks for a 320-point pane so the title-led cards keep T3's compact silhouette without
weakening Threading's standard controls. Hover and keyboard focus replace the status slot with
host-owned actions instead of permanently crowding selected rows. The proof does not invent T3's
snooze or new-thread behavior: those intents are not in the native contract yet.

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

Device logs remains an entry in the panel's new-tab menu and `device_log_prepare` still reveals it.
The live Simulator and physical-iPhone toolbars also carry a logs button: it moves that session's
one plugin tab into the bottom drawer, keeps the device visible in the right panel, and targets the
same UDID. The drawer still reads legacy `.deviceLog` rows, but any verified native plugin pane now
persists an identifier and bundle name through `.nativePlugin` in panel, dock and drawer. The host
rebuilds only a reserved first-party address or a top-level installed address, then requires the
verified bundle identifier to match before mapping code. The stored route grants no trust; a
removed plugin shows its ordinary refusal state. Format version 8 keeps an older app from reading
this new tab kind and silently saving a partial layout. Device Logs keeps writing `.deviceLog`
while older layouts and the dedicated logs commands exist.
On transfer, the destination host takes over the plugin pane's title and section-reveal callbacks.
The drawer can create a Bluetooth sibling for Device Logs without moving its shared owner out of
another host, and a tool reveal opens the drawer through the same host route as a browser. Other
plugins declare section identifiers in signed metadata; a saved route waits for that declaration
and only restores a section that still exists. Contextual pane routes declare a section and panel
or drawer placement in that same offer. The device button names Device Logs' `from-device` route
and passes the selected `deviceID`; the window resolves the route, reuses a tab in its current dock or drawer,
or moves a new panel tab into the drawer. The route does not grant execution authority.

Revealing a singleton for a new subject must not rebuild its view or start a second reader.
`ThreadingNativePlugin.activatePane(context:)` is therefore optional and additive: the host sends
the latest narrow activation arguments to an existing instance, while an older plugin simply keeps
the pane it already made. Device Logs consumes `deviceID` and switches through its ordinary machine
selection path, so reader teardown, row clearing and recents retain one owner.

Two things stayed in the application deliberately. The **tap consent** is a security grant about
the user's own product, so it belongs to the host and is asked by the agent command rather than by
the pane; `DeviceLogTap` stays with it, because compiling the tap is the agent's build step.

The feature's own decisions — the four sources, what each one redacts, the predicate pushed into
the log daemon, the modern paired-phone native-RSD reader with its legacy relay fallback, and
`DeviceRelayReclaim` — stay in
[`device-and-simulator-logs.md`](../feature-drafts/device-and-simulator-logs.md).

Only the verified first-party Device Logs tenant receives the preferred path to Threading's
managed `pymobiledevice3` environment in its placement arguments, whether bundled in a development
build or installed from the signed release manifest. The host owns that installation and selects
the capability; arbitrary installed plugins do not receive it. The pane resolves and
version-checks the path during every source rescan, so an explicit Advanced Settings installation
can become active without reloading the plugin or restarting the app.

### Bluetooth packet source

The singleton Device Logs workspace contains **Regular Logs** and **Bluetooth** tabs.
`DeviceLogWorkspaceViewController` owns one lazily constructed controller per stream, shares
discovery, and owns capture lifetime independently of the selected child view. The first tab
offers system/app sources; the second offers only paired-phone Bluetooth sources. Opening the
Bluetooth tab starts its reader without stopping the regular reader. Switching tabs hides only
presentation: the inactive controller records rows in its capped ring and distinct SQLite history,
without projecting filters, changing menus or reloading its table. Returning projects a bounded
snapshot off-main, preserving that tab's filter and following state. Closing/hiding the workspace
stops both readers and retires pending discovery. The tab controls use the shared
`ThemedSegmentedControl`, now exported through ThreadingDesignKit without separate drawing code.
Theme delivery repaints the workspace through the plugin's own `AppThemeRefresh`: marking only
the root dirty leaves layer fills frozen in the previous theme, because the host's refresh
cannot read the plugin module's recorded surfaces. Product-shell evidence checks the tab track
against the current theme as well as rendering it in dark, Cyberpunk and Swiss appearances.
History and source recents are separated by stream; legacy history remains with Regular Logs.
Agent tools read the selected tab, and `bluetooth` selects the Bluetooth tab for its exact UDID.

Streaming presentation updates the table's row count and existing viewport cells in place.
`ThemedTableTextCell` retains its selectable label with frame layout: the previous `reloadData`
plus fresh labels and constraints on every 100 ms batch spent most of its time in AppKit cell
destruction and layout. Ring trimming shifts selected lines and a paused viewport; programmatic
updates cannot turn following off. Context scans and user filter changes publish immutable
snapshots from a cancellable worker. Entries keep addressing that snapshot while capture advances,
then selection and the viewport are restored by absolute line position. Completed snapshots are
published before catching up, so sustained traffic cannot starve the view by invalidating every
result. The synchronous agent focus receipt remains a one-time scan; streaming never repeats it
on the main actor. See the matched rendered workload in `performance.md`.

USB reader start/stop never synchronously waits for transport work. Each serial lifecycle queue
checks a cancellation generation before launching and before delivering callbacks, including a
fallback delayed by orphan reclaim. Reclaim uses numeric kernel identity discovery and a bounded
argv lookup for exact executable candidates; a global process-argument scan previously held
teardown for minutes. See `DeviceRelayReclaimTests` and `StructuredDeviceLogSourceTests` for the
exact-device rule and cancellation while cleanup is blocked.

Paired phones offer **Bluetooth (USB/Wi-Fi)** in that tab. This reads HCI traffic through the external
`idevicebtlogger` executable from libimobiledevice. Apple documents the connected-phone capture
route and the Bluetooth logging profile in [WWDC19 session 901](https://developer.apple.com/videos/play/wwdc2019/901/).
The [service implementation](https://github.com/libimobiledevice/libimobiledevice/blob/master/src/bt_packet_logger.c)
connects to `com.apple.bluetooth.BTPacketLogger` through the paired-device service transport.
PacketLogger itself links Apple's private MobileDevice framework and its own PacketDecoder;
neither framework nor PacketLogger's code is copied into Threading.

`BluetoothLogRowSource` launches `idevicebtlogger -u <hardware-UDID> -x -f pcap [-n] -` on its
own serial worker. The PCAP path flushes every packet; the tool's PKLG output can buffer quiet
traffic. It is discovered beside the existing Homebrew relay executable and is not bundled or
linked. The source remains discoverable without the tool and explains `brew install
libimobiledevice` when selected. The phone owner installs Apple's current Bluetooth logging
profile from [Profiles and Logs](https://developer.apple.com/bug-reporting/profiles-and-logs/?name=bluetooth).
The **Set Up…** disclosure offers the primary **Send certificate to this iPhone** action: choose
a downloaded Bluetooth logging profile and send it directly to the selected hardware UDID through
the ordinary interactive installation service. **Install from Apple…** opens the exact Apple
profile download endpoint in a dedicated `WKWebView`, presented through `ThemedPopover` independently
of the log pane's height. Its preferred 640×740 content is capped to the current screen with room
for themed chrome; WebKit fills the remaining height between the origin/Cancel bar and the
sign-in-storage footer, and the page retains native scrolling. The old 360-point inline view
could clip the bottom of Apple's form in a short log pane.
Apple's authentication redirect returns to the download automatically. Navigation/download
redirects admit HTTPS Apple domains only, with the current origin shown above the page. This
view has no agent bridge, injected scripts, credential export, diagnostics or network capture.
Apple-requested child windows use WebKit's supplied configuration and stay inside the same
dialog, preserving `window.opener`, POST bodies and the shared isolated website store. Never
replay a new-window request in its opener: that destroys the page waiting for the authentication
callback and can leave the user signing in repeatedly. The newest child fills the browser area;
closing it restores its opener. There are at most two child windows, even if a page requests more,
and Cancel, Forget Sign-In and completion retire all of them. A loopback WebKit test exercises a
POST into a child, its cookie, the opener callback and the resulting authenticated download;
another stresses ten popup requests against the two-window limit. Neither test uses Apple accounts.
On macOS 14+, a stable, named `WKWebsiteDataStore` retains Apple's cookies and website data across
reopening and app restarts, separately from the shared Browser and every project website store.
On macOS 13, one shared nonpersistent store retains sign-in only until Threading quits. WebKit
owns the data; Threading does not serialize or export cookies. **Forget Sign-In** clears that
store through WebKit and reloads Apple's sign-in flow. Apple still decides session expiry and
reauthentication. Tests inject temporary stores and never clear or read the production store.
`WKDownload` takes the authenticated response directly into a private temporary directory;
there is no cookie transfer into URLSession, Save panel or Downloads-folder watcher. Only a
successful response for `iOSBluetoothLogging.mobileconfig` is admitted. Closing/hiding setup,
switching phones and Cancel retire its generation, cancel WebKit, then remove partial files.
WebKit reports `WebKitErrorDomain` 102 when navigation becomes a download. Ignore that specific
navigation interruption only after choosing download policy or attaching the download; its own
delegate now owns success/failure. A policy interruption without that handoff remains a failure.
HTTP refusals, unexpected files, transfer limits, network failures and web-process termination
settle explicitly. User-facing details contain only known error categories/status codes, never
authentication URLs, NSError user info or server-supplied descriptions.

`BluetoothProfileInstaller` reads at most 1 MiB from a regular file on a worker, decodes CMS or
plain plist metadata, checks `com.apple.bluetooth.logging` and an absolute removal date, and
stages those exact bytes privately. These checks identify the profile type, not signing trust;
iOS owns the signature and consent presentation. The explicit install action pins the selected
hardware UDID and invokes `pymobiledevice3 --no-color profile install --udid … -- …`, using the
host-managed path or fixed local tool paths. Never use silent installation, supervise a phone,
bundle Apple's profile, or expose this mutation to agent tools. Once sending starts it finishes
for that exact phone even if the pane is hidden. An acknowledgement is reported as **sent**, not
installed; the owner finishes in Settings and restarts the phone per Apple's instructions.
Tool absence, rejection and an unconfirmed transfer have distinct guidance. Capture is
phone-wide HCI traffic, not an app-PID stream or a promiscuous radio sniffer.
`--no-color` is a root CLI option, not an option of `profile install`. Placing it after the
subcommand fails before any phone connection; a fake installer that merely records arguments
cannot verify that grammar. `THREADING_BLUETOOTH_PROFILE_TOOL_FIXTURE` opts the real installed
parser into the regression suite with `--help`, which exits before discovery or installation.

The worker reads microsecond PCAP link type 201, validating lengths, direction, byte order and
EOF. It emits value rows for HCI commands/events, ACL/L2CAP, complete ATT messages and SCO.
Packet data is hex with a 256-byte preview ceiling and an explicit omitted-byte count.
L2CAP frames are reassembled per ACL connection (one pending frame each, 16 connections, LRU);
a continuation with no pending start stays labelled. No full GATT database reconstruction,
Apple vendor-log decoding or raw archive export is claimed.

**The PCAP header's snapshot length is not a record bound.** `idevicebtlogger` hard-codes 2,048
("larger than any ACL") and then writes every packet whole; LE Data Length Extension ACLs exceed
it, and enforcing it stopped real captures with "invalid packet length or timestamp". Records are
bounded by the 65,535-byte packet limit instead. The test fixture header now declares the tool's
real 2,048, which is why the earlier 65,535 fixture never caught it.

**App packet definitions.** `BluetoothATTSession` carries the cross-packet state an app value
needs: L2CAP reassembly per connection and direction, then per connection *and GATT database*
(odd ATT opcodes are about the sender's, even ones the receiver's) the handle→UUID map learned from
Read By Type (0x2803) responses, the outstanding read, a long read joined from Read Blob responses,
and queued Prepare Writes. Keying by connection alone shipped first and labelled a watch's FOTA
writes as the iPhone's ANCS characteristic, which had the same handle; a replay of that capture
(`BluetoothCaptureReplayTests`, opt-in) went from 0 to 2,801 decoded FOTA writes.

`msgpack` values are parsed into a bounded `MessagePackValue` tree, then rendered or matched by
`MessagePackPattern` (`BluetoothMessagePack.swift`). `learn:` blocks make `BluetoothATTSession`
fill `BluetoothLearnedEnums` from received values before decoding them, per device identity
(address, else name, else the most recent teacher). The capture worker loads that store from
Application Support at start, saves it at most once per definition check and on stop, and reports
its summary and every enum name through `BluetoothDefinitionReport`; the pane colours those names
with `NameColor` (FNV-1a hue, theme keyword lightness/chroma in OKLCH, `legible(on:)` the ground,
resolved at draw time). Two panes capturing at once each save their own view; the last save wins.

**Across packets** (`BluetoothFlows.swift`, draft
[`bluetooth-protocol-understanding.md`](../feature-drafts/bluetooth-protocol-understanding.md)).
A decode now leaves named values behind (`Decoded.values`: field ids, paths, `bits:` parts, pattern
captures, at most 128), the first MessagePack value it parsed, and a level. `BluetoothFlowState`,
per connection, feeds them to `transactions:` (request/response pairing by key, window, pending
pattern and timeout; an ATT Error Response fails the waiting request) and `streams:` (lines from a
byte stream; transfers with progress and incremental CRC-32/CRC-16). Flow rows are queued on the
session and collected by the decoder after each packet, at the packet's time; an unanswered
request is reported by the first packet after its deadline, on any connection. The same values,
keyed `Characteristic.field`, are the context a `switch-on` on another characteristic reads.
Replaying the 13 Oct capture against a YAML with these sections paired 45 FOTA responses and 13
command reads and reported the one read that never got an answer (`map_buildinfo`) — the lead an
earlier session found by reading rows by hand. Two lessons from that replay are in the code: a
response must carry the transaction's key to pair (an `ancs_filter` re-read after a write had
paired with the unanswered read), and a request answered by silence on success (a FOTA data chunk)
must be left out of the request endpoint, which is why `where:` takes lists and `"!VALUE"`.

`include:` compiles `BluetoothProfiles` (SIG GATT, ANCS, Nordic Secure and legacy DFU) before the
project's file and merges with the project winning. Learned enums are kept per firmware build
(version 2 of the store; version 1 reads as the device's current build). `session.event` returns
an `EventSummary` for link-health events (subsystem `Link`) and decoded advertising. `logs:` rules
are `NSRegularExpression`s compiled with the file; app rows carry `DeviceLogRow.link` (characteristic,
operation, key values), and `DeviceLogWorkspaceViewController` links a selection in one tab to the
nearest matching row of the other through `BluetoothLogLinker`, a binary search to the time window
and a scan bounded by it.

**Identities and procedures** (`BluetoothProcedures.swift`). A connection has a *family* (the
device it belongs to) and an optional *role*. An `identities:` rule arms a watch when its `after:`
fires; the next LE Connection Complete whose address fits (`+1` on the lowest byte without carry,
as fw-pascal's `gap_address_change` and Nordic's SDK do) and whose advertising agrees joins that
family, so `Kronaby (bootloader)` and the reconnect after the update are one device. Procedures
are a per-family state machine fed by `Signal`s from the session: app values, link events
(connected, disconnected, encryption failed, Service Changed, firmware changed) and notes
(everything else worth a timeline). Attempts live in `BluetoothProcedureHistory`, saved by the
capture worker beside the other stores and read off the main actor by the Timelines panel and the
`timelines` tool. Time-based endings (idle, settle) are decided by the next packet's time, which a
quiet link can delay, so an abandoned try ends at its last activity rather than at the deadline.
Replaying the 13 Oct capture through app-mono's FOTA procedure gave one try with every page, the
watch's page bitmap after each, and the image's real pace (about 23 s per 4 KiB page), abandoned
where the capture stopped. Stream `verify:` compares the device's reported offset and CRC with the
bytes seen; `info:` with an offset resumes from the device's own account, continuing the CRC-32
register from its value (`~crc`).

**Remembered GATT tables.** Discovery (Read By Group Type, Read By Type 0x2803 with properties,
Find Information) is written through to `BluetoothGATTTables`, keyed by device identity, or under
`phone:<udid>` for the iPhone's own database. Lookup order is live discovery, then the connection's
remembered table, then a YAML pin — the reverse of the first version, where a pin beat discovery and
went stale silently. A connection without an identity narrows candidate tables packet by packet by
handle presence and property fit, and is rejected outright when none fits: in the 13 Oct capture
that is what keeps a second watch's indications on 0x002e from being read as the paired watch's
read/write Anima Command. Replayed with every pin removed and a restart at 15:08, the post-restart
traffic decoded 2,498 FOTA RX writes, 39 FOTA TX notifications and 63 Anima rows. Long reads are now
joined without definitions too, because a 26-byte Firmware Revision recorded as its first 22 bytes
made the next full read look like a firmware change. When the session's checkout has `.threading/bluetooth.yaml`, matching ATT
values are interpreted by `BluetoothPacketDefinitions` — a Kaitai-flavoured, bounded interpreter
over our own YAML subset (`YAMLSubset`, no dependency) — and the row's subsystem becomes `App`. The
plugin learns the checkout from the existing `checkoutPath` placement argument; no contract
change. The capture worker stats the file once a second and recompiles on change, so a save takes
effect on the next packet; compile errors carry a line and appear in the footer, the "?" panel and
the agent `visible` answer. A value whose bytes do not fit is logged at Warning and carries ` ⚠ `
(`BluetoothATTSession.problemMarker`), which is what the filter bar's "Fully decoded only" excludes
(`LogFocus.excluding`). It excluded by severity first; once definitions could give rows their own
levels (`22: { name: BATTERY_OK, level: info }`, `level: error` on a match rule), a well-formed
error packet would have been hidden as "not fully decoded". Decoded rows name the
peer from HCI events and GATT as well — Device Name read, else advertised local name tied by the
connection-complete address, else the definitions' service name — with advertised names capped at
256 addresses and dropped per handle on disconnection. The message column is coloured by `LogMessageHighlighter`, a pure UTF-16 tokenizer run per
viewport cell (at most 2,048 units examined, ~0.3 ms per long row in Debug); the definitions'
`highlight:` words arrive with the status callback. Bounds per value and per file, and the
authoring format, are in [`bluetooth-packet-definitions.md`](../bluetooth-packet-definitions.md);
the in-app guide and the example share `BluetoothDefinitionsGuide`, whose example is compiled by a
test.

The tool's PCAP conversion omits non-HCI PacketLogger record types. UTC timestamps
come from the phone's capture. These are packet payloads and can contain private application data;
they follow Device Logs' existing local history retention, not unified-log privacy redaction.

The existing native-plugin presentation is deliberately host-owned: phone identity, process
lifetime, bounds and history custody stay with the plugin/host. Themes style the existing source
menu and virtual table; this adds no safe-extension slot or new data grant. The source hides and
clears the app-process selector and hides the redundant Process column. Compact protocol metadata
leaves room for packet summaries; horizontal scrolling and cell tooltips expose longer previews.
The first 700-point product-shell render left only about 140 points for the message. The Bluetooth
column mode leaves about 400; the shell test now requires more than 350 points of visible message
width and was inspected under System Dark, Swiss Minimalist and Cyberpunk.
`plugin__devicelogs__bluetooth` requires a visible pane and an exact discovered
hardware UDID and selects the same tab/source; `visible` includes reader status, and existing search,
focus and time-range tools read the captured rows. A start receipt never claims receipt of a
packet. Silence keeps waiting with profile/activity guidance. Service-start errors are surfaced
even when the CLI remains alive waiting for another device event. Rescan can restart a failed
reader, and stale discovery completions cannot start a reader after the pane was hidden.

No reader outlives Threading. macOS has no parent-death signal and `idevicebtlogger` ignores
`SIGPIPE`, so a logger started by a Threading that quit for an update kept the phone's Bluetooth
relay, and the new Threading's captures received nothing. Long-lived readers therefore run under
`TetheredReader`: a `/bin/sh` tether whose stdin is a pipe only Threading holds the
(close-on-exec) write end of. Its watcher blocks reading that pipe and ends the reader on
end-of-file — Threading quitting, crashing or being killed, or a stop closing the end, which also
covers a tether that had to be `SIGKILL`ed. The Bluetooth capture additionally runs
`DeviceRelayReclaim` before it starts, as the system log already did, to clear orphans left by
builds without the tether.

A running Bluetooth reader outlives hiding; the system log does not. A capture is something the
user started on purpose, and the moment it exists for — a firmware update, a pairing — tends to
happen while they look at another session; the first real DFU test lost its pairing to exactly
that. Hiding therefore only stops drawing (`stopCaptureUnlessRecording`): the reader keeps
decoding, recording and following procedures at its existing bounds, and closing the tab or session
releases the source, whose `deinit` stops it. A system log is a firehose nobody asked to keep, so
it still stops.

Scaling: expected 100–6,000 packets/s, stress 100,000 generated packets; 32 KiB reads, at most
128 KiB per pipe per 50 ms worker tick, one incomplete packet of at most 65,535 bytes, 4 KiB
diagnostics, and 256 payload bytes per row. The existing 20,000-row handoff, 50,000-row viewport
ring and 500,000-row local history apply. Process startup, parsing, reads and teardown stay off
the main actor. Stop is asynchronous, and a child that ignores termination is killed after one
second. No new view is created for a packet; the table continues to reuse its viewport cells.

Profile setup creates WebKit only after a deliberate click, with one download per visible setup.
Declared oversized downloads are rejected; progress above 1 MiB cancels the download, with a
60-second transfer deadline. The file is checked again before bounded decoding (WebKit may
buffer beyond a progress notification). Installation admits one process across all plugin panes,
refuses concurrent work without queuing, drains at most 8 KiB of diagnostics, and times out after
90 seconds. File/CMS/process work and temporary-directory cleanup stay off the main actor.
Temporary files are removed after normal success/failure/cancellation; a process crash can leave
a private OS-temporary directory for normal system cleanup.

`BluetoothProfileTests` covers download policy, profile identity/expiry/size, optional local signed
Apple input, exact-device staging and cleanup, CLI errors/deadlines, isolated WebKit and cancel
settlement. `BluetoothProfileDownloadTests` uses a loopback HTTP server and real `WKDownload` to
cover the successful navigation handoff, HTTP refusal and unexpected filename; random named stores
verify cookie reuse and forgetting without using an Apple account. Product-shell evidence includes
expanded setup and the real sign-in presentation in three themes, with a tall synthetic form whose
bottom action must be visible. Apple sign-in and actual on-phone installation remain a separate
interactive hardware check; fixtures never contain Apple profile bytes or account details.

`BluetoothPacketTests` covers split frames, endianness, ATT boundaries, malformed lengths, EOF,
preview limits, silent-child teardown and a service failure without process exit. The shipping
bundle is rendered in the real window shell by the `device-log-filters` evidence entry, using a
synthetic capture through the production decoder. Hardware verification is separate:

```bash
THREADING_BLUETOOTH_LIVE_UDID=<hardware-UDID> swift test --package-path Plugins/DeviceLogsPlugin --filter BluetoothPacketTests/testLivePhoneProducesPackets
THREADING_BLUETOOTH_STRESS=1 swift test --package-path Plugins/DeviceLogsPlugin --filter BluetoothPacketTests/testBurstKeepsOnlyAnIncompletePacketBetweenReads
```

On 2026-10-12 the attached iPhone accepted the service connection but returned no packets in a
10-second CLI probe. That verifies connectivity only; successful live packet reception still
requires a prepared phone and Bluetooth activity. Do not replace that limitation with the
synthetic render or codec test result.

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

**`ThreadingDesignKit` cannot follow yet, and that is recorded rather than hoped away.** It is 80
symlinks into `Sources/Threading` plus dependencies on ThreadingDomain, ThreadingRemoteKit and
SwiftTerm; publishing it means exporting the app's UI layer and dragging two more of our layers
behind it. So the first-party Device Logs and T3 plugins link something an external author cannot
consume from a released package yet. The distinction is now explicit rather than visual debt:
first-party native plugins use the actual components; external custom components receive all 30
resolved semantic colours through publishable `ThreadingPluginKit`. The latter is palette parity,
not component parity — it does not promise Threading's control anatomy, type recipes or interaction
surfaces.

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
| Native T3 DesignKit composition, filtering, viewport-only cells, stable row identity and host-owned actions | `T3NavigatorPluginTests` |
| Every custom-component semantic colour crosses from the active host theme | `NativePluginCatalogTests`, `PluginContractTests` |
| The shipped native navigator metadata and principal-class conformance | `NativeWorkspaceNavigatorDiscoveryTests` |

`NativePluginLoadingTests` skips when no plugin is installed, so a green run on a machine without
one is not mistaken for coverage.

## Still open

- **Contextual native pane routes are still host declarations.** Versioned bundle metadata now
  exposes pane sections and commands to every signed native plugin. Device Logs retains the
  pre-install command aliases and `from-device` route in `NativePluginManagedOffer`. A public
  contextual-route declaration and capability-scoped iPhone tool broker remain to reach full
  Device Logs parity. The host keeps placement and command conflicts.
- **No install flow for a third-party plugin.** A bundle is placed in `~/Library/Application
  Support/Threading/Plugins` by hand, and the approval prompt is the whole review surface. It says
  which tier the thing is and cannot be suppressed, but it is a dialog rather than a flow: nothing
  yet lists what has been approved or offers to revoke it, though `NativePluginApprovalStore`
  supports both.
- **Manual third-party plugins have no automatic crash quarantine.** The managed first-party
  path records a load-start and load-finish checkpoint, blocks the exact build after an unclean
  load, and offers an explicit Retry. A manually placed bundle still requires the user's build
  approval, and the host does not silently quarantine it without a matching recovery path.
- **Gatekeeper still runs at `dlopen`** for a bundle carrying a quarantine attribute, and refuses
  with its own dialog rather than an error we control. An install flow has to own the attribute.
  This is the real requirement a third-party plugin faces:
  it must be Developer ID signed **and notarized**, which also means signed with a secure timestamp.
  The first-party on-demand installer now removes the attribute only after manifest and notarized
  code checks. `build_plugin.sh` passes `--timestamp=none` for a bundled development build; the
  release export signs the distributable bundle again with a secure timestamp.

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

### Device Logs in independent dock groups

The log plugin supports two optional, additive PluginKit selectors:
`makePaneSectionView(identifier:)` and `setPaneSectionPresented(identifier:presented:)`.
The host opts in with `hostPaneSections=true` in the initial context. Without that opt-in, the
plugin retains its internal segmented-control presentation, so older hosts and ordinary native
plugins keep their existing contract. The binary API generation remains 5.

Device Logs and Bluetooth become separate host tabs, with persisted modes `regular` and
`bluetooth`. Each first-party offer declares its ordered section identifiers and localized title
keys in `NativePluginManagedOffer`; the first is the primary section. The panel, dock and drawer
use the same registration to create and restore tabs, validate saved modes and accept tool reveals
without reading bundle metadata on the main actor. `NativePluginPaneViewController.sectioned`
shares one verified plugin owner and one runtime registration per bundle and session. Device Logs
adds only its privileged managed-tool path. A Bluetooth sibling retains that owner,
including when the regular tab closes.
Visibility is tracked per section: both can project rows simultaneously, an inactive section
keeps its reader while another is visible, and hiding the last section stops both. Visibility
loss is deferred one main turn so synchronous tab reparenting does not restart capture. Theme
handoff repaints both section trees, including a section in another dock group.

**One command opens one tab.** Device Logs (`panel.deviceLogs`) and Bluetooth
(`panel.bluetoothLogs`) are separate panel commands, each revealing or creating only its own
section tab, in either order. Their stable command IDs, titles, icons and optional descriptions
are declared beside their section identifiers in the first-party managed offer. The command
registry and `+` menu therefore expose them before the on-demand bundle is installed, while the
panel resolves the current fixed bundle address and opens the declared section. Device Logs first
opened a Bluetooth tab beside itself, so one menu
choice produced two tabs and a packet tab the user had not asked for; a legacy row persisted
without a mode now restores as Device Logs alone for the same reason. A native `PluginTool` may
declare `paneSectionToReveal`; the six-argument initializer remains available to existing
plugins. The runtime snapshots the tool declarations when the pane loads; the MCP provider
verifies that the invoked tool was in that snapshot, then asks the pane that
owns that exact loaded instance to reveal the section before invoking it. This also keeps two
windows with the same plugin from routing to the most recently opened window. Device Logs declares
`bluetooth` for its capture tool, so an agent's packets arrive in a visible tab. A section must
also be declared in its first-party managed offer; naming a section in a tool alone does not
create section chrome. If the owning host cannot reveal the declared section, the
provider refuses the tool call rather than starting work in an invisible pane. The offer's
section registration is the one source for panel, dock and drawer routing. Threading retains tab
placement and lifetime. See
`WorkspaceDockTests.testDeviceLogsAndBluetoothCommandsEachOpenOnlyTheirOwnTab`.
