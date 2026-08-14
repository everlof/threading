#!/usr/bin/env swift

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
    .init(id: "pure-black", suffix: "PureBlack"),
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

private enum PackagingError: Error, CustomStringConvertible {
    case usage
    case invalidImage(String)
    case missingRender(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: package_mobile_app_icons.swift <render-directory> <asset-catalog>"
        case .invalidImage(let path):
            return "could not decode rendered icon: \(path)"
        case .missingRender(let id):
            return "missing rendered Mac icon for theme: \(id)"
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
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = raster.representation(using: .png, properties: [:]) else {
        throw PackagingError.invalidImage("PNG \(side)")
    }
    return data
}

/// Makes the Dock renderer's theme ground full-bleed. The mark, corner treatment and themed
/// glow remain byte-for-byte the Mac renderer's output; iOS then supplies the outer mask.
private func fullBleedImage(at url: URL) throws -> NSImage {
    let data = try Data(contentsOf: url)
    guard let sourceRaster = NSBitmapImageRep(data: data),
          let source = NSImage(data: data),
          let ground = sourceRaster.colorAt(
            x: Int(CGFloat(sourceRaster.pixelsWide) * 0.13),
            y: sourceRaster.pixelsHigh / 2
          ) else {
        throw PackagingError.invalidImage(url.path)
    }
    let side: CGFloat = 1024
    return NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
        ground.setFill()
        bounds.fill()
        source.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        return true
    }
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

    let primary = try fullBleedImage(at: primaryURL)
    try pngData(primary, side: 1024).write(
        to: iconSet.appendingPathComponent("AppIcon-1024.png"),
        options: .atomic
    )
    var iconEntries: [[String: Any]] = [[
        "filename": "AppIcon-1024.png",
        "idiom": "universal",
        "platform": "ios",
        "size": "1024x1024",
    ]]

    if manager.fileExists(atPath: dark.path) {
        try pngData(try fullBleedImage(at: dark), side: 1024).write(
            to: iconSet.appendingPathComponent("AppIcon-1024-dark.png"),
            options: .atomic
        )
        iconEntries.append([
            "appearances": [["appearance": "luminosity", "value": "dark"]],
            "filename": "AppIcon-1024-dark.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        ])
    }
    try writeContents(images: iconEntries, to: iconSet)

    let previewFilename = "AppIconPreview\(theme.suffix)-256.png"
    try pngData(primary, side: 256).write(
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
