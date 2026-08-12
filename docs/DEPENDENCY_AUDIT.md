# Dependency and License Audit

- Audit date: 2026-08-12
- Dependency baseline: `8360796d46742796646d38bc58e565fb1401688f`
- Scope: shipped code dependencies, local package boundaries, submodules, and bundled font assets

This is an engineering publication gate, not a legal opinion.

## Result

| Gate | Result | Evidence |
|---|---|---|
| Source publication under GPLv3 | Pass | Every code dependency is MIT, BSD, zlib, or Apache-2.0 with the Swift runtime exception. |
| Public dependency access | Pass | Every Git-backed dependency is anonymously readable on GitHub. |
| Reproducible resolution | Pass | Submodules are gitlinks; remote Swift packages have committed `Package.resolved` revisions; vendored SwiftTerm is part of the parent repository. |
| Known-vulnerability check | Pass | No resolved version or pinned revision matched OSV or GitHub Advisory Database records on the audit date. |
| Binary license delivery | Pass | Fresh macOS and physical-iOS builds embed target-specific, build-verified legal-notice bundles containing 22 and 13 non-empty files respectively. |
| iOS export declaration | Release action required | WebRTC bundles standards-based DTLS/SRTP cryptography. The target now declares `ITSAppUsesNonExemptEncryption = YES`; complete Apple's App Store Connect determination and any required French declaration before distribution. |

The source-publication and binary-distribution gates pass. App Store export-compliance review is
an explicit release blocker. Re-run the advisory queries and the finished-product notice check
immediately before tagging a release.

## Human-readable SBOM

### Code

| Component | Form | Resolved version or revision | License | Advisory result |
|---|---|---|---|---|
| Threading | Main repository | `8360796d46742796646d38bc58e565fb1401688f` | GPL-3.0 | Project under audit |
| BorderBeamKit | Git submodule | `cbea80755c9d8371b44f158cf340cc84d0c8b93b` | MIT | No match by revision |
| LabelMorph | Git submodule | `677d6dad55cd9bf08a6a2fd97f814f4ce072fe11` | MIT | No match by revision |
| ThinkingOrbs | Git submodule | `9287ca9da66cd21851cbe4d7e9019a7cf669d23d` | MIT | No match by revision |
| SwiftTerm | Vendored fork | Imported from former gitlink `06dbdd410f0684120e2bbb0d0b645eb9285db078`, then modified in-tree | MIT | Historical `GHSA-jq43-q8mx-r7mq` fix verified in the vendored source; no match by imported revision |
| NativeDiffKit | SwiftPM | `0.1.1` / `363c6197d8e334fa0aaf30550fb0a0bcac540e71` | MIT | No match by version or revision |
| Sparkle | SwiftPM | `2.9.4` / `b6496a74a087257ef5e6da1c5b29a447a60f5bd7` | MIT, BSD, zlib notices in upstream `LICENSE` | No match by version or revision |
| WasmKit | SwiftPM | `0.1.6` / `827056b014e37da50e2645a7634fddb32e441f32` | MIT; Apache-2.0 derivative notices | No match by version or revision |
| swift-system | SwiftPM | `1.6.3` / `395a77f0aa927f0ff73941d7ac35f2b46d47c9db` | Apache-2.0 with Swift Runtime Library Exception | No match by version or revision |
| swift-argument-parser | SwiftPM | App graph: `1.8.2` / `6a52f3251125d74daf04fcbd5e6f08a75d074382`; standalone SwiftTerm lock: `1.6.2` / `cdd0ef3755280949551dc26dee5de9ddeda89f54` | Apache-2.0 with Swift Runtime Library Exception | No match for either resolved version; no match for app revision |
| WebRTC | SwiftPM binary target | `151.0.0` / package revision `19aa8c1fc7120d50df987b7111f42d5024df3d54`; upstream source `f20ebb8adbf4fa781830e4384c61f732bd28a217` | BSD-3-Clause and upstream WebRTC notices | No OSV match for either revision and no GitHub advisory match for version on 2026-08-12 |

The SwiftTerm library target does not link its `termcast` executable's argument-parser product,
but the standalone vendored package lock is included because it is still committed and can be
built independently.

### Bundled fonts and font-derived artwork

| Asset | Provenance pin | License | Distribution state |
|---|---|---|---|
| W95FA | Font SHA-256 `9e1ad53708307b2b68e06d43799b2267f6aec620dda972bc62753ad16ba50f2b` | SIL OFL 1.1 | Unmodified; source and OFL text retained beside the font |
| Topaz Workbench fallback | Upstream revision `d42987535d94ebbfb51e64fee76f9974c6ae145a`; font SHA-256 `da95bfdd6d16ac3602f64ae01699808efede94665fa2a7ac5f33e61641a67e14` | GPL-2.0 with GNU font exception | Unmodified; upstream README, GPL text, exception, and provenance retained |
| Platinum bitmap fallback | Systemless 0.2.1 archive SHA-256 `07eced336ab0641a30908de47d489d22997d3613927b6fc1b01069ad9056ee14` | SIL OFL 1.1 | Mechanically converted; source record and OFL text retained; reserved name not reused |

OFL fonts may be bundled with applications while remaining under the OFL. The Topaz font
exception permits ordinary use and embedding without changing the surrounding program's
license. Each asset remains separately licensed and its notice must travel with binary
distribution.

## Pinning and provenance

- `.gitmodules` uses public HTTPS URLs for all three submodules, and each parent-tree entry pins
  an immutable commit.
- `Threading.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` pins the six
  packages in the application graph to full Git revisions.
- The WebRTC manifest pins version `151.0.0` exactly. SwiftPM verifies the release archive against
  SHA-256 `64a218fad3d84a0d783321aa9a1eec58ca266ac7879123f86b0b44b703b7d8dc`, which matches both the
  package manifest and the upstream GitHub release asset digest. The release identifies upstream
  WebRTC source commit `f20ebb8adbf4fa781830e4384c61f732bd28a217`.
- `Packages/ThreadingWasmRuntime/Package.resolved` repeats the WasmKit graph pins.
- `Packages/Vendor/SwiftTerm/Package.resolved` pins the vendored package's standalone tooling
  dependency.
- Manifest version ranges do not weaken the committed build: SwiftPM consumes the checked-in
  lockfiles. Any intentional dependency update must include and review the lockfile diff.
- SwiftTerm's former gitlink revision is recoverable from repository history but was not written
  in the dependency documentation before this audit. This report makes that provenance explicit.

## Vulnerability method and result

The audit queried both of these current databases:

1. OSV `/v1/querybatch`, using every exact Git revision plus the six Swift package versions.
2. GitHub's global advisory API with the Swift ecosystem and exact affected package versions.

All exact queries returned zero affected advisories. The standalone argument-parser `1.6.2`
lock was checked separately and also returned zero.

SwiftTerm has one historical high-severity advisory,
[`GHSA-jq43-q8mx-r7mq`](https://github.com/advisories/GHSA-jq43-q8mx-r7mq), fixed before version
1.2.0. Because the vendored fork's former revision is not indexed as an upstream release, the
audit also compared the security patch directly. The vendored `Terminal.swift`:

- refuses to echo attacker-controlled invalid DECRQSS data; and
- returns empty OSC 20/21 title responses rather than attacker-controlled window titles.

Those are the three changes in the upstream fix, so the vendored code is not affected.

An empty advisory result means no published record matched the supplied identity on the audit
date. It does not prove that a dependency contains no undisclosed vulnerability.

## Binary-distribution control

Both application targets have an `Embed Legal Notices` build phase. The phase copies the root
GPLv3 text plus the exact upstream license, notice, and provenance files from the pinned source
tree and resolved SwiftPM checkouts into the finished application's `Legal` resource directory.

The build remains sandboxed on iOS: target-specific `.xcfilelist` files declare each allowed
input and output rather than disabling `ENABLE_USER_SCRIPT_SANDBOXING`. The macOS profile
contains 22 required files; the smaller iOS graph contains 13. The shared verifier rejects any
missing or empty file and runs as part of every application build, including release builds.

Verification on the audit date used fresh derived-data directories:

- macOS arm64 Debug build:
  `/tmp/threading-hosted-mac-validation/Build/Products/Debug/Threading.app`
- physical iOS Debug build:
  `/private/tmp/threading-hosted-ios-derived/Build/Products/Debug-iphoneos/ThreadingMobile.app`

Both builds passed `scripts/check_bundled_licenses.sh`. The verifier's failure path was also
exercised against an empty directory and correctly reported every absent notice.

Release procedure: re-run the exact-version advisory queries, build the release archive, and run
the same verifier against the archived `.app` immediately before tagging.

## iOS encryption export declaration

The iOS target sets `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES` in both Debug and Release.
This is intentionally conservative: the audited mobile graph uses:

- CryptoKit SHA-256 for one-way diagnostic pseudonyms;
- Security framework Keychain storage; and
- URLSession HTTP/WebSocket transport, including operating-system TLS when using secure URLs; and
- the bundled WebRTC framework's industry-standard DTLS/SRTP encryption for peer data channels.

It does not link the SSH sample shipped in SwiftTerm's repository or a proprietary cryptographic
implementation. Apple says an app and its third-party libraries must be included in the export
determination; industry-standard encryption not provided by the operating system may require a
French declaration. Complete the App Store Connect questionnaire and attach any resulting
documentation before TestFlight or App Store distribution. If Apple issues an export compliance
code, add `ITSEncryptionExportComplianceCode` to both configurations.

## Authoritative references

- [OSV API](https://google.github.io/osv.dev/api/)
- [GitHub global security advisory API](https://docs.github.com/en/rest/security-advisories/global-advisories)
- [Apple export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Apple encryption-documentation matrix](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption)
- [GNU license compatibility guidance](https://www.gnu.org/licenses/license-compatibility.en.html)
- [SIL OFL bundling guidance](https://openfontlicense.org/ofl-faq/)
- [GNU font exception guidance](https://www.gnu.org/licenses/gpl-faq.en.html#FontException)
