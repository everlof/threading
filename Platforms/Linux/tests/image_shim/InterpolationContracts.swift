import AppKit
import Foundation

@main
struct InterpolationContracts {
    static func image() -> NSImage {
        NSImage(rgba: [255, 0, 0, 255,   0, 255, 0, 255,
                       0, 0, 255, 255,   0, 0, 0, 0], width: 2, height: 2)!
    }

    static func checkerImage() -> NSImage {
        var pixels: [UInt8] = []
        for y in 0..<8 {
            for x in 0..<8 {
                let value: UInt8 = (x + y).isMultiple(of: 2) ? 255 : 0
                pixels.append(contentsOf: [value, value, value, 255])
            }
        }
        return NSImage(rgba: pixels, width: 8, height: 8)!
    }

    static func render(_ label: String, source: NSRect, destination: NSRect,
                       contextInterpolation: NSImageInterpolation = .default,
                       hint: Any? = nil,
                       artwork: NSImage? = nil,
                       operation: NSGraphicsContext.CompositingOperation = .sourceOver,
                       fraction: CGFloat = 1) {
        let bitmap = Bitmap(width: 12, height: 12, background: (0.2, 0.4, 0.6, 1))
        let context = NSGraphicsContext(bitmap: bitmap, scale: 1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.imageInterpolation = contextInterpolation
        let hints: [NSImageRep.HintKey: Any]? = hint.map { [.interpolation: $0] }
        (artwork ?? image()).draw(in: destination, from: source, operation: operation,
                     fraction: fraction, respectFlipped: true, hints: hints)
        NSGraphicsContext.current = previous
        if CommandLine.arguments.count > 1 {
            try! PNGWriter.write(bitmap, to: URL(fileURLWithPath: CommandLine.arguments[1])
                .appendingPathComponent("shim-\(label).png"))
        }
        let points = [(3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (8, 8),
                      (5, 3), (8, 3), (3, 7), (4, 8)]
        let pixels = points.map { x, y -> String in
            let offset = (y * bitmap.width + x) * 4
            return "\(x),\(y):\(bitmap.pixels[offset]),\(bitmap.pixels[offset + 1]),\(bitmap.pixels[offset + 2]),\(bitmap.pixels[offset + 3])"
        }
        print("\(label) \(pixels.joined(separator: " "))")
    }

    static func main() {
        precondition(NSImageInterpolation.default.rawValue == 0)
        precondition(NSImageInterpolation.none.rawValue == 1)
        precondition(NSImageInterpolation.low.rawValue == 2)
        precondition(NSImageInterpolation.high.rawValue == 3)
        precondition(NSImageInterpolation.medium.rawValue == 4)

        let state = NSGraphicsContext(bitmap: Bitmap(width: 1, height: 1), scale: 1)
        precondition(state.imageInterpolation == .default)
        state.saveGraphicsState()
        state.imageInterpolation = .none
        precondition(state.imageInterpolation == .none)
        state.restoreGraphicsState()
        precondition(state.imageInterpolation == .default)

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
        render("sourceCrop", source: NSRect(x: 1, y: 1, width: 1, height: 1),
               destination: destination, hint: NSImageInterpolation.none)
        render("copyHalf", source: full, destination: destination,
               hint: NSImageInterpolation.none, operation: .copy, fraction: 0.5)
        render("downsample", source: .zero, destination: NSRect(x: 3, y: 3, width: 2, height: 2),
               hint: NSImageInterpolation.high, artwork: checkerImage())
    }
}
