#!/usr/bin/env bash

# Reproduces the checked-in universal scc helper from the two pinned official release archives.
# This is a maintainer operation, never a build step: normal builds and installed apps perform no
# download and do not rely on Homebrew or another package manager.
set -euo pipefail

readonly VERSION="3.7.0"
readonly ARM_ARCHIVE_SHA256="376cbae670be59ee64f398de20e0694ec434bf8a9b842642952b0ab0be5f3961"
readonly X86_ARCHIVE_SHA256="c3f7457856b9169ccb3c1dd14198e67f730bee065f24d9051bf52cdc2a719ecc"
readonly UNIVERSAL_SHA256="0a41a621edc697b888b92c424ffea37e82f7c06db85bbae0c10ee19236dc1d9f"

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
destination="${repository_directory}/ThirdParty/scc/scc"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/threading-scc.XXXXXX")"

cleanup() {
    find "$scratch" -depth -delete
}
trap cleanup EXIT

download_slice() {
    local architecture="$1"
    local expected_sha256="$2"
    local archive="$scratch/scc-${architecture}.tar.gz"
    local extracted="$scratch/${architecture}"
    local url="https://github.com/boyter/scc/releases/download/v${VERSION}/scc_Darwin_${architecture}.tar.gz"

    /usr/bin/curl --fail --location --silent --show-error "$url" --output "$archive"
    local actual_sha256
    actual_sha256="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
    [[ "$actual_sha256" == "$expected_sha256" ]] || {
        echo "error: $architecture archive checksum was $actual_sha256, expected $expected_sha256" >&2
        exit 1
    }

    /bin/mkdir -p "$extracted"
    /usr/bin/tar -xzf "$archive" -C "$extracted" scc LICENSE
    [[ -x "$extracted/scc" ]] || {
        echo "error: $url did not contain an executable scc" >&2
        exit 1
    }
}

download_slice arm64 "$ARM_ARCHIVE_SHA256"
download_slice x86_64 "$X86_ARCHIVE_SHA256"

/usr/bin/lipo -create \
    "$scratch/arm64/scc" \
    "$scratch/x86_64/scc" \
    -output "$scratch/scc"

actual_sha256="$(/usr/bin/shasum -a 256 "$scratch/scc" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha256" == "$UNIVERSAL_SHA256" ]] || {
    echo "error: universal checksum was $actual_sha256, expected $UNIVERSAL_SHA256" >&2
    exit 1
}

/usr/bin/install -m 0755 "$scratch/scc" "$destination"
"$script_directory/check_bundled_scc.sh" "$destination"
echo "Updated $destination from official scc $VERSION release assets."
