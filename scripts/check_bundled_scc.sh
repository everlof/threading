#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
binary="${1:-${repository_directory}/ThirdParty/scc/scc}"
readonly EXPECTED_VERSION="scc version 3.7.0"
# Threading ships for Apple silicon only (docs/architecture/releasing.md), and the bundled scc is
# the official arm64 release executable rather than a lipo-combined pair — so one slice, exactly.
readonly EXPECTED_ARCHITECTURES="arm64"

[[ -x "$binary" ]] || {
    echo "error: bundled scc is missing or not executable: $binary" >&2
    exit 1
}

architectures="$(/usr/bin/lipo -archs "$binary")"
[[ "$architectures" == "$EXPECTED_ARCHITECTURES" ]] || {
    echo "error: bundled scc must be $EXPECTED_ARCHITECTURES only, found: $architectures" >&2
    exit 1
}

version="$($binary --version 2>&1)"
[[ "$version" == "$EXPECTED_VERSION" ]] || {
    echo "error: bundled scc answered '$version', expected '$EXPECTED_VERSION'" >&2
    exit 1
}

echo "Verified bundled $EXPECTED_VERSION ($architectures)."
