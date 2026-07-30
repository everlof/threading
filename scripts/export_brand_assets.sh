#!/bin/bash

set -euo pipefail

repository="$(cd "$(dirname "$0")/.." && pwd)"
brand="$repository/Brand"
website="$repository/web/public"
mac_icon_assets="$repository/Sources/Threading/AppIcon.icon/Assets"
mobile_icon="$repository/Sources/ThreadingMobile/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

command -v rsvg-convert >/dev/null 2>&1 || {
  echo "rsvg-convert is required (brew install librsvg)" >&2
  exit 1
}

mkdir -p "$website" "$mac_icon_assets" "$(dirname "$mobile_icon")"

cp "$brand/ThreadingMark.svg" "$website/threading-mark.svg"
cp "$brand/ThreadingMarkMono.svg" "$website/threading-mark-mono.svg"

rsvg-convert --width 1024 --height 1024 \
  --output "$brand/ThreadingMark-1024.png" \
  "$brand/ThreadingMark.svg"
rsvg-convert --width 1024 --height 1024 \
  --background-color '#07172b' \
  --output "$brand/ThreadingMark-Navy-1024.png" \
  "$brand/ThreadingMark.svg"
rsvg-convert --width 1024 --height 1024 \
  --output "$brand/ThreadingMarkMono-1024.png" \
  "$brand/ThreadingMarkMono.svg"

cp "$brand/ThreadingMark-1024.png" "$website/threading-mark-1024.png"
cp "$brand/ThreadingMark-Navy-1024.png" "$website/threading-mark-navy-1024.png"
cp "$brand/ThreadingMarkMono-1024.png" "$website/threading-mark-mono-1024.png"
cp "$brand/ThreadingMark-Navy-1024.png" "$website/threading-icon.png"

rsvg-convert --width 180 --height 180 \
  --background-color '#07172b' \
  --output "$website/threading-apple-touch-icon.png" \
  "$brand/ThreadingMark.svg"
rsvg-convert --width 1200 --height 630 \
  --output "$website/og.png" \
  "$brand/ThreadingSocialCard.svg"

cp "$brand/ThreadingMark-1024.png" "$mac_icon_assets/Threading Mark.png"
cp "$brand/ThreadingMark-Navy-1024.png" "$mobile_icon"

echo "Exported Threading brand assets."
