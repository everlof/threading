#!/usr/bin/env bash

# Reproduces the checked-in scc helper from the pinned official arm64 release archive. Threading
# ships for Apple silicon only (docs/architecture/releasing.md), so the bundled executable is the
# official one byte for byte — nothing is patched, rebuilt or lipo-combined.
# This is a maintainer operation, never a build step: normal builds and installed apps perform no
# download and do not rely on Homebrew or another package manager.
set -euo pipefail

readonly VERSION="3.7.0"
readonly ARCHITECTURE="arm64"
readonly ARCHIVE_SHA256="376cbae670be59ee64f398de20e0694ec434bf8a9b842642952b0ab0be5f3961"
readonly EXECUTABLE_SHA256="ecfd9c37119ffe354b96d5cc37b0e5eafaa7f454c5d05566c9ba9ff9da3a57d9"

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
destination="${repository_directory}/ThirdParty/scc/scc"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/threading-scc.XXXXXX")"

cleanup() {
    find "$scratch" -depth -delete
}
trap cleanup EXIT

sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

archive="$scratch/scc-${ARCHITECTURE}.tar.gz"
url="https://github.com/boyter/scc/releases/download/v${VERSION}/scc_Darwin_${ARCHITECTURE}.tar.gz"

/usr/bin/curl --fail --location --silent --show-error "$url" --output "$archive"
actual_sha256="$(sha256 "$archive")"
[[ "$actual_sha256" == "$ARCHIVE_SHA256" ]] || {
    echo "error: archive checksum was $actual_sha256, expected $ARCHIVE_SHA256" >&2
    exit 1
}

/usr/bin/tar -xzf "$archive" -C "$scratch" scc LICENSE
[[ -x "$scratch/scc" ]] || {
    echo "error: $url did not contain an executable scc" >&2
    exit 1
}

actual_sha256="$(sha256 "$scratch/scc")"
[[ "$actual_sha256" == "$EXECUTABLE_SHA256" ]] || {
    echo "error: executable checksum was $actual_sha256, expected $EXECUTABLE_SHA256" >&2
    exit 1
}

/usr/bin/install -m 0755 "$scratch/scc" "$destination"
"$script_directory/check_bundled_scc.sh" "$destination"
echo "Updated $destination from the official scc $VERSION $ARCHITECTURE release asset."
