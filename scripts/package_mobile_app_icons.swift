#!/usr/bin/env swift
//
// Packages the phone-grid renders `AppIconRenderTests.testRendersThePhoneIconUnderEveryStockStyle`
// writes into ThreadingMobile's asset catalogue: one alternate app-icon set and one Settings
// preview per stock style.
//
// The render is already the tile iOS compiles — the theme's ground to every edge, no rounding
// and no shadow, the mark on the platform's safe zone — so nothing here recomposes it. The 1024
// bytes are copied through untouched and the preview is the same picture at 256.
//
//   scripts/package_mobile_app_icons.swift <phone-render-directory> <asset-catalog>

import AppKit

private struct ThemeIcon {
    let id: String
    let suffix: String
}

private let themes: [ThemeIcon] = [
    .init(id: "threading", suffix: "Threading"),
    .init(id: "editorial", suffix: "Editorial"),
    .init(id: "cyberpunk", suffix: "Cyberpunk"),
    .init(id: "swiss-minimalist", suffix: "SwissMinimalist"),
    .init(id: "bauhaus", suffix: "Bauhaus"),
    .init(id: "art-deco", suffix: "ArtDeco"),
    .init(id: "neo-brutalism", suffix: "NeoBrutalism"),
    .init(id: "claymorphism", suffix: "Claymorphism"),
    .init(id: "vaporwave", suffix: "Vaporwave"),
    .init(id: "newsprint", suffix: "Newsprint"),
    .init(id: "botanical", suffix: "Botanical"),
    .init(id: "industrial", suffix: "Industrial"),
    .init(id: "pure", suffix: "Pure"),
    .init(id: "cappuccino", suffix: "Cappuccino"),
    .init(id: "solarized", suffix: "Solarized"),
    .init(id: "nord", suffix: "Nord"),
    .init(id: "dracula", suffix: "Dracula"),
    .init(id: "platinum-9", suffix: "Platinum"),
    .init(id: "aqua-cheetah", suffix: "Aqua"),
    .init(id: "aqua-tiger", suffix: "Tiger"),
    .init(id: "beos-r5", suffix: "BeOS"),
    .init(id: "openstep-42", suffix: "OpenStep"),
    .init(id: "irix-indigo-magic", suffix: "IRIX"),
    .init(id: "amiga-workbench-31", suffix: "Amiga"),
    .init(id: "retro-98", suffix: "Windows98"),
    .init(id: "tui", suffix: "TUI"),
    .init(id: "classic-player", suffix: "ClassicPlayer"),
    .init(id: "christmas", suffix: "Christmas"),
]

/// The side iOS compiles an app icon from, and the side the render test writes.
private let iconSide = 1024
/// The Settings picker's preview.
private let previewSide = 256

private enum PackagingError: Error, CustomStringConvertible {
    case usage
    case invalidImage(String)
    case missingRender(String)
    case wrongSize(String, Int, Int)

    var description: String {
        switch self {
        case .usage:
            return "usage: package_mobile_app_icons.swift <phone-render-directory> <asset-catalog>"
        case .invalidImage(let path):
            return "could not decode rendered icon: \(path)"
        case .missingRender(let id):
            return "missing rendered phone icon for theme: \(id)"
        case .wrongSize(let path, let width, let height):
            return "rendered phone icon is \(width)×\(height), not \(iconSide)×\(iconSide): \(path)"
        }
    }
}

private func replaceDirectory(_ url: URL) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: url.path) {
        try manager.removeItem(at: url)
    }
    try manager.createDirectory(at: url, withIntermediateDirectories: true)
}

/// A phone render, decoded and held to the size iOS compiles.
private func phoneRender(at url: URL) throws -> (bytes: Data, image: NSImage) {
    let bytes = try Data(contentsOf: url)
    guard let raster = NSBitmapImageRep(data: bytes), let image = NSImage(data: bytes) else {
        throw PackagingError.invalidImage(url.path)
    }
    guard raster.pixelsWide == iconSide, raster.pixelsHigh == iconSide else {
        throw PackagingError.wrongSize(url.path, raster.pixelsWide, raster.pixelsHigh)
    }
    return (bytes, image)
}

private func pngData(_ image: NSImage, side: Int) throws -> Data {
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
    ) else {
        throw PackagingError.invalidImage("bitmap \(side)")
    }
    raster.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: raster)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = raster.representation(using: .png, properties: [:]) else {
        throw PackagingError.invalidImage("PNG \(side)")
    }
    return data
}

private func writeContents(images: [[String: Any]], to directory: URL) throws {
    let contents: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: contents,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: directory.appendingPathComponent("Contents.json"), options: .atomic)
}

guard CommandLine.arguments.count == 3 else { throw PackagingError.usage }
let renders = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

for theme in themes {
    let ordinary = renders.appendingPathComponent("appicon-\(theme.id).png")
    let light = renders.appendingPathComponent("appicon-\(theme.id)-light.png")
    let dark = renders.appendingPathComponent("appicon-\(theme.id)-dark.png")
    let manager = FileManager.default
    let primaryURL = manager.fileExists(atPath: light.path) ? light : ordinary
    guard manager.fileExists(atPath: primaryURL.path) else {
        throw PackagingError.missingRender(theme.id)
    }

    let iconSet = assets.appendingPathComponent(
        "AppIconTheme\(theme.suffix).appiconset",
        isDirectory: true
    )
    let previewSet = assets.appendingPathComponent(
        "AppIconPreview\(theme.suffix).imageset",
        isDirectory: true
    )
    try replaceDirectory(iconSet)
    try replaceDirectory(previewSet)

    let primary = try phoneRender(at: primaryURL)
    try primary.bytes.write(
        to: iconSet.appendingPathComponent("AppIcon-\(iconSide).png"),
        options: .atomic
    )
    var iconEntries: [[String: Any]] = [[
        "filename": "AppIcon-\(iconSide).png",
        "idiom": "universal",
        "platform": "ios",
        "size": "\(iconSide)x\(iconSide)",
    ]]

    // An adaptive style ships both luminosities in one alternate set; iOS picks between them.
    if manager.fileExists(atPath: dark.path) {
        try phoneRender(at: dark).bytes.write(
            to: iconSet.appendingPathComponent("AppIcon-\(iconSide)-dark.png"),
            options: .atomic
        )
        iconEntries.append([
            "appearances": [["appearance": "luminosity", "value": "dark"]],
            "filename": "AppIcon-\(iconSide)-dark.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "\(iconSide)x\(iconSide)",
        ])
    }
    try writeContents(images: iconEntries, to: iconSet)

    let previewFilename = "AppIconPreview\(theme.suffix)-\(previewSide).png"
    try pngData(primary.image, side: previewSide).write(
        to: previewSet.appendingPathComponent(previewFilename),
        options: .atomic
    )
    try writeContents(images: [[
        "filename": previewFilename,
        "idiom": "universal",
        "scale": "1x",
    ]], to: previewSet)
}

print("Packaged \(themes.count) mobile theme icons")
