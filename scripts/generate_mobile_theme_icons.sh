#!/bin/bash

set -euo pipefail

repository="$(cd "$(dirname "$0")/.." && pwd)"
assets="$repository/Sources/ThreadingMobile/Assets.xcassets"
renders="$(mktemp -d /tmp/threading-mobile-icons.XXXXXX)"
trap 'rm -rf "$renders"' EXIT

"$repository/scripts/generate_mobile_app_icon.swift"

# The phone grid, not the Dock's: the ground to every edge, no plate, no shadow, the mark on the
# iOS safe zone — iOS masks the tile itself and draws nothing under it, so anything the Dock
# form puts in its margin would end up inside the squircle.
#
# THREADING_MOBILE_ICON_OUTPUT_DIR tells the project's Enforce Repository Boundaries phase that
# this is the icon-generation build, which skips the architecture lint for it.
THREADING_MOBILE_ICON_OUTPUT_DIR="$assets" \
  THREADING_RENDER_OUT="$renders" \
  xcodebuild test \
    -project "$repository/Threading.xcodeproj" \
    -scheme Threading \
    -destination 'platform=macOS' \
    -only-testing:ThreadingTests/AppIconRenderTests/testRendersThePhoneIconUnderEveryStockStyle \
    THREADING_MOBILE_ICON_OUTPUT_DIR="$assets" \
    CODE_SIGNING_ALLOWED=NO

"$repository/scripts/package_mobile_app_icons.swift" "$renders/phone" "$assets"

echo "Generated primary and theme-matched iOS app icons in $assets"
