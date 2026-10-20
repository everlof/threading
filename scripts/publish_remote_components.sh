#!/usr/bin/env bash
#
# Publish the Linux components a remote execution host runs, and write the manifest the app
# verifies them against.
#
#   scripts/publish_remote_components.sh              # build, hash, upload, rewrite the manifest
#   scripts/publish_remote_components.sh --no-upload  # everything but the release (for a dry run)
#   scripts/publish_remote_components.sh --skip-build --no-upload  # hash and write from build/linux
#   scripts/publish_remote_components.sh --check      # required app-release preflight
#
# What it does, in order:
#   1. builds `threading-ptyd` and `threading-mcp-bridge` for both architectures through
#      scripts/test-ptyd-linux.sh, which also runs the daemon's suite against what it built;
#   2. compresses each binary and measures two digests — the asset that will be downloaded and the
#      binary inside it, which is also its install identifier on a host;
#   3. uploads the assets and manifest to their own release, tagged by the commit the inputs are
#      at, so a tag names exactly one set of bytes and can never be rewritten to mean another;
#   4. verifies the public downloads, then writes the measured manifest into
#      Sources/Threading/Core/RemoteHost/RemoteHostComponentManifest.swift. Those digests are
#      compiled into the app: downloads are trusted only when they match that signed pin.
#
# Every app release checks the pinned sources and public downloads. Unchanged component inputs
# reuse their immutable release; changed inputs must be published and the manifest committed
# before the app is tagged. The source inventory includes transitive packages and Linux recipes.
#
# See docs/feature-drafts/remote-execution-hosts.md and docs/architecture/releasing.md.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
manifest="${repository_directory}/Sources/Threading/Core/RemoteHost/RemoteHostComponentManifest.swift"
output="${repository_directory}/build/linux"
repository="${THREADING_REPO:-everlof/threading}"
checker="${script_directory}/check_remote_components.py"
upload=1
build=1

usage() { sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (( $# > 0 )); do
  case "$1" in
    --no-upload) upload=0; shift ;;
    --skip-build) build=0; shift ;;
    --check) exec python3 "${checker}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

# A production upload must run the suites against the exact static binaries it publishes.
if (( upload && ! build )); then
  echo "publish_remote_components: --skip-build requires --no-upload" >&2
  exit 65
fi
revision="$(python3 "${checker}" --source-revision)"
tag="remote-components-${revision:0:12}"
manifest_directory="$(mktemp -d "${TMPDIR:-/tmp}/threading-component-manifest.XXXXXX")"
prepared_manifest="${manifest_directory}/RemoteHostComponentManifest.swift"
trap 'rm -f "${prepared_manifest}"; rmdir "${manifest_directory}"' EXIT

if (( upload )); then
  # The manifest can name an older commit when none of the component inputs changed.
  if python3 "${checker}" --local >/dev/null 2>&1; then
    python3 "${checker}"
    echo "publish_remote_components: reusing the verified component release"
    exit 0
  fi
  command -v gh >/dev/null 2>&1 || { echo "publish_remote_components: gh is not installed" >&2; exit 69; }
  if gh release view "${tag}" --repo "${repository}" >/dev/null 2>&1; then
    # Recover an upload that completed before manifest installation/commit. Never rebuild or
    # overwrite that tag: Swift builds need not reproduce the same bytes on a later invocation.
    gh release download "${tag}" --repo "${repository}" \
      --pattern RemoteHostComponentManifest.swift --output "${prepared_manifest}" --clobber
    python3 "${checker}" --manifest "${prepared_manifest}"
    python3 "${checker}" --assert-snapshot "${revision}"
    cp "${prepared_manifest}" "${manifest}"
    echo "publish_remote_components: recovered ${tag}; commit the regenerated manifest"
    exit 0
  fi
  # Check the actual destination, not possibly stale tracking refs for an unrelated remote.
  remote_revision="$(gh api "repos/${repository}/commits/${revision}" --jq .sha)"
  [[ "${remote_revision}" == "${revision}" ]] || {
    echo "publish_remote_components: ${revision} must be published to ${repository} first" >&2
    exit 65
  }
fi

if (( build )); then
  echo "==> building both architectures"
  MARKETING_VERSION=0.0.0 CURRENT_PROJECT_VERSION=0.0.0 THREADING_SOURCE_REVISION="${revision}" \
    "${script_directory}/test-ptyd-linux.sh" --arch all
fi

declare -a rows=()
declare -a assets=()
for architecture in arm64 amd64; do
  for executable in threading-ptyd threading-mcp-bridge; do
    binary="${output}/${architecture}/${executable}"
    [[ -f "${binary}" ]] || { echo "publish_remote_components: ${binary} was not built" >&2; exit 70; }
    asset="${output}/${executable}-${architecture}.gz"
    # `-n` so the name and timestamp stay out: the same binary compresses to the same bytes.
    gzip -9 -n -c "${binary}" > "${asset}"
    assets+=("${asset}")

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

echo "==> preparing the manifest"
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
  cat <<MIDDLE
    /// Where the assets are, one directory for the release.
    static let baseURL = "https://github.com/${repository}/releases/download/"

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
} > "${prepared_manifest}"

python3 "${checker}" --assert-snapshot "${revision}"
python3 "${checker}" --manifest "${prepared_manifest}" --local
if (( upload )); then
  echo "==> publishing ${tag}"
  # Component releases must never displace the stable app release serving Sparkle's /latest feed.
  gh release create "${tag}" --repo "${repository}" \
    --target "${revision}" --prerelease --latest=false \
    --title "Remote host components ${revision:0:12}" \
    --notes "Linux components for remote execution hosts, built and tested from ${revision}." \
    "${assets[@]}" "${prepared_manifest}"
  # Install the pin only after the same public URLs the app will use pass both digest checks.
  python3 "${checker}" --manifest "${prepared_manifest}"
fi
python3 "${checker}" --assert-snapshot "${revision}"
cp "${prepared_manifest}" "${manifest}"
if (( upload )); then
  echo "publish_remote_components: ${tag} published and verified; commit the regenerated manifest"
else
  echo "publish_remote_components: dry-run manifest written; no assets published"
fi
