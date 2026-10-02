import AppKit
import Foundation

@MainActor private func require(_ condition: @autoclosure () -> Bool, _ reason: String) {
    precondition(condition(), "floating glyph: \(reason)")
}

@MainActor private func render(_ glyph: ThemedFloatingGlyphView,
                               scale: CGFloat = 2) -> Bitmap {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    glyph.frame = NSRect(x: 6, y: 6, width: 16, height: 16)
    root.addSubview(glyph)
    let bitmap = Bitmap(width: Int(28 * scale), height: Int(28 * scale),
                        background: (1, 1, 1, 1))
    root.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
    return bitmap
}

private func paintedPixels(_ bitmap: Bitmap) -> [(Int, Int)] {
    var answer: [(Int, Int)] = []
    for y in 0..<bitmap.height {
        for x in 0..<bitmap.width {
            let offset = (y * bitmap.width + x) * 4
            if bitmap.pixels[offset] < 245 || bitmap.pixels[offset + 1] < 245
                || bitmap.pixels[offset + 2] < 245 { answer.append((x, y)) }
        }
    }
    return answer
}

@MainActor private func renderClassic(_ style: ThemedFloatingGlyphView.ClassicGlyph,
                                      name: String, output: URL) throws -> Bitmap {
    let glyph = ThemedFloatingGlyphView(systemSymbolName: "fixture.symbol",
                                        classicGlyph: style, pointSize: 14,
                                        accessibilityDescription: name)
    glyph.tintColor = NSColor(red: 0.12, green: 0.23, blue: 0.52, alpha: 1)
    require(glyph.semanticDescription == name, "semantic description lost")
    require(!glyph.isAccessibilityElement(), "decorative glyph became accessible")
    require(glyph.intrinsicContentSize == NSSize(width: 14, height: 14),
            "intrinsic size is not the authored point size")
    let bitmap = render(glyph)
    let ink = paintedPixels(bitmap)
    require(ink.count >= 8, "\(name) produced no meaningful pixels")
    require(ink.allSatisfy { (8..<48).contains($0.0) && (8..<48).contains($0.1) },
            "\(name) escaped its 16-point slot")
    try PNGWriter.write(bitmap, to: output.appendingPathComponent("\(name).png"))
    return bitmap
}

@MainActor private func testPathState() {
    let bitmap = Bitmap(width: 20, height: 20, background: (1, 1, 1, 1))
    let graphics = NSGraphicsContext(bitmap: bitmap, scale: 1)
    let context = graphics.cgContext
    context.setShouldAntialias(false)
    context.setStrokeColor(NSColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor)
    context.setLineWidth(1)
    context.move(to: CGPoint(x: 3, y: 3))
    context.addLine(to: CGPoint(x: 3, y: 15))
    context.saveGState()
    context.setStrokeColor(NSColor(red: 0, green: 0, blue: 1, alpha: 1).cgColor)
    context.setShouldAntialias(true)
    context.restoreGState()
    require(!graphics.shouldAntialias, "saved antialias mode did not restore")
    context.addLine(to: CGPoint(x: 15, y: 15))
    context.strokePath()
    let before = bitmap.pixels
    context.strokePath()
    require(bitmap.pixels == before, "stroke did not consume the current path")
    func rgb(_ x: Int, _ y: Int) -> [UInt8] {
        let offset = (y * 20 + x) * 4
        return Array(bitmap.pixels[offset..<(offset + 3)])
    }
    require(rgb(2, 10) == [255, 0, 0], "saved stroke ink did not restore")
    require(rgb(10, 5) == [255, 255, 255], "open path was closed while stroking")
    require((1...5).allSatisfy { rgb($0, 10) != [0, 0, 255] }, "nested ink leaked")
}

@main struct FloatingGlyphHarness {
    @MainActor static func main() throws {
        require(CommandLine.arguments.count == 2, "usage: FloatingGlyphHarness OUTPUT_DIRECTORY")
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        AppThemePalette.glyphStyle = .classic
        let glyphs: [(String, ThemedFloatingGlyphView.ClassicGlyph)] = [
            ("folder", .folder), ("branch", .branch), ("handoff", .handoff),
            ("status", .status), ("changes", .changes), ("model", .model),
            ("plan", .plan), ("speed", .speed), ("workspace", .workspace)
        ]
        var signatures = Set<String>()
        for (name, style) in glyphs {
            let bitmap = try renderClassic(style, name: name, output: output)
            signatures.insert(bitmap.pixels.map { String($0, radix: 16) }.joined())
        }
        require(signatures.count == glyphs.count, "two semantic marks drew identically")

        AppThemePalette.glyphStyle = .system
        let system = ThemedFloatingGlyphView(systemSymbolName: "fixture.symbol",
                                             classicGlyph: .folder,
                                             accessibilityDescription: "system")
        let systemBitmap = render(system)
        require(paintedPixels(systemBitmap).count >= 40, "system template path drew no ink")
        try PNGWriter.write(systemBitmap, to: output.appendingPathComponent("system.png"))
        testPathState()
        print("floating glyph: nine classic marks, system template, path state pass")
    }
}
