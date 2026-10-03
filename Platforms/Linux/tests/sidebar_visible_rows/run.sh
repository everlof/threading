#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
output_dir=$(mktemp -d)
trap 'rm -rf "$output_dir"' EXIT
mkdir -p "$output_dir/module-cache"
swiftc -swift-version 6 -module-cache-path "$output_dir/module-cache" \
    Sources/WindowHarness/SidebarVisibleRows.swift \
    tests/sidebar_visible_rows/Fixture.swift -o "$output_dir/sidebar-visible-rows"
"$output_dir/sidebar-visible-rows"
