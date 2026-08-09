#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $0 <macos|ios> <Legal directory or .app bundle>" >&2
    exit 64
}

[[ $# -eq 2 ]] || usage

profile="$1"
target_path="$2"

case "$profile" in
    macos|ios) ;;
    *) usage ;;
esac

if [[ -d "$target_path/Contents/Resources/Legal" ]]; then
    legal_directory="$target_path/Contents/Resources/Legal"
elif [[ -d "$target_path/Legal" ]]; then
    legal_directory="$target_path/Legal"
else
    legal_directory="$target_path"
fi

common_notices=(
    "THIRD_PARTY_NOTICES.md"
    "Threading-GPL-3.0.txt"
    "SwiftTerm-MIT.txt"
    "NativeDiffKit-MIT.txt"
    "W95FA-OFL-1.1.txt"
    "W95FA-SOURCE.md"
    "PlatinumBitmap-OFL-1.1.txt"
    "PlatinumBitmap-SOURCE.md"
    "Topaz-GPL-2.0.txt"
    "Topaz-FONT-EXCEPTION.txt"
    "Topaz-UPSTREAM-README.txt"
    "Topaz-SOURCE.md"
)

macos_notices=(
    "BorderBeamKit-MIT.txt"
    "LabelMorph-MIT.txt"
    "ThinkingOrbs-MIT.txt"
    "Sparkle-LICENSE.txt"
    "Sparkle-ed25519-LICENSE.txt"
    "WasmKit-MIT.txt"
    "WasmKit-NOTICE.txt"
    "swift-system-LICENSE.txt"
    "swift-argument-parser-LICENSE.txt"
)

required_notices=("${common_notices[@]}")
if [[ "$profile" == "macos" ]]; then
    required_notices+=("${macos_notices[@]}")
fi

missing_notices=()
for notice in "${required_notices[@]}"; do
    if [[ ! -s "$legal_directory/$notice" ]]; then
        missing_notices+=("$notice")
    fi
done

if (( ${#missing_notices[@]} > 0 )); then
    echo "error: incomplete legal-notice bundle at $legal_directory" >&2
    for notice in "${missing_notices[@]}"; do
        echo "error: missing or empty Legal/$notice" >&2
    done
    exit 1
fi

echo "Verified ${#required_notices[@]} bundled legal notices for $profile."
