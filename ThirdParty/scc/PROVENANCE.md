# Bundled scc provenance

Threading bundles [scc](https://github.com/boyter/scc) 3.7.0 under its MIT license. The macOS
executable is the official arm64 release executable, byte for byte: Threading does not patch,
rebuild or combine it. (Threading ships for Apple silicon only — see
`docs/architecture/releasing.md`, "Apple silicon only".)

| Official asset | SHA-256 |
|---|---|
| `scc_Darwin_arm64.tar.gz` | `376cbae670be59ee64f398de20e0694ec434bf8a9b842642952b0ab0be5f3961` |

The executable extracted from that archive, and therefore the checked-in `scc`, has SHA-256
`ecfd9c37119ffe354b96d5cc37b0e5eafaa7f454c5d05566c9ba9ff9da3a57d9` before Xcode signs the copy
embedded in the app. (Bundles built before 2026-08-22 carried a `lipo`-combined universal binary,
SHA-256 `0a41a621edc697b888b92c424ffea37e82f7c06db85bbae0c10ee19236dc1d9f`, whose arm64 slice is
this same executable.)

Run `scripts/update_bundled_scc.sh` to reproduce this binary. Updating scc deliberately requires
updating that script's pinned version and checksums, this file, the legal notice table, and the
dependency audit in the same change.
