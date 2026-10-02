#!/usr/bin/env bash
# Run inside the pinned Linux Swift container; no SwiftPM or Python dependency.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
shim=Platforms/Linux/Sources/AppKit
fixture=Platforms/Linux/tests/image_shim
mkdir -p Platforms/Linux/out/image-interpolation

swiftc -O -swift-version 6 -module-cache-path "$scratch/module-cache" \
  -emit-library -emit-module -module-name AppKit \
  -emit-module-path "$scratch/AppKit.swiftmodule" -o "$scratch/libAppKit.so" \
  "$shim/Exports.swift" "$shim/Geometry.swift" "$shim/NSColor.swift" \
  "$shim/NSBezierPath.swift" "$shim/Raster.swift" "$shim/RasterClip.swift" \
  "$shim/NSGraphicsContext.swift" "$shim/NSImage.swift" \
  "$shim/ImageCompositing.swift" "$shim/PNG.swift" \
  "$fixture/FixtureDependencies.swift"

swiftc -O -swift-version 6 -module-cache-path "$scratch/module-cache" \
  -parse-as-library -I "$scratch" -L "$scratch" -lAppKit \
  -Xlinker -rpath -Xlinker "$scratch" \
  Sources/Threading/UI/Design/TemplateImageDrawing.swift "$fixture/Contracts.swift" \
  -o "$scratch/contracts"
"$scratch/contracts"

swiftc -O -swift-version 6 -module-cache-path "$scratch/module-cache" \
  -parse-as-library -I "$scratch" -L "$scratch" -lAppKit \
  -Xlinker -rpath -Xlinker "$scratch" \
  "$fixture/InterpolationContracts.swift" -o "$scratch/interpolation"
output=$("$scratch/interpolation" Platforms/Linux/out/image-interpolation)
printf '%s\n' "$output"
grep -Fq 'none 3,3:255,0,0,255' <<<"$output"
grep -Fq 'sourceCrop 3,3:0,255,0,255' <<<"$output"
grep -Fq 'copyHalf 3,3:255,0,0,128' <<<"$output"
grep -Fq 'downsample 3,3:51,102,153,255' <<<"$output"
grep -Fq '3,7:128,128,128,255' <<<"$output"
echo 'PASS Linux image interpolation: exact nearest/crop/copy and bounded downsampling'
