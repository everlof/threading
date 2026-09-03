# Threading legal notices

Threading is distributed under the GNU General Public License version 3. The complete license
is included in this directory as `Threading-GPL-3.0.txt`.

The application also includes or is built from the separately licensed components below. The
complete license and notice texts shipped with this build are included beside this file.

## Application dependencies

| Component | Resolved version or revision | License file in this directory |
|---|---|---|
| scc bundled source counter (macOS) | 3.7.0 official Darwin arm64 and x86_64 release executables | `scc-MIT.txt` |
| SwiftTerm (vendored fork) | Imported from `06dbdd410f0684120e2bbb0d0b645eb9285db078`, then modified in-tree | `SwiftTerm-MIT.txt` |
| NativeDiffKit | 0.1.1 / `363c6197d8e334fa0aaf30550fb0a0bcac540e71` | `NativeDiffKit-MIT.txt` |
| WebRTC binary distribution | 150.0.0 / `6ed87f05368632f71dc95c89c14c051561710925` | `WebRTC-BSD-3-Clause.txt` |
| BorderBeamKit (macOS) | `cbea80755c9d8371b44f158cf340cc84d0c8b93b` | `BorderBeamKit-MIT.txt` |
| LabelMorph (macOS) | `677d6dad55cd9bf08a6a2fd97f814f4ce072fe11` | `LabelMorph-MIT.txt` |
| ThinkingOrbs (macOS) | `9287ca9da66cd21851cbe4d7e9019a7cf669d23d` | `ThinkingOrbs-MIT.txt` |
| Sparkle (macOS) | 2.9.4 / `b6496a74a087257ef5e6da1c5b29a447a60f5bd7` | `Sparkle-LICENSE.txt`, `Sparkle-ed25519-LICENSE.txt` |
| WasmKit (macOS helper) | 0.1.6 / `827056b014e37da50e2645a7634fddb32e441f32` | `WasmKit-MIT.txt`, `WasmKit-NOTICE.txt` |
| swift-system (macOS helper) | 1.6.3 / `395a77f0aa927f0ff73941d7ac35f2b46d47c9db` | `swift-system-LICENSE.txt` |
| swift-argument-parser (resolved build graph) | 1.8.2 / `6a52f3251125d74daf04fcbd5e6f08a75d074382` | `swift-argument-parser-LICENSE.txt` |

The macOS-only files are present in the macOS application bundle. The iOS bundle contains the
notices applicable to its smaller dependency graph. The WebRTC notice contains both the binary
distribution's BSD terms and the upstream Google WebRTC terms supplied by the pinned package.

## Bundled fonts and font-derived artwork

| Asset | License files in this directory |
|---|---|
| W95FA | `W95FA-OFL-1.1.txt`, `W95FA-SOURCE.md` |
| Platinum bitmap fallback | `PlatinumBitmap-OFL-1.1.txt`, `PlatinumBitmap-SOURCE.md` |
| Topaz Workbench fallback | `Topaz-GPL-2.0.txt`, `Topaz-FONT-EXCEPTION.txt`, `Topaz-UPSTREAM-README.txt`, `Topaz-SOURCE.md` |

The build copies these texts from the pinned source checkout rather than maintaining rewritten
license summaries. `scripts/check_bundled_licenses.sh` verifies that every required file is
present and non-empty in the finished application resources.
