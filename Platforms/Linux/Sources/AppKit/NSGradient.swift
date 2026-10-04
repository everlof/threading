import Foundation

/// Bounded linear gradient for the small AppKit chooser well. The raster tree already clips
/// each draw to its view, so one row of flat fill per backing pixel keeps the gradient inside
/// the caller's rounded path without a window-sized intermediate bitmap.
public final class NSGradient {
    private let colors: [NSColor]

    public init?(colors: [NSColor]) {
        guard colors.count >= 2, colors.count <= 16 else { return nil }
        self.colors = colors
    }

    public func draw(in rect: NSRect, angle: CGFloat) {
        precondition(angle == -90 || angle == 90,
                     "Linux NSGradient currently supports vertical chooser gradients")
        guard rect.height > 0, rect.width > 0 else { return }
        let scale = NSGraphicsContext.current?.scale ?? 1
        let rows = min(4096, max(1, Int(ceil(rect.height * scale))))
        for row in 0..<rows {
            let location = (CGFloat(row) + 0.5) / CGFloat(rows)
            let position = (angle == -90 ? location : 1 - location)
                * CGFloat(colors.count - 1)
            let lower = min(colors.count - 2, Int(position))
            let fraction = position - CGFloat(lower)
            let color = colors[lower].blended(withFraction: fraction, of: colors[lower + 1])!
            color.setFill()
            NSRect(x: rect.minX, y: rect.minY + CGFloat(row) * rect.height / CGFloat(rows),
                   width: rect.width, height: rect.height / CGFloat(rows) + 0.5 / scale).fill()
        }
    }
}
