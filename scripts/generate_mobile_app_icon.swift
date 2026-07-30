#!/usr/bin/env swift
//
// Installs ThreadingMobile's canonical app icon.
//
// The editable vector master is `Brand/ThreadingMark.svg`; `scripts/export_brand_assets.sh`
// renders the full-bleed navy 1024px PNG once for every consumer. This script deliberately
// copies that checked-in canonical raster instead of restating the mark in a second drawing
// implementation. That makes the website and iOS use the same pixels, including the filled
// center, while still leaving the build independent of librsvg.
//
//   scripts/generate_mobile_app_icon.swift
//
// Writes Sources/ThreadingMobile/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png.
//
// iOS masks the icon itself, so the source is a full-bleed square with no corner rounding or
// shadow—the opposite of `GeneratedAppIcon`, which draws both because the Dock does neither for
// a runtime icon.

import AppKit

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let source = repository.appendingPathComponent("Brand/ThreadingMark-Navy-1024.png")
let iconSet = repository
    .appendingPathComponent("Sources/ThreadingMobile/Assets.xcassets/AppIcon.appiconset")
let destination = iconSet.appendingPathComponent("AppIcon-1024.png")

let png = try Data(contentsOf: source)
guard let raster = NSBitmapImageRep(data: png),
      raster.pixelsWide == 1024,
      raster.pixelsHigh == 1024 else {
    FileHandle.standardError.write(
        Data("Brand/ThreadingMark-Navy-1024.png must be a 1024px PNG\n".utf8)
    )
    exit(1)
}

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
try png.write(to: destination, options: .atomic)
print("Wrote \(destination.path) from \(source.path)")
