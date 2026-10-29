# Bundle diet: measure, stop the copies, then load features on demand

Status: agreed plan. Step 0 (the size ratchet) is implemented 2026-10-17, step 1a (the proxy
helper's source out of the bundle) 2026-10-18, and step 1b (one shared plugin runtime)
2026-10-20. Step 2 now moves T3 Navigator and Device Logs from the notarized release app to
signed on-demand archives. Both have install rows in Extensions Settings; a first-party pane
listed in the shared managed-offer catalogue also installs from its own missing-bundle view.
The pane-section host now shares one plugin instance per bundle and session, with Device Logs as
its first tenant. First-party section identifiers and titles are declared once in the managed
offer catalogue and drive panel, dock, drawer and saved-route validation. The Devices pilot has
moved its Simulator helper into a third on-demand bundle;
the network proxy helper and setup script now live in a fourth.
Step 1c's matched speed gate rejected `-Osize` for now; the rest of step 3 remains to do.
Planned: 2026-10-17.

## The problem

`Threading.app` was 54.5 MB on disk and a 24.5 MB download on 2026-08-22
([`bundle-size-levers.md`](../decisions/bundle-size-levers.md) §2). On 2026-10-17 the same
measurement — an archived Developer ID export, thinned to `arm64` — is **129.0 MB on disk and
63.1 MB compressed**. The instinct is to move features out of the main binary into extensions that
load on demand. The measurements say that is right for some features, wrong as the first step,
and actively harmful with today's plugin linking.

## What the size is (2026-10-17, `884de6e3e`)

`scripts/check_bundle_size.py --report` on the auto-installer's profiled export, thinned:

| Component | On disk | Compressed | 2026-08-22 on disk |
|---|---|---|---|
| `MacOS/Threading` | 53.8 MB | 22.9 MB | 28.4 MB |
| `Resources/ProxySource` | 17.2 MB | **16.8 MB** | — |
| `Frameworks/WebRTC.framework` | 11.9 MB | 5.7 MB | 11.8 MB |
| `PlugIns/DeviceLogsPlugin.bundle` | 11.8 MB | 4.9 MB | — |
| `PlugIns/T3NavigatorPlugin.bundle` | 10.6 MB | 4.3 MB | — |
| `Helpers` (all nine) | 8.6 MB | 3.3 MB | 5.3 MB |
| every other resource | 12.9 MB | 4.6 MB | 7.4 MB (all resources) |
| `Sparkle.framework` and the rest | 2.2 MB | 0.7 MB | 1.6 MB |
| **Total** | **129.0 MB** | **63.1 MB** | **54.5 MB** |

Four findings decide the plan:

1. **The main binary has no fat feature.** A Release link map (`LD_GENERATE_MAP_FILE=YES`),
   attributed by source file and grouped by filename, puts the largest areas of the `Threading`
   module at (shares only: that `xcodebuild build` carried coverage instrumentation, which
   inflates absolute sizes by roughly a third): themes ~10%, remote access and iPhone pairing ~9%, the extension host ~7%,
   usage/accounts ~6%, the native conversation ~6%, the browser ~6%, triggers ~5% (plus the
   2.2 MB `ThreadingController` package), simulators and devices ~4%, git ~4%, MCP ~4%. The
   largest file is `MCPTools.swift` at ~3%. 1,637 commits added ~240k net lines since
   2026-08-22; the binary grew ~24 MB with them. That is §2 of the decision record again: it
   shrinks by writing — or moving — code, not by flags.
2. **Each native plugin is ~10 MB of copies.** Both plugin targets link `ThreadingDesignKit`
   statically, and with it SwiftTerm, ThreadingRemoteKit, ThreadingExtensionKit, ThreadingDomain,
   BorderBeamKit, ThinkingOrbs, LabelMorph and NativeDiffCore. T3Navigator's own objects are
   ~130 KB of `__TEXT`; its binary is 7.2 MB of `__text`. 216 Objective-C class names are
   defined in both plugins, and 126 of T3Navigator's also exist in the host. **Moving a feature
   into a plugin today makes the app ~10 MB bigger.**
3. **`ProxySource` is a quarter of the download** and compresses not at all: it is the
   unmodified upstream tarballs of the proxy helper's five dependencies, retained so the legal
   notices can point at source in the bundle
   ([`dependencies.md`](../architecture/dependencies.md), portable proxy helper). It landed without
   a row in the decision record's table, as did both plugins — the written 5 MB rule was not
   enforced by anything.
4. **The safe extension tier is not a size vehicle.** A release Wasm module that links Foundation
   measures ~68 MB ([`docs/extensions/README.md`](../extensions/README.md), measured 2026-10-04). Features move to the
   native first-party tier or not at all.

After step 1a the same bundle measures **112.0 MB on disk and 46.4 MB compressed**.

The `/Applications` copy measured 141 MB because the auto-installer skipped thinning (16.8 MB of
WebRTC and Sparkle `x86_64`); that is fixed in step 0 and was never the product.

## The plan

### 0. Make size a gate — **implemented 2026-10-17**

`scripts/check_bundle_size.py` against `scripts/bundle_size_baseline.json`, enforced by
`release.sh` after the signing sweep; the auto-installer thins its archive before export, as
release does, and appends each build's size to `history.log`. The durable contract is in
[`releasing.md`](../architecture/releasing.md#the-bundle-size-ratchet).

### 1. Size opportunities that do not remove features

- **a. `ProxySource` out of the bundle** (−16.8 MB compressed) — **implemented 2026-10-18.**
  The helper's dependencies (MIT, BSD, ISC, Apache-2.0, Zlib) require their notices, not their
  source, so those stay — now in `Legal/ProxyHost/`, 0.25 MB. The source obligation is the GPL's
  on the helper itself, and it is now met the way the rest of Threading's GPL source always was:
  from the place the app is downloaded. Every release carries
  `threading-proxyd-source-<version>.tar.gz` beside the zip, and the notices say so. The owner
  chose this over keeping the tree (every download pays) and over waiting for the proxy to become
  an on-demand plugin (step 3). The contract is in
  [`releasing.md`](../architecture/releasing.md#the-proxy-helpers-source).
- **b. One shared plugin runtime — implemented 2026-10-20.** `ThreadingDesignKit` and its
  statically linked dependency closure are one dynamic framework in `Contents/Frameworks`,
  linked by both bundled plugins and **not** by the app executable. A separately installed plugin
  uses the package's static `ThreadingDesignKitStandalone` product so its private Swift ABI travels
  with that build. The two bundled plugins receive the same encoded theme; a duplicate delivery
  now posts one shared theme-change notification. Host/kit class-name duplicates remain across
  two images rather than three. The exported Developer ID archive, thinned to arm64, measured
  8.96 MB less on disk and 4.04 MB less compressed for DesignKit plus the two plugins than the
  previous two plugin bundles. The complete app measured 103.42 MB / 42.50 MB, down 8.62 MB /
  3.90 MB from the step-1a baseline; other app changes between those revisions account for the
  difference between the two comparisons. The shared 11.22 MB framework is now a fixed cost;
  each additional bundled plugin pays for its own code and resources. The signing and hosted
  loading checks passed. See [`plugins.md`](../architecture/plugins.md) for the build boundary.
- **c. `-Osize`** (−19% `__text` measured on 2026-08-22). A second arm64 Developer ID archive,
  thinned and exported with `XCODE_XCCONFIG_FILE` forcing `-Osize` for every Swift target, passed
  `codesign --verify --deep --strict`. Against the step-1b `-O` export its app executable is
  7,949,056 bytes smaller, DesignKit is 881,104 bytes smaller, Device Logs is 159,744 bytes
  smaller, and T3 Navigator is 14,576 bytes smaller. The complete app measured 94.22 MB on disk
  and 40.11 MB compressed, compared with 103.42 / 42.50 MB for the prior export. The whole-bundle
  comparison also includes a changed helper grouping, so it is not a clean attribution to the
  flag. **The flag remains off.** Matched `scripts/profile_threading.sh full` interaction
  sweeps on 2026-10-20 completed against the same source and app-hosted fixtures: 116 ordered
  `THREADING_PERF` records under each setting, plus a sample and three Instruments traces.
  Across seven project-sidebar fixture sizes, `-Osize` made tree construction 27% slower,
  cold reload 24% slower, and same-shape refresh 30% slower at the median. The range for
  same-shape refresh was 28–32% slower. Settings search stayed effectively even
  (95.09 versus 95.23 ms), and the median ratio over all timing fields was +1.9%, but the
  repeated sidebar regression fails the interaction gate. The runs were sequential, so thermal
  state was not alternated; a later alternating sidebar experiment could reopen the decision.
  The flag is not enabled in the shipping build.
  Twelve alternating, fresh-home launches of the two signed exports gave median first-frame times
  of 996 ms (`-O`) and 1,052 ms (`-Osize`). The paired median difference was +30 ms, with five of
  twelve pairs faster under `-Osize`; this did not establish an interaction cost. The earlier
  failed full-sweep attempt was superseded by the completed matched run above.

### 2. One on-demand install path, built once

The decision record rejected on-demand WebRTC because it would be "a second Sparkle" for one
5.5 MB payload. Built once and used by every movable feature, that cost is amortized — the
record's own reopen condition. Shape:

- `release.sh` builds, signs (with a secure timestamp — `build-plugin.sh`'s `--timestamp=none` is
  right only for a bundled plugin) and notarizes each first-party plugin with the app.
- They are published beside the appcast with an EdDSA-signed manifest keyed to the **exact host
  build**. `ThreadingDesignKit` has no library evolution, so a first-party plugin is lockstep with
  its host, never a compatibility range.
- The installer downloads into the existing `~/Library/Application Support/Threading/Plugins`,
  owns the quarantine attribute, and trusts without a prompt only what is our team, `notarized`
  (the requirement `plugins.md` "Still open" already describes) and matches the manifest digest.
- After a Sparkle update, features the person has used are fetched again in the background.
  Offline, a feature shows an install state with its size rather than failing.
- A plugin that crashes at load is quarantined through the launch ledger in
  [`crash-recovery.md`](../architecture/crash-recovery.md).
- `Pymobiledevice3Installation.swift` is the in-repo precedent for consent and atomic rollback.

A local release-shaped Developer ID export with both native bundles removed measured **101.21 MB
on disk / 41.66 MB compressed**, down 2.21 / 0.84 MB from the step-1b baseline. The app's deep
signature passed; the two separately notarized, stapled archives passed the Swift managed-receipt
gate against that exact app and its signed manifest. A complete clean-tree release run and remote
publication have not yet been exercised, so the size baseline stays at the last shipping export.
The release now stages and removes the export's full native `.bundle` set, resetting stale staged
copies and refusing a changed set; the next first-party bundle can use the same shipping path.
The Devices pilot exercised that generic path with three bundles in a local arm64 Developer ID
archive/export. After staging and removing all three plugins, the app passed deep signature and
helper-entitlement checks and measured **101.02 MB on disk / 41.59 MB compressed**. The separately
notarized, stapled Devices archive was 156,570 bytes. A signed manifest admitted it against that
exact exported host, and the Simulator launcher selected its resolved version path. Changing one
byte in the nested helper made both the managed receipt and launcher refuse it. This was a local
release-shaped probe, not a clean-tree release or publication; its size is not a like-for-like
attribution against the prior export.

### 3. Move the features that bring a heavy payload with them

One pilot, then by payload:

1. **Devices** — the Simulator, physical iPhone and Android panes, `threading-simulator-helper`
   and Device Logs (already a plugin). Used only by people developing for those platforms;
   ~4% of the binary plus the helper. About 30 host files reference it.
2. **iPhone companion** — remote access, pairing and `ThreadingPeerTransport` with
   `WebRTC.framework`: ~9% of the binary plus 11.9 MB on disk, the largest optional payload.
   About 64 host files reference it and it carries notification delivery, so it is second, not first.
3. Smaller: the network proxy (~1 MB of helper now that its source is published separately), Linked Workrooms,
   theme authoring, and the component gallery (~1.5% of the binary, shipped to every user).

The Devices pilot has started: `DevicesPlugin.bundle` now carries the Simulator helper, and the
app target no longer embeds a second copy. Its managed install offer uses the same signed manifest
and Settings path as Device Logs and T3. The host verifies the exact managed build and nested
helper, then launches the resolved version rather than a replaceable symlink. The device panes,
Android backend and physical-iPhone code still live in the host and remain to be moved.
The first public-API Simulator slice adds a read-only Snapshots pane to that same Devices bundle.
It uses `PluginContext.simulatorServices` for bounded running-device discovery and exact-device
PNG capture; approved external native plugins receive the same service. The broker enters the
existing device transaction gate before `simctl` capture, so a plugin cannot wedge a live
workspace by racing its private stream. This makes a usable external example, but does not yet
remove the interactive workspace or backend from the app binary. Those are still the
size-bearing Devices move.
An unpublished Developer ID archive/export on 2026-10-23 passed deep signature and helper
entitlement checks. The dry-run export retains all four bundles and measured **104.70 MB on disk /
42.90 MB compressed**; its size ratchet failed because the reviewed baseline predates the new
embedded Proxy bundle. A copy pruned with `native_plugin_staging.py` against the export's exact
staged bundle set was re-signed, passed deep signature verification and the size ratchet, and
measured **100.32 MB / 41.27 MB**. It was not notarized or published, and the 2026-10-23 source is
not a matched comparison with the earlier 99.95 MB / 41.11 MB probe. The separately built Devices
bundle from the public SDK recipe also loaded through the native pane host; live PNG capture on a
booted Simulator was not verified because CoreSimulator discovery did not answer during the probe.

The network proxy's portable helper and certificate setup script now build into
`ProxyPlugin.bundle`. The app's direct copies are removed. The host verifies the signed managed
receipt, nested helper identity and signing team before launching a pinned version path; the host
still owns capture leases, client consent and CA private keys. The Settings install row uses the
same release manifest path as the other first-party bundles. A local arm64 Developer ID export
with all four plugins staged and removed measured **99.95 MB on disk / 41.11 MB compressed**.
The Proxy archive was separately notarized and stapled, measured **587,923 bytes**, and passed
the signed-manifest receipt against that exact host. The launcher selected the resolved version's
helper; changing the signed setup script made both the receipt and launcher reject it. This was a
local release-shaped probe, not a clean-tree release or remote publication, and its size is not a
like-for-like attribution against the earlier Devices probe.

Expect 10–15 MB off the main binary in total, plus WebRTC. The boundaries are worth as much as
the bytes.

## Growing the extension surface

For each feature, use the public sandboxed extension API when it can meet the feature's
performance and interaction needs; use the native tier only when it cannot. Features we move to
native plugins must exercise the **same published PluginKit capabilities that an independently
authored native plugin can use**. First-party status changes distribution and trust:
Threading can sign, notarize and offer its own exact-build archives without another approval.
It must not grant our plugins a private presentation, command or lifecycle API that an approved
plugin cannot use. Privileged operations remain host-owned and need explicit, capability-scoped
broker requests rather than a private host object or executable path.

A native plugin can contribute today: a restorable pane tab in panel, dock or drawer, pane
sections, the workspace navigator, `apply(theme:)`, and MCP tools that are offered only while
that chat has the pane open; its base context is four strings
(`sessionID`, `projectID`, `projectName`, `checkoutPath`). A selected-device route also supplies
the host-chosen `deviceID`. A tool can now declare a host-registered
pane section to reveal before invocation, instead of the MCP router recognizing a particular
Device Logs tool name. The drawer can retain a verified plugin pane and rebind its callbacks after
a move. Installed section registration and panel commands now come from versioned plugin metadata
for both first-party and external bundles. Before installation, Device Logs' stable command
aliases still come from its managed offer. Contextual panel/drawer routes come from installed
plugin metadata, with the managed offer retaining a matching pre-install declaration. The device
button names the Device Logs route and passes its selected device ID; `device_log_prepare` and that button still
have feature-specific entry points.

That is not full parity yet. External plugins can declare separate tabs, commands and
`selected-device` contextual routes through `ThreadingPaneSections`. Device Logs uses that same
declaration; the device controls list installed routes on right-click while primary click keeps
opening Device Logs. Its structured-log stream and Bluetooth-profile transfer now use the same
public `PluginContext.deviceServices` as any approved native plugin; no private executable path
is passed. `ThreadingPluginSDK-<version>.zip` now has a release path that includes DesignKit,
its dependencies and Device Logs with DesignKit's app-source links materialized. An isolated copy
compiled and ran the Device Logs broker test; the host parity test built and loaded it from a
locally generated SDK zip. The asset has not yet been uploaded or loaded from a real release.
Threading owns tab
placement, command identity/conflicts, restore validation and invocation. The first-party offer
retains the information needed to show an install action **before its bundle exists**; the
installed declaration must agree with it.

Next, put general native-plugin actions, Settings contributions, pane-independent MCP tools,
bounded background lifecycle and host services (session/project reads, notifications) behind
public, versioned contracts with explicit capability and user-approval rules. Build our moved
features against those contracts and test an independently built plugin with the same declaration.
An external author also needs an in-app install and update path for a signed, notarized archive;
the present manual bundle copy does not meet the simple-install goal. The first-party signed
release manifest and automatic trust remain a distribution policy, not a separate feature API.
The safe Wasm tier remains the crash-isolated option for untrusted code. The customization audit's
"host-only" verdicts (simulators, proxy, browser, Usage) keep authority and truth in Threading;
plugins may request bounded host actions only where the public contract and consent allow it.

## Non-goals

- Shrinking by deleting features, or by lowering quality (stripping is already complete).
- Automatically trusting third-party native code. An external plugin needs explicit approval
  for the exact build even when it uses the same PluginKit capabilities as Threading's plugins.
- On-demand Mac resources in general — the decision record's rejection stands for loose files.

## Evidence that should change this plan

- Step 1b measured: the shared framework saved 8.96 MB on disk and 4.04 MB compressed across
  the moved components, close to the forecast. Recheck the fixed runtime cost before moving a
  feature that needs a different dependency closure; a first-party on-demand plugin must be built
  against the exact host build to use its shared framework.
- A licensing read that the proxy helper's source must travel inside the bundle after all — then
  the proxy becomes the natural second move in step 3, because the archives move with it.
- `-Osize` passing the profile sweep changes step 1's total, not its order.
