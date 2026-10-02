import AppKit
import Foundation

// A small real-AppKit oracle for the production image calls. Its printed pixels are intended
// for comparing behavior, not byte-identical color management across renderers.
@main
struct MacInterpolationProbe {
    static func image() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 8, bitsPerPixel: 32)!
        rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        rep.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), atX: 1, y: 0)
        rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: 0, y: 1)
        rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: 1, y: 1)
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(rep)
        return image
    }

    static func checkerImage() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 32, bitsPerPixel: 32)!
        for y in 0..<8 {
            for x in 0..<8 {
                let value: CGFloat = (x + y).isMultiple(of: 2) ? 1 : 0
                rep.setColor(NSColor(deviceRed: value, green: value, blue: value, alpha: 1),
                             atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.addRepresentation(rep)
        return image
    }

    static func render(_ label: String, source: NSRect, destination: NSRect,
                       contextInterpolation: NSImageInterpolation = .default,
                       hint: Any? = nil,
                       artwork: NSImage? = nil,
                       operation: NSCompositingOperation = .sourceOver,
                       fraction: CGFloat = 1) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 48, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.imageInterpolation = contextInterpolation
        NSColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 12, height: 12).fill()
        let hints: [NSImageRep.HintKey: Any]? = hint.map { [.interpolation: $0] }
        (artwork ?? image()).draw(in: destination, from: source, operation: operation,
                     fraction: fraction, respectFlipped: true, hints: hints)
        context.flushGraphics()
        NSGraphicsContext.current = previous
        if CommandLine.arguments.count > 1 {
            let path = URL(fileURLWithPath: CommandLine.arguments[1])
                .appendingPathComponent("mac-\(label).png")
            try! rep.representation(using: .png, properties: [:])!.write(to: path)
        }
        let points = [(3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (8, 8),
                      (5, 3), (8, 3), (3, 7), (4, 8)]
        let pixels = points.map { x, y -> String in
            let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return "\(x),\(y):\(Int((color.redComponent * 255).rounded())),\(Int((color.greenComponent * 255).rounded())),\(Int((color.blueComponent * 255).rounded())),\(Int((color.alphaComponent * 255).rounded()))"
        }
        print("\(label) \(pixels.joined(separator: " "))")
    }

    static func main() {
        _ = NSApplication.shared
        print("raw default/none/low/high/medium: \(NSImageInterpolation.default.rawValue)/\(NSImageInterpolation.none.rawValue)/\(NSImageInterpolation.low.rawValue)/\(NSImageInterpolation.high.rawValue)/\(NSImageInterpolation.medium.rawValue)")
        let full = NSRect(x: 0, y: 0, width: 2, height: 2)
        let destination = NSRect(x: 3, y: 3, width: 6, height: 6)
        render("none", source: full, destination: destination, hint: NSImageInterpolation.none)
        render("high", source: full, destination: destination, hint: NSImageInterpolation.high)
        render("highRaw", source: full, destination: destination, hint: NSImageInterpolation.high.rawValue)
        render("contextNone", source: full, destination: destination, contextInterpolation: .none)
        render("contextNoneHighHint", source: full, destination: destination,
               contextInterpolation: .none, hint: NSImageInterpolation.high)
        render("contextHighNoneHint", source: full, destination: destination,
               contextInterpolation: .high, hint: NSImageInterpolation.none)
        render("zeroSource", source: .zero, destination: destination, hint: NSImageInterpolation.none)
        render("sourceCrop", source: NSRect(x: 1, y: 1, width: 1, height: 1), destination: destination, hint: NSImageInterpolation.none)
        render("copyHalf", source: full, destination: destination, hint: NSImageInterpolation.none,
               operation: .copy, fraction: 0.5)
        render("downsample", source: .zero, destination: NSRect(x: 3, y: 3, width: 2, height: 2),
               hint: NSImageInterpolation.high, artwork: checkerImage())
    }
}
