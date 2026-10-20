# threading-proxyd dependencies

The Threading helper's own code follows the repository's **GPL-3.0-only** license, reproduced
in `LICENSE`. It is not independently relicensed. The retained upstream code is unmodified and
keeps its own terms:

| Component | Version | Terms | Original notices |
|---|---|---|---|
| libuv | 1.53.0 | MIT; some source files BSD-2-Clause or ISC | `libuv-MIT.txt`, `libuv-LICENSE-extra.txt`, `libuv-SOURCE-NOTICES.txt` |
| llhttp generated C and preferred TypeScript source | 9.4.3 | MIT | `llhttp-MIT.txt`, `llhttp-LICENSE-MIT.txt` |
| libuv documentation, retained in its source archive | 1.53.0 | CC-BY-4.0 | `libuv-LICENSE-docs.txt` |
| Mbed TLS and bundled TF-PSA-Crypto | 4.1.1 release bundle | Apache-2.0, chosen from upstream Apache-2.0 OR GPL-2.0-or-later | `mbedtls-LICENSE.txt`, `tf-psa-crypto-LICENSE.txt`, `mbedtls-SOURCE-NOTICES.txt` |
| Mbed TLS/TF-PSA build frameworks | Bundled with 4.1.1 | Apache-2.0, same dual-license offer | `mbedtls-framework-LICENSE.txt`, `tf-psa-framework-LICENSE.txt` |
| mldsa-native, source only; driver disabled by upstream defaults | Bundled with TF-PSA-Crypto | Apache-2.0 OR ISC OR MIT; some test/example files MIT-0 or public-domain alternatives; documentation CC-BY-4.0 | `mldsa-native-LICENSE.txt`, `mldsa-native-RELICENSE.md`, `mldsa-example-LICENSE.txt`, original source notices |
| cJSON | 1.7.19 | MIT | `cJSON-MIT.txt` |

In the source tree these files live in `third_party/licenses/`; an installed helper places them
in `share/threading-proxyd/licenses/`; both Threading.app and its separately distributed
`ProxyPlugin.bundle` keep copies in `Contents/Resources/Legal/ProxyHost/`. The file-level libuv notice collection includes all leading
copyright/license blocks in `src/` and `include/`, including the BSD tree, ISC address conversion,
IDNA, queue and heap code. Do not replace this with just the top-level MIT text.
The Mbed TLS collection preserves leading C/header/assembly notices throughout the complete
release bundle, including crypto drivers and source-only tests/examples. Original files retain
full notices and documentation attribution. Upstream source is unmodified.

`third_party/manifest.json` records the exact upstream download URLs and SHA-256 hashes.
The CMake build verifies all four build archives before extracting them and needs no network.
The provenance test also verifies the preferred-source archive and compares notices byte for byte
with upstream. llhttp's generated release archive builds without Node; its matching TypeScript
generator, package lockfile, fixtures and regeneration instructions are retained separately.
Regenerating the parser needs that upstream toolchain; normal offline compilation does not.

MIT, BSD-2-Clause, ISC and Apache-2.0 permit redistribution under their respective conditions and are compatible with the
repository's GPLv3 distribution. See the [GNU license list](https://www.gnu.org/licenses/license-list.html)
and [license compatibility guidance](https://www.gnu.org/licenses/license-compatibility.en.html).
Retaining these notices does not remove the helper's own GPL source-distribution obligations.
`cmake --install` therefore installs the complete helper source and retained dependency archives
beside the executable's notices, under `share/threading-proxyd/source/`. Distribute that tree with
the helper; do not distribute the executable alone. `ProxyPlugin.bundle` carries the executable
and notices but not the source: it offers the source from the place the plugin is downloaded (GPLv3
§6(d)). `scripts/release.sh` archives this directory at the released commit as
`threading-proxyd-source-<version>.tar.gz`, every publisher attaches it to the GitHub release beside
`Threading-<version>.zip`, and the app's `Legal/THIRD_PARTY_NOTICES.md` says so.

OpenSSL, nghttp2, mitmproxy, Proxyman and Atlantis are **not linked or redistributed dependencies**.
Tests invoke an already-installed OpenSSL CLI to manufacture ephemeral fixtures. Proxyman's
public documentation informed Apple onboarding; no Proxyman implementation was copied. Before
adding dependencies, review their exact source/transitive licenses and update the inventory,
notices and provenance tests together.

## zlib 1.3.2

Used only for bounded gzip/deflate inspection previews. Zlib license; original notice is
`third_party/licenses/zlib-LICENSE.txt`. Complete unmodified source is retained as
`third_party/zlib-1.3.2.tar.gz`; origin and SHA-256 are in `third_party/manifest.json`.
