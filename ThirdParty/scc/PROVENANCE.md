# Bundled scc provenance

Threading bundles [scc](https://github.com/boyter/scc) 3.7.0 under its MIT license. The
universal macOS executable is made only by combining the two official release executables with
Apple's `lipo`; Threading does not patch or rebuild either slice.

| Official asset | SHA-256 |
|---|---|
| `scc_Darwin_arm64.tar.gz` | `376cbae670be59ee64f398de20e0694ec434bf8a9b842642952b0ab0be5f3961` |
| `scc_Darwin_x86_64.tar.gz` | `c3f7457856b9169ccb3c1dd14198e67f730bee065f24d9051bf52cdc2a719ecc` |

The slices extracted from those archives have SHA-256 sums
`ecfd9c37119ffe354b96d5cc37b0e5eafaa7f454c5d05566c9ba9ff9da3a57d9` (arm64) and
`dada362eaa3bc92c1d17a360097b21ba195675b664a73c3cd82db4188ef6a533` (x86_64). The checked-in
universal `scc` has SHA-256
`0a41a621edc697b888b92c424ffea37e82f7c06db85bbae0c10ee19236dc1d9f` before Xcode signs the
copy embedded in the app.

Run `scripts/update_bundled_scc.sh` to reproduce this binary. Updating scc deliberately requires
updating that script's pinned version and checksums, this file, the legal notice table, and the
dependency audit in the same change.
