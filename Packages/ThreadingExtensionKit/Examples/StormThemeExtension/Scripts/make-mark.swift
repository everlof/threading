#!/usr/bin/env swift
//
// Draws Storm's app-icon mark: a rain glyph on transparency.
//
//   swift Scripts/make-mark.swift
//
// Writes Resources/storm-mark.png.
//
// **The background stays clear.** Threading draws the icon's plate from this theme's own `ground`
// role and composites the mark on top, and refuses — at package inspection, before the extension
// can be enabled — any mark whose edges are opaque. An opaque rectangle is a tile trying to be
// the whole icon, which is the shape a package would use to make Threading's Dock icon look like
// some other application's.
//
// Generated rather than drawn so the asset in this example is reviewable: a reader can see what
// the shape is without opening a binary, and change it by editing eight numbers.

import AppKit

let side: CGFloat = 1024

enum Mark {
    /// A cloud, as two overlapping discs on a bar.
    static let cloudCentreY: CGFloat = 0.62
    static let cloudLeft = (x: CGFloat(0.36), y: CGFloat(0.62), r: CGFloat(0.115))
    static let cloudRight = (x: CGFloat(0.60), y: CGFloat(0.655), r: CGFloat(0.145))
    static let cloudBar = NSRect(x: 0.30, y: 0.545, width: 0.40, height: 0.15)

    /// Three strokes of rain, falling left to right.
    static let rain: [(x: CGFloat, top: CGFloat, length: CGFloat)] = [
        (x: 0.395, top: 0.50, length: 0.135),
        (x: 0.500, top: 0.465, length: 0.175),
        (x: 0.605, top: 0.50, length: 0.135)
    ]
    static let rainWidth: CGFloat = 0.042
    static let rainSlant: CGFloat = 0.045
}

func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: side * x, y: side * y)
}

func rect(_ r: NSRect) -> NSRect {
    NSRect(x: side * r.minX, y: side * r.minY, width: side * r.width, height: side * r.height)
}

guard let raster = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(side),
    pixelsHigh: Int(side),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }
raster.size = NSSize(width: side, height: side)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: raster)

// Deliberately not filled: the plate is the host's, drawn from this theme's `ground`.
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill(using: .copy)

let cloud = NSBezierPath()
for disc in [Mark.cloudLeft, Mark.cloudRight] {
    cloud.appendOval(in: NSRect(
        x: side * (disc.x - disc.r),
        y: side * (disc.y - disc.r),
        width: side * disc.r * 2,
        height: side * disc.r * 2
    ))
}
let bar = rect(Mark.cloudBar)
cloud.appendRoundedRect(bar, xRadius: bar.height / 2, yRadius: bar.height / 2)

NSColor.white.setFill()
cloud.fill()

for drop in Mark.rain {
    let stroke = NSBezierPath()
    stroke.move(to: point(drop.x, drop.top))
    stroke.line(to: point(drop.x - Mark.rainSlant, drop.top - drop.length))
    stroke.lineWidth = side * Mark.rainWidth
    stroke.lineCapStyle = .round
    NSColor.white.setStroke()
    stroke.stroke()
}

NSGraphicsContext.restoreGraphicsState()

let destination = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/storm-mark.png")
guard let png = raster.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: destination)
print("Wrote \(destination.path)")
