#!/usr/bin/env swift
//
// Draws ThreadingMobile's app icon.
//
// The phone app had `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` set and no asset catalog at
// all, so it shipped the blank placeholder. This produces the one asset that fixes it.
//
// Committed rather than generated at build time — an app icon is not allowed to depend on a
// toolchain being present — but generated rather than drawn, so the mark is the *same* mark the
// Mac draws and the two cannot drift by hand.
//
//   scripts/generate_mobile_app_icon.swift
//
// Writes Sources/ThreadingMobile/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png.
//
// **iOS masks the icon itself**, so this draws a full-bleed square with no corner rounding and
// no shadow — the opposite of `GeneratedAppIcon`, which draws both because the Dock does neither
// for a runtime icon.

import AppKit

// MARK: - Geometry

/// The chevron, restated from `GeneratedAppIcon.Layout`.
///
/// Duplicated deliberately: this script is not part of the app target, and the alternative —
/// hoisting five fractions into `ThreadingRemoteKit` so a Foundation-only wire package could carry
/// icon geometry — puts the numbers somewhere less obvious than either place that uses them.
/// `AppIconGeometryTests` pins the two against each other so the duplication cannot drift.
enum Mark {
    static let side: CGFloat = 1024

    static let strokeRatio: CGFloat = 0.14
    static let armX: CGFloat = 0.385
    static let armTopY: CGFloat = 0.755
    static let armBottomY: CGFloat = 0.245
    static let apexY: CGFloat = 0.5
    /// The round-join apex; the phone's mark is always round-joined, matching the shipped
    /// `AppIcon.icon` document rather than any one theme's material.
    static let apexX: CGFloat = 0.615
}

/// The colours of the shipped macOS `AppIcon.icon` document, read out of its `icon.json`.
enum Ink {
    static let chevronTop = NSColor(srgbRed: 0.90644, green: 0.0, blue: 1.0, alpha: 1)
    static let chevronBottom = NSColor(srgbRed: 0.36248, green: 0.50541, blue: 0.93024, alpha: 1)
    static let plateTop = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    static let plateBottom = NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1)
}

// MARK: - Drawing

func drawIcon() -> Data? {
    let side = Int(Mark.side)
    guard let raster = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side,
        pixelsHigh: side,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    raster.size = NSSize(width: Mark.side, height: Mark.side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: raster)

    let bounds = NSRect(x: 0, y: 0, width: Mark.side, height: Mark.side)
    NSGradient(starting: Ink.plateBottom, ending: Ink.plateTop)?
        .draw(in: bounds, angle: 90)

    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: Mark.side * x, y: Mark.side * y)
    }

    let chevron = NSBezierPath()
    chevron.move(to: point(Mark.armX, Mark.armTopY))
    chevron.line(to: point(Mark.apexX, Mark.apexY))
    chevron.line(to: point(Mark.armX, Mark.armBottomY))
    chevron.lineWidth = Mark.side * Mark.strokeRatio
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round

    // The gradient belongs to the stroke, not to the tile, so the stroked path is turned into a
    // fillable outline and clipped — `NSGradient` cannot stroke.
    NSGraphicsContext.saveGraphicsState()
    let stroked = chevron.cgPath.copy(
        strokingWithWidth: chevron.lineWidth,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 10
    )
    let outline = NSBezierPath(cgPath: stroked)
    outline.addClip()
    NSGradient(starting: Ink.chevronBottom, ending: Ink.chevronTop)?
        .draw(in: outline.bounds, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return raster.representation(using: .png, properties: [:])
}

// MARK: - Output

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconSet = repository
    .appendingPathComponent("Sources/ThreadingMobile/Assets.xcassets/AppIcon.appiconset")

guard let png = drawIcon() else {
    FileHandle.standardError.write(Data("failed to draw the icon\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
let destination = iconSet.appendingPathComponent("AppIcon-1024.png")
try png.write(to: destination)
print("Wrote \(destination.path)")
