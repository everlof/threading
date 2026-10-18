# Bundle diet: measure, stop the copies, then load features on demand

Status: agreed plan. Step 0 (the size ratchet) is implemented 2026-10-17 and step 1a (the proxy
helper's source out of the bundle) 2026-10-18; everything after it is not started.
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

### 1. Wins that cost no feature (~22 MB of the 63 MB download)

- **a. `ProxySource` out of the bundle** (−16.8 MB compressed) — **implemented 2026-10-18.**
  The helper's dependencies (MIT, BSD, ISC, Apache-2.0, Zlib) require their notices, not their
  source, so those stay — now in `Legal/ProxyHost/`, 0.25 MB. The source obligation is the GPL's
  on the helper itself, and it is now met the way the rest of Threading's GPL source always was:
  from the place the app is downloaded. Every release carries
  `threading-proxyd-source-<version>.tar.gz` beside the zip, and the notices say so. The owner
  chose this over keeping the tree (every download pays) and over waiting for the proxy to become
  an on-demand plugin (step 3). The contract is in
  [`releasing.md`](../architecture/releasing.md#the-proxy-helpers-source).
- **b. One shared plugin runtime** (−~10 MB on disk, −~4 MB compressed today; every later plugin
  costs only its own code). Build `ThreadingDesignKit` and its dependency closure as one
  dynamic framework, embedded in `Contents/Frameworks` and **linked only by plugins**. What
  [`plugins.md`](../architecture/plugins.md) rejected was linking the kit *into the app*, which
  makes `Design` exist twice in one module; this never touches the app's compile. To check first:
  `Seam/HostSeam.swift`'s static state (`ThemeManager`, `AppThemeLibrary`) becomes shared between
  plugins, which is believed benign because every plugin receives the same encoded theme; the
  126 host/kit class-name duplicates remain as today. This is the prerequisite for step 3 — without
  it the program grows the app.
- **c. `-Osize`** (−19% `__text` measured on 2026-08-22, ~−9 MB on disk today). Still gated on a
  `scripts/profile_threading.sh full` sweep showing no interaction regression; the decision
  record's verdict stands, the prize has doubled.

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

Expect 10–15 MB off the main binary in total, plus WebRTC. The boundaries are worth as much as
the bytes.

## Growing the extension surface

The moves need seams in the **first-party native tier**, not the public one. A native plugin can
contribute today: a display-pane tab, pane sections, the workspace navigator, `apply(theme:)`, and
MCP tools that are offered only while that chat has the pane open; its context is four strings
(`sessionID`, `projectID`, `projectName`, `checkoutPath`). Device Logs reaches further only
through branches hard-coded to `deviceLogsIdentifier` (drawer placement, `device_log_prepare`,
the logs button).

The pilot needs, and so adds: command-registry contributions, Settings pages, MCP tools
independent of pane visibility, a startup/background lifecycle, a host-services broker
(session/project reads, notifications), and the drawer as a declared placement. Each replaces a
hard-coded branch, which is the argument for doing it.

These seams stay **internal**: first-party plugins are same-team and lockstep, so the seams can
change every release and promise nothing to outside authors. The public, stable surface remains
the safe tier, whose growth is a separate track. The customization audit's "host-only" verdicts
(simulators, proxy, browser, Usage) are about keeping authority away from untrusted code; a
signed in-process first-party plugin does not move that authority, so they do not block step 3.

## Non-goals

- Shrinking by deleting features, or by lowering quality (stripping is already complete).
- Opening the native tier to third parties. It remains first-party; installed third-party
  bundles keep today's explicit approval.
- On-demand Mac resources in general — the decision record's rejection stands for loose files.

## Evidence that should change this plan

- Step 1b measured: if the shared framework saves materially less than ~10 MB, the per-plugin
  cost model in step 3 is wrong and has to be re-derived before any feature moves.
- A licensing read that the proxy helper's source must travel inside the bundle after all — then
  the proxy becomes the natural second move in step 3, because the archives move with it.
- `-Osize` passing the profile sweep changes step 1's total, not its order.
