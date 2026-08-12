#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
binary="${1:-${repository_directory}/ThirdParty/scc/scc}"
readonly EXPECTED_VERSION="scc version 3.7.0"

[[ -x "$binary" ]] || {
    echo "error: bundled scc is missing or not executable: $binary" >&2
    exit 1
}

architectures="$(/usr/bin/lipo -archs "$binary")"
for required in arm64 x86_64; do
    [[ " $architectures " == *" $required "* ]] || {
        echo "error: bundled scc is missing $required: $architectures" >&2
        exit 1
    }
done

version="$($binary --version 2>&1)"
[[ "$version" == "$EXPECTED_VERSION" ]] || {
    echo "error: bundled scc answered '$version', expected '$EXPECTED_VERSION'" >&2
    exit 1
}

echo "Verified bundled $EXPECTED_VERSION ($architectures)."
