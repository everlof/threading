#!/usr/bin/env bash
#
# Publish the Linux components a remote execution host runs, and write the manifest the app
# verifies them against.
#
#   scripts/publish_remote_components.sh              # build, hash, upload, rewrite the manifest
#   scripts/publish_remote_components.sh --no-upload  # everything but the release (for a dry run)
#   scripts/publish_remote_components.sh --skip-build --no-upload  # hash and write from build/linux
#
# What it does, in order:
#   1. builds `threading-ptyd` and `threading-mcp-bridge` for both architectures through
#      scripts/test-ptyd-linux.sh, which also runs the daemon's suite against what it built;
#   2. compresses each binary and measures two digests — the asset that will be downloaded and the
#      binary inside it, which is also its install identifier on a host;
#   3. uploads the assets to a release of their own, tagged by the commit the daemon's sources are
#      at, so a tag names exactly one set of bytes and can never be rewritten to mean another;
#   4. rewrites Sources/Threading/Core/RemoteHost/RemoteHostComponentManifest.swift with what it
#      measured. Those digests are compiled into the app, which is what makes the download safe:
#      the app never trusts the bytes it receives, only the bytes it was built expecting.
#
# The release is separate from the app's own releases on purpose. Components change when the daemon
# does, which is far less often than the app ships, and every app build that carries the same
# manifest shares one cached download on a person's Mac.
#
# See docs/feature-drafts/remote-execution-hosts.md and docs/architecture/releasing.md.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
manifest="${repository_directory}/Sources/Threading/Core/RemoteHost/RemoteHostComponentManifest.swift"
output="${repository_directory}/build/linux"
upload=1
build=1

usage() { sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (( $# > 0 )); do
  case "$1" in
    --no-upload) upload=0; shift ;;
    --skip-build) build=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

# The tag names the sources, not the day: two publications of the same commit are the same bytes.
daemon_sources=(Targets/PTYHost Targets/MCPBridge Packages/ThreadingPTYHostKit Packages/ThreadingDomain)
if ! git -C "${repository_directory}" diff --quiet HEAD -- "${daemon_sources[@]}" \
  || [[ -n "$(git -C "${repository_directory}" ls-files --others --exclude-standard -- "${daemon_sources[@]}")" ]]; then
  echo "publish_remote_components: the component sources differ from HEAD; commit them first" >&2
  exit 65
fi
revision="$(git -C "${repository_directory}" rev-parse HEAD)"
tag="remote-components-${revision:0:12}"

if (( build )); then
  echo "==> building both architectures"
  "${script_directory}/test-ptyd-linux.sh" --arch all
fi

declare -a rows=()
for architecture in arm64 amd64; do
  for executable in threading-ptyd threading-mcp-bridge; do
    binary="${output}/${architecture}/${executable}"
    [[ -f "${binary}" ]] || { echo "publish_remote_components: ${binary} was not built" >&2; exit 70; }
    asset="${output}/${executable}-${architecture}.gz"
    # `-n` so the name and timestamp stay out: the same binary compresses to the same bytes.
    gzip -9 -n -c "${binary}" > "${asset}"

    kind=daemon
    [[ "${executable}" == threading-mcp-bridge ]] && kind=bridge
    rows+=("$(printf '        RemoteHostComponent(\n            kind: .%s,\n            architecture: .%s,\n            assetName: "%s",\n            assetSHA256: "%s",\n            assetByteCount: %s,\n            sha256: "%s"\n        )' \
      "${kind}" "${architecture}" "$(basename "${asset}")" \
      "$(shasum -a 256 "${asset}" | cut -d' ' -f1)" \
      "$(wc -c < "${asset}" | tr -d ' ')" \
      "$(shasum -a 256 "${binary}" | cut -d' ' -f1)")")
    echo "    $(basename "${asset}") $(du -h "${asset}" | cut -f1)"
  done
done

if (( upload )); then
  command -v gh >/dev/null 2>&1 || { echo "publish_remote_components: gh is not installed" >&2; exit 69; }
  echo "==> publishing ${tag}"
  if gh release view "${tag}" --repo everlof/threading >/dev/null 2>&1; then
    echo "publish_remote_components: ${tag} already exists; its assets are immutable" >&2
    exit 65
  fi
  # The tag is created on the remote, so the commit it names must already be there: publish after
  # the push, never before. `--target` pins it to that commit rather than to whatever the default
  # branch's head happens to be when GitHub creates it.
  if ! git -C "${repository_directory}" branch -r --contains "${revision}" | grep -q .; then
    echo "publish_remote_components: ${revision:0:12} is not on any remote branch; push it first" >&2
    exit 65
  fi
  gh release create "${tag}" --repo everlof/threading \
    --target "${revision}" \
    --title "Remote host components ${revision:0:12}" \
    --notes "Linux components for remote execution hosts, built from ${revision}." \
    "${output}"/threading-*-*.gz
fi

echo "==> writing the manifest"
{
  cat <<'HEADER'
// Generated by scripts/publish_remote_components.sh. Do not edit by hand.
//
// Rewritten wholesale each time the Linux components are published: the script builds them, hashes
// what it built, uploads the assets and writes the digests it measured here.

import Foundation

/// The components this build knows how to fetch, and where they live.
///
/// **Generated, not written by hand.** `scripts/publish_remote_components.sh` builds the Linux
/// binaries, uploads them to their own release and rewrites this file with the digests it measured.
/// Compiling the digests in is what makes the download safe to do at all: the app never trusts the
/// bytes it receives, only the bytes it was built expecting.
///
/// Empty in a build that has published none, which is not a failure of the download — it is a build
/// that cannot set up a host, and says so in those words.
enum RemoteHostComponentManifest {

    /// The release tag carrying these assets.
HEADER
  printf '    static let release = "%s"\n\n' "${tag}"
  cat <<'MIDDLE'
    /// Where the assets are, one directory for the release.
    static let baseURL = "https://github.com/everlof/threading/releases/download/"

    static let components: [RemoteHostComponent] = [
MIDDLE
  for index in "${!rows[@]}"; do
    if (( index + 1 < ${#rows[@]} )); then
      printf '%s,\n' "${rows[index]}"
    else
      printf '%s\n' "${rows[index]}"
    fi
  done
  cat <<'FOOTER'
    ]

    static func component(
        _ kind: RemoteHostBinaryKind,
        for architecture: RemoteHostArchitecture
    ) -> RemoteHostComponent? {
        components.first { $0.kind == kind && $0.architecture == architecture }
    }

    static func url(for component: RemoteHostComponent) -> URL? {
        URL(string: baseURL + release + "/" + component.assetName)
    }

    /// What one host costs to set up, for the sentence that asks.
    static func downloadByteCount(for architecture: RemoteHostArchitecture) -> Int {
        components.filter { $0.architecture == architecture }.reduce(0) { $0 + $1.assetByteCount }
    }
}
FOOTER
} > "${manifest}"

echo "publish_remote_components: ${tag} published; commit the regenerated manifest"
