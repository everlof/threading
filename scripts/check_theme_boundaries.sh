#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
policy="$repo_root/config/theme-boundary.json"
source_file="$script_dir/theme_boundary_lint.swift"

swiftc_path="$(xcrun --find swiftc)"
toolchain_root="${swiftc_path%/usr/bin/swiftc}"
host_libs="$toolchain_root/usr/lib/swift/host"

cache_root="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}/threading-theme-boundary-${UID}}"
mkdir -p "$cache_root"
binary="$cache_root/theme-boundary-lint"

if [[ ! -x "$binary" || "$source_file" -nt "$binary" ]]; then
    xcrun swiftc \
        -I "$host_libs" \
        -L "$host_libs" \
        -lSwiftSyntax \
        -lSwiftParser \
        "$source_file" \
        -o "$binary"
fi

DYLD_LIBRARY_PATH="$host_libs${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    "$binary" "$repo_root" "$policy"

guidance='docs/THEME_BOUNDARY.md'
for agent_file in "$repo_root/AGENTS.md" "$repo_root/CLAUDE.md"; do
    if ! grep -Fq "$guidance" "$agent_file"; then
        echo "${agent_file#$repo_root/}: error: agent guidance must point to $guidance" >&2
        exit 1
    fi
done

"$script_dir/chrome_reference.py" validate
"$script_dir/check_localization_boundaries.sh"
