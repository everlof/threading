# Bundle-size levers

> Status: **decision record** (2026-08-22). **Done**: ship `arm64` only — the durable rule now
> lives in [`releasing.md`](../architecture/releasing.md#apple-silicon-only). **Reject**
> on-demand resources and any further stripping. **Keep `-O`** after the matched `-Osize`
> interaction sweep showed a repeated sidebar regression. **Wait for
> demand** on a slimmer or on-demand WebRTC, and on Sparkle delta updates. **Added 2026-10-08**:
> the Mermaid attachment reader ships the official tiny build, not the full one, and is not
> downloaded on demand (§2, §3). **Re-measured 2026-10-17**: 54.5 → 129.0 MB on disk and
> 24.5 → 63.1 MB compressed, none of the large additions recorded here first; a release-time
> [size ratchet](../architecture/releasing.md#the-bundle-size-ratchet) now enforces §4's 5 MB
> line, and the [bundle diet plan](../feature-drafts/bundle-diet.md) **reopens on-demand
> delivery** for first-party native plugins (§2, §3). **2026-10-18**: the proxy helper's source
> moved from the bundle to each release, 63.1 → 46.4 MB compressed (§3). **2026-10-20**: the
> shared plugin runtime is implemented, 46.40 → 42.50 MB compressed in the exported app (§3).

Part of the [decisions index](README.md). Read alongside
[`releasing.md`](../architecture/releasing.md) (the archive, export and the gates),
[`performance.md`](../architecture/performance.md) (the sweep any optimisation-level change has
to pass) and [`hosted-remote-service.md`](../feature-drafts/hosted-remote-service.md) (what WebRTC
is for).

**The one-sentence version.** The shipped bundle is judged on disk, in the Finder, and the
measurements say its weight is the second architecture, then our own code, then WebRTC —
resources, the intuitive target, are 3.7 MB of a 46 MB download, and the archive already strips
everything `strip` can take.

---

## 1. The question

How small can `Threading.app` be on disk and as a download, and which levers are worth their
engineering. The prompt was the 225 MB copy in `/Applications`, which turned out not to be the
product at all (§2).

## 2. What was measured

Master at `0fbd79f9`, Xcode 26.5, 2026-08-22. The product is what `scripts/release.sh` makes:
`xcodebuild archive -configuration Release -destination 'generic/platform=macOS'` in a clone,
measured with `CODE_SIGNING_ALLOWED=NO` (signing adds well under 1 MB), the download as
`ditto -c -k --keepParent --sequesterRsrc`.

| Component | universal on disk | arm64 on disk | compressed, universal → arm64 |
|---|---|---|---|
| `Threading` (stripped) | 59.0 MB | 28.4 MB | 25.3 → 12.1 MB |
| `WebRTC.framework` | 27.1 MB | 11.8 MB | 12.1 → 5.5 MB |
| `Helpers` (`scc` 8.6, wasm runner 2.0, two extension helpers) | 10.9 MB | 5.3 MB | 4.2 → 2.0 MB |
| `Resources` (`Assets.car` 2.7 — 1.7 of it the app icon — `ExtensionSDK` 1.5, `sv.lproj` 0.9) | 7.4 MB | 7.4 MB | 3.7 MB |
| `Sparkle.framework` | 2.8 MB | 1.6 MB | 0.9 → 0.5 MB |
| **Bundle** | **107.2 MB** | **54.5 MB** | **46.2 → 24.5 MB** |

The dSYMs the archive keeps outside the bundle are another 275 MB for the app alone.

**Added since: the Mermaid renderer (2026-10-08).** The attachment reader's bundled JavaScript
was the first new embedded payload over the ~5 MB line in §4, and was not recorded when it
landed. It is architecture-independent, so its two columns are the same; compressed is
`ditto -c -k` of the file alone. Percentages are of the 54.5 MB / 24.5 MB `arm64` bundle above,
which has not been re-measured since.

| `Resources/Mermaid` | on disk | compressed |
|---|---|---|
| `mermaid` 12.1.0, `mermaid.min.js` (shipped first) | 5.49 MB (≈10%) | 1.57 MB (≈6.4%) |
| `@mermaid-js/tiny` 12.1.0, `mermaid.tiny.js` (shipped) | 2.81 MB (≈5.2%) | 0.75 MB (≈3.0%) |

**Re-measured 2026-10-17 (`884de6e3e`).** The auto-installer's profiled archive and Developer ID
export, thinned to `arm64`, measured by `scripts/check_bundle_size.py` — the numbers are its
baseline. Compressed is raw deflate per file, within 0.4% of the real `ditto` zip (63.07 vs
63.30 MB).

| Component | 2026-08-22 on disk | 2026-10-17 on disk | compressed |
|---|---|---|---|
| `Threading` | 28.4 MB | 53.8 MB | 22.9 MB |
| `Resources/ProxySource` (unmodified upstream tarballs of the proxy's five dependencies) | — | 17.2 MB | 16.8 MB |
| `WebRTC.framework` | 11.8 MB | 11.9 MB | 5.7 MB |
| `PlugIns/DeviceLogsPlugin.bundle` | — | 11.8 MB | 4.9 MB |
| `PlugIns/T3NavigatorPlugin.bundle` | — | 10.6 MB | 4.3 MB |
| `Helpers` (nine now) | 5.3 MB | 8.6 MB | 3.3 MB |
| other `Resources` | 7.4 MB (all of them) | 12.9 MB | 4.6 MB |
| `Sparkle.framework` and the rest | 1.6 MB | 2.2 MB | 0.7 MB |
| **Bundle** | **54.5 MB** | **129.0 MB** | **63.1 MB** |

Three things in it were not true in August, and each changes a lever:

- **The two native plugins are almost entirely copies.** Each links `ThreadingDesignKit`
  statically and with it SwiftTerm, ThreadingRemoteKit, ThreadingExtensionKit and five smaller
  packages the host has already; T3Navigator's own code is ~130 KB of a 7.2 MB `__text`. A
  feature moved into a plugin under this linking costs ~10 MB more than it did in the host.
- **`ProxySource` is 27% of the download** and incompressible.
- **The main binary is still flat.** A Release link map attributes no area of the `Threading`
  module above ~10% (themes); remote access ~9%, the extension host ~7%, usage, conversation and
  browser ~6% each. 1,637 commits added ~240k net lines since August.

**Shared runtime measured 2026-10-20.** A Developer ID Release archive at `477a299e8` plus the
uncommitted runtime change was thinned to arm64 before export, then measured by the same size
script. The prior two plugin bundles totalled 22.39 MB on disk / 9.22 MB compressed. The new
`ThreadingDesignKit.framework` plus the two plugin bundles total 13.43 / 5.19 MB: a saving of
**8.96 / 4.04 MB**. The full exported app is 103.42 / 42.50 MB, down 8.62 / 3.90 MB from the
step-1a baseline; the app and other resources also changed between source revisions. The app
executable does not link DesignKit, both bundled plugin executables do, and all 22 Mach-O files
in the exported bundle passed arm64, Developer ID, hardened-runtime and secure-timestamp checks.
The framework is an 11.22 MB fixed cost; a new bundled plugin adds its own code rather than a
second design-system copy.

**Clean `v0.10.0` export measured 2026-10-26.** The signed, arm64-thinned Developer ID
export at `b891b88b2` is 100.46 MB on disk / 41.33 MB compressed. The host executable is
54.58 / 23.22 MB, up 0.57 / 0.26 MB from the 2026-10-20 baseline; this small growth is
accepted with the release's shared Device Logs and Bluetooth tools. The complete app is
1.18 MB smaller compressed, and the former `DeviceLogsPlugin.bundle` and
`threading-proxyd` components are absent. This is the first clean export after the prior
baseline, which was measured from an uncommitted shared-runtime checkout; the new
per-component baseline records the delivered layout and locks in the net saving.

**Stripping is already complete.** `STRIP_INSTALLED_PRODUCT=YES`, `STRIP_STYLE=all`,
`STRIP_SWIFT_SYMBOLS=YES`, dead-stripping and whole-module `-O` are all in effect for the
archive; the shipped main binary has 3.4k symbols left (the exports dyld needs) and a 1.1 MB
`__LINKEDIT`. There is nothing more for `strip` to take.

**The 225 MB `/Applications` copy is not the product.** `scripts/autoinstall.sh` uses
`xcodebuild build`, which (a) never strips — `build` does not set `DEPLOYMENT_POSTPROCESSING`,
so the binary carried 323k symbols and a 49.7 MB `__LINKEDIT` per slice; (b) built both slices,
because `ONLY_ACTIVE_ARCH=YES` has no active architecture under a `generic/platform=macOS`
destination; and (c) compiled with coverage instrumentation — `-profile-coverage-mapping
-profile-generate` on twelve modules, a 2.3 MB `__LLVM_COV` segment, `__text` 12% larger, and
`default.profraw` dumped on exit by every instrumented helper — because the scheme's
`.xctestplan`s leave `codeCoverage` unset and Xcode's default for a test plan is *on*. The
`archive` action ignores the scheme's coverage setting; `build` and `test` honour it. (a) and (b)
are now moot for our own targets; (c) is a build-hygiene change — `"codeCoverage": false` in the
plans' `defaultOptions`, coverage re-enabled per run with `-enableCodeCoverage YES` — recorded here
so the local copy is not mistaken for the release again. It is not a release-size lever.

**Where our own 28 MB goes** (`arm64` `__text`, attributed by symbol from the archive's dSYM):
`Threading` 16.5 MB, Swift stdlib specialisations 2.3 MB, `SwiftTerm` 1.1 MB,
`ThreadingExtensionKit` 0.8 MB, `ThreadingRemoteKit` 0.6 MB, `ThreadingPeerTransport` 0.3 MB. The
largest single function is a 116 KB one-time initialiser (`authoredDeclarations`); everything else
is under 30 KB. There is no fat spot; the binary shrinks by writing less code, not by flags.

## 3. Levers

| Lever | Measured | Verdict |
|---|---|---|
| **Ship `arm64` only** | 107 → 54.5 MB on disk, 46 → 24.5 MB download; a product decision and ~0 code | **Done** — [`releasing.md`](../architecture/releasing.md#apple-silicon-only) |
| **`-Osize`** | `__text` 22.1 → 18.0 MB per slice (−19%), bundle 107 → 99 MB, download 46.2 → 43.8 MB in the original probe | **Keep `-O`**: matched full interaction sweeps found a repeated 24–30% project-sidebar regression under `-Osize`; a later alternating retest may reopen it |

| **Resources on demand** (a CDN, "our Cloudflare setup") | Resources are 7.4 MB on disk, 3.7 MB compressed; deleting every one saves 8% of the download | **Reject**. macOS has no on-demand resources; a signed bundle cannot change after signing, so files would live outside it with their own integrity check, offline story and first-launch wait. The Cloudflare service is a signalling/TURN control plane, not a CDN |
| **Slimmer WebRTC** | 27 MB universal, 11.8 MB `arm64`, 5.5 MB compressed, for nine imported classes — the data channel, ICE and SDP types; no media | **Wait for demand**. A data-channel-only libwebrtc is a depot_tools checkout and a build we maintain; downloading it on demand is code, so a signed and notarized payload, EdDSA verification, quarantine handling and a fail-safe loader — a second Sparkle. Reopen when remote-access adoption is known or a maintained slim community build exists |
| **Sparkle delta updates** | Affects updates only; `scripts/generate_appcast.sh` runs `--maximum-deltas 0` with only the current zip in its work dir, so deltas cannot be produced today | **Wait for demand**: reopen when update downloads are what people notice. The change is to download the previous release's zip into `$WORK` and raise `--maximum-versions`/`--maximum-deltas` |
| **Mermaid: tiny build** | 5.49 → 2.81 MB on disk, 1.57 → 0.75 MB of every update download; loses mindmap and architecture diagrams (cytoscape) and KaTeX math, which then show their source | **Done** — `Resources/Mermaid/SOURCE.md`; the reader's tests pin which diagram types render |
| **Mermaid on demand** | Would save the remaining 0.75 MB of download | **Reject**: the resources-on-demand row's costs, plus it is executable code — a hash-verified download into a location the page's `script-src` must be widened to, a cache pinned to the exact version `viewer.js` was written against, and a reader that no longer renders offline the first time |
| **`scc` on demand** | Official build is already `-s -w`; 4.4 MB `arm64` | **Reject**: the on-demand cost is WebRTC's for a smaller prize |
| **`SWIFT_REFLECTION_METADATA_LEVEL=none`** | `__swift5_fieldmd` + `__swift5_reflstr` ≈ 0.5 MB per slice; three `Mirror(` call sites to audit | **Reject**: not worth the audit |
| **A release-time size ratchet** (2026-10-17) | The 5 MB rule in §4 held for nothing it applied to: Mermaid was recorded after it landed, and the 74.5 MB since arrived unrecorded | **Done** — [`releasing.md`](../architecture/releasing.md#the-bundle-size-ratchet) |
| **`ProxySource` outside the bundle** (2026-10-17) | −16.8 MB of a 63.1 MB download (129.0 → 112.0 MB on disk, 63.1 → 46.4 MB compressed); reverses the retained-source choice in [`dependencies.md`](../architecture/dependencies.md). Adds 0.25 MB of upstream license texts to `Legal/`, which the bundle must carry once the source does not | **Done** 2026-10-18, by the owner's call: the source is attached to every release beside the zip (GPLv3 §6(d)) — [`releasing.md`](../architecture/releasing.md#the-proxy-helpers-source) |
| **One shared plugin runtime** (2026-10-20) | −8.96 MB on disk / −4.04 MB compressed across the plugin components; one 11.22 MB dynamic kit linked by bundled plugins only, never by the app | **Done** — step 1b; future bundled plugins pay only for their own code and resources |
| **First-party plugins on demand** (2026-10-17) | The "second Sparkle" cost of the WebRTC row, paid once for every movable feature | **Reopened** — step 2; this row supersedes "wait for demand" on WebRTC, which moves with the iPhone companion in step 3 |

The 2026-10-20 step-1b follow-up archived and Developer ID exported `-Osize` for all Swift
targets. It saved 7.95 MB in the host executable and 0.88 MB in the shared plugin framework on
disk; the complete app was 94.22 MB / 40.11 MB against the earlier `-O` export's 103.42 MB /
42.50 MB. Another helper packaging change is present between those exports, so the whole-app
delta is not wholly attributable to optimization. On 2026-10-20, both `-O` and `-Osize`
completed `scripts/profile_threading.sh full` against the same source and app-hosted test bundle
shape: 116 corresponding performance records and the sample plus three Instruments traces per
setting. Median ratio over all timing fields was +1.9%, but across seven project-sidebar fixture
sizes, tree construction was 27% slower, cold reload 24% slower, and same-shape refresh 30%
slower under `-Osize`. The latter ranged from 28% to 32% slower. The runs were sequential, not
alternated after the expensive rebuild, so thermal state remains a possible confounder; the
repeated sidebar cost does not pass the no-regression gate. Leave the shipping flag at `-O`.

## 4. Evidence that should reopen this

- A user-facing signal that the download, not the bundle, is what people judge — then Sparkle
  deltas first.
- Remote-access adoption numbers, or a maintained data-channel-only WebRTC build — then the
  WebRTC row.
- An alternating, matched sidebar and full-profile sweep that explains or removes the measured
  `-Osize` regression without moving the bottleneck to another interaction workload.
- Any new embedded binary over ~5 MB: add it to the table in §2 before accepting it. Since
  2026-10-17 `release.sh` refuses an unseen component over 1 MiB until the baseline is
  regenerated, so the rule is enforced at the release rather than remembered.
