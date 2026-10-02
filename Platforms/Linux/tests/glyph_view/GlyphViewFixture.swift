import AppKit
import Foundation

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("GlyphView contract: \(message)") }
}

private struct InkBounds {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

@MainActor
private func inkBounds(_ bitmap: Bitmap) -> InkBounds? {
    var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
    for y in 0..<bitmap.height {
        for x in 0..<bitmap.width {
            let offset = (y * bitmap.width + x) * 4
            let pixel = bitmap.pixels[offset..<(offset + 4)]
            if pixel.elementsEqual([255, 255, 255, 255]) { continue }
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return InkBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
}

@MainActor
private func render(
    _ image: NSImage,
    tint: NSColor,
    slot: NSSize? = nil,
    scale: CGFloat,
    to url: URL
) throws -> (Bitmap, GlyphView) {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    let glyph = GlyphView()
    glyph.image = image
    glyph.tint = tint
    glyph.slot = slot
    glyph.frame = NSRect(x: 3.25, y: 4.25, width: 18, height: 18)
    glyph.translatesAutoresizingMaskIntoConstraints = true
    root.addSubview(glyph)

    let bitmap = Bitmap(width: Int(root.frame.width * scale),
                        height: Int(root.frame.height * scale),
                        background: (1, 1, 1, 1))
    let context = NSGraphicsContext(bitmap: bitmap, scale: scale)
    NSGraphicsContext.current = context
    root.render(in: context)
    NSGraphicsContext.current = nil
    try PNGWriter.write(bitmap, to: url)
    return (bitmap, glyph)
}

@MainActor
private func renderImageView(
    _ image: NSImage,
    tint: NSColor,
    scaling: NSImageScaling,
    frame: NSRect,
    scale: CGFloat,
    to url: URL
) throws -> (Bitmap, NSImageView) {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    let view = NSImageView(frame: frame)
    view.image = image
    view.imageScaling = scaling
    view.contentTintColor = tint
    root.addSubview(view)
    let bitmap = Bitmap(width: Int(root.frame.width * scale),
                        height: Int(root.frame.height * scale),
                        background: (1, 1, 1, 1))
    let context = NSGraphicsContext(bitmap: bitmap, scale: scale)
    NSGraphicsContext.current = context
    root.render(in: context)
    NSGraphicsContext.current = nil
    try PNGWriter.write(bitmap, to: url)
    return (bitmap, view)
}

@main
struct GlyphViewHarness {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("usage: GlyphViewHarness OUTPUT_DIRECTORY")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let opaqueBlack = [UInt8](repeating: 0, count: 9 * 9 * 4).enumerated().map {
            $0.offset % 4 == 3 ? UInt8(255) : $0.element
        }
        guard let template = NSImage(rgba: opaqueBlack, width: 9, height: 9,
                                     size: NSSize(width: 9, height: 9)) else {
            fatalError("fixture image was rejected")
        }
        template.isTemplate = true
        let red = NSColor(red: 1, green: 0, blue: 0, alpha: 1)
        for (scale, expectedSide) in [(CGFloat(1), 8), (CGFloat(2), 17)] {
            let (bitmap, glyph) = try render(
                template, tint: red, scale: scale,
                to: output.appendingPathComponent("template-\(Int(scale))x.png")
            )
            require(!glyph.isAccessibilityElement(), "decorative glyph is accessible")
            require(glyph.intrinsicContentSize == NSSize(width: 9, height: 9),
                    "uncapped intrinsic size changed")
            guard let ink = inkBounds(bitmap) else { fatalError("template rendered no ink") }
            require(ink.width == expectedSide && ink.height == expectedSide,
                    "\(Int(scale))x template edges are not inset to device pixels: \(ink)")
            for index in stride(from: 0, to: bitmap.pixels.count, by: 4) {
                let pixel = Array(bitmap.pixels[index..<(index + 4)])
                require(pixel == [255, 255, 255, 255] || pixel == [255, 0, 0, 255],
                        "\(Int(scale))x template has a soft or incorrectly tinted edge: \(pixel)")
            }
        }

        let opaqueGreen = Array(repeating: [UInt8(0), UInt8(200), UInt8(20), UInt8(255)], count: 8).flatMap { $0 }
        guard let artwork = NSImage(rgba: opaqueGreen, width: 4, height: 2,
                                    size: NSSize(width: 20, height: 10)) else {
            fatalError("fixture artwork was rejected")
        }
        let (bitmap, glyph) = try render(
            artwork, tint: red, slot: NSSize(width: 10, height: 10), scale: 2,
            to: output.appendingPathComponent("artwork-2x.png")
        )
        require(glyph.intrinsicContentSize == NSSize(width: 10, height: 10),
                "slot cap did not bound intrinsic size")
        guard let ink = inkBounds(bitmap) else { fatalError("artwork rendered no ink") }
        require(abs(Double(ink.width) / Double(ink.height) - 2) < 0.35,
                "capped artwork lost its 2:1 aspect ratio: \(ink)")
        let centreX = (ink.minX + ink.maxX) / 2
        let centreY = (ink.minY + ink.maxY) / 2
        let centre = (centreY * bitmap.width + centreX) * 4
        require(bitmap.pixels[centre] < 20 && bitmap.pixels[centre + 1] > 150
                && bitmap.pixels[centre + 2] < 40,
                "non-template artwork was stained by tint")

        let halfRed = NSColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        for scale in [CGFloat(1), CGFloat(2)] {
            let (pixels, imageView) = try renderImageView(
                template, tint: halfRed, scaling: .scaleProportionallyDown,
                frame: NSRect(x: 5, y: 5, width: 17, height: 17), scale: scale,
                to: output.appendingPathComponent("image-view-template-\(Int(scale))x.png")
            )
            require(!imageView.isAccessibilityElement(), "decorative image view is accessible")
            require(imageView.intrinsicContentSize == NSSize(width: 9, height: 9),
                    "image view intrinsic size does not follow the image")
            guard let drawn = inkBounds(pixels) else { fatalError("image view rendered no template") }
            require(drawn.width == Int(9 * scale) && drawn.height == Int(9 * scale),
                    "proportional-down image view enlarged or distorted the image: \(drawn)")
            let center = ((drawn.minY + drawn.maxY) / 2 * pixels.width
                          + (drawn.minX + drawn.maxX) / 2) * 4
            require(pixels.pixels[center] == 255 && (126...129).contains(Int(pixels.pixels[center + 1]))
                    && (126...129).contains(Int(pixels.pixels[center + 2])),
                    "template alpha tint did not composite over the ground")
        }
        let (imagePixels, imageView) = try renderImageView(
            artwork, tint: red, scaling: .scaleProportionallyDown,
            frame: NSRect(x: 5, y: 5, width: 10, height: 10), scale: 2,
            to: output.appendingPathComponent("image-view-artwork-2x.png")
        )
        guard let drawn = inkBounds(imagePixels) else { fatalError("image view rendered no artwork") }
        require(abs(Double(drawn.width) / Double(drawn.height) - 2) < 0.35,
                "image view distorted the artwork aspect ratio: \(drawn)")
        let pixel = ((drawn.minY + drawn.maxY) / 2 * imagePixels.width
                     + (drawn.minX + drawn.maxX) / 2) * 4
        require(imagePixels.pixels[pixel] < 20 && imagePixels.pixels[pixel + 1] > 150
                && imagePixels.pixels[pixel + 2] < 40,
                "image view tinted non-template artwork")
        imageView.image = nil
        require(imageView.intrinsicContentSize == .zero, "empty image view kept stale intrinsic size")
        print("PASS real GlyphView and NSImageView: 1x/2x alignment, template alpha tint, artwork color/aspect and intrinsic size")
    }
}
