# Bundle-size levers

> Status: **decision record** (2026-08-22). **Done**: ship `arm64` only — the durable rule now
> lives in [`releasing.md`](../architecture/releasing.md#apple-silicon-only). **Reject**
> on-demand resources and any further stripping. **Wait for evidence** on `-Osize`. **Wait for
> demand** on a slimmer or on-demand WebRTC, and on Sparkle delta updates.

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
| **`-Osize`** | `__text` 22.1 → 18.0 MB per slice (−19%), bundle 107 → 99 MB, download 46.2 → 43.8 MB; speed cost unmeasured | **Wait for evidence**: a `scripts/profile_threading.sh full` sweep at `-Osize` with no regression reopens it. 2.4 MB of download is not worth an unmeasured speed cost |
| **Resources on demand** (a CDN, "our Cloudflare setup") | Resources are 7.4 MB on disk, 3.7 MB compressed; deleting every one saves 8% of the download | **Reject**. macOS has no on-demand resources; a signed bundle cannot change after signing, so files would live outside it with their own integrity check, offline story and first-launch wait. The Cloudflare service is a signalling/TURN control plane, not a CDN |
| **Slimmer WebRTC** | 27 MB universal, 11.8 MB `arm64`, 5.5 MB compressed, for nine imported classes — the data channel, ICE and SDP types; no media | **Wait for demand**. A data-channel-only libwebrtc is a depot_tools checkout and a build we maintain; downloading it on demand is code, so a signed and notarized payload, EdDSA verification, quarantine handling and a fail-safe loader — a second Sparkle. Reopen when remote-access adoption is known or a maintained slim community build exists |
| **Sparkle delta updates** | Affects updates only; `scripts/generate_appcast.sh` runs `--maximum-deltas 0` with only the current zip in its work dir, so deltas cannot be produced today | **Wait for demand**: reopen when update downloads are what people notice. The change is to download the previous release's zip into `$WORK` and raise `--maximum-versions`/`--maximum-deltas` |
| **`scc` on demand** | Official build is already `-s -w`; 4.4 MB `arm64` | **Reject**: the on-demand cost is WebRTC's for a smaller prize |
| **`SWIFT_REFLECTION_METADATA_LEVEL=none`** | `__swift5_fieldmd` + `__swift5_reflstr` ≈ 0.5 MB per slice; three `Mirror(` call sites to audit | **Reject**: not worth the audit |

## 4. Evidence that should reopen this

- A user-facing signal that the download, not the bundle, is what people judge — then Sparkle
  deltas first.
- Remote-access adoption numbers, or a maintained data-channel-only WebRTC build — then the
  WebRTC row.
- A full profile sweep at `-Osize` that shows no regression on the interaction workloads.
- Any new embedded binary over ~5 MB: add it to the table in §2 before accepting it.
