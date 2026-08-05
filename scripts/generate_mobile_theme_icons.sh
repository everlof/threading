#!/bin/bash

set -euo pipefail

repository="$(cd "$(dirname "$0")/.." && pwd)"
assets="$repository/Sources/ThreadingMobile/Assets.xcassets"
renders="$(mktemp -d /tmp/threading-mobile-icons.XXXXXX)"
trap 'rm -rf "$renders"' EXIT

"$repository/scripts/generate_mobile_app_icon.swift"

THREADING_MOBILE_ICON_OUTPUT_DIR="$assets" \
  THREADING_RENDER_OUT="$renders" \
  xcodebuild test \
    -project "$repository/Threading.xcodeproj" \
    -scheme Threading \
    -destination 'platform=macOS' \
    -only-testing:ThreadingTests/AppIconRenderTests/testRendersTheIconUnderEveryStockStyle \
    THREADING_MOBILE_ICON_OUTPUT_DIR="$assets" \
    CODE_SIGNING_ALLOWED=NO

"$repository/scripts/package_mobile_app_icons.swift" "$renders" "$assets"

echo "Generated primary and theme-matched iOS app icons in $assets"
