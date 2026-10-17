import Foundation

/// Gradients for chooser wells, sidebar backdrops and small radial highlights. Vertical fills
/// visit visible backing rows; radial fills visit the transformed path's visible pixels. Neither
/// allocates an intermediate bitmap, and clipping retains the complete gradient's phase.
public final class NSGradient {
    private let colors: [NSColor]

    public init?(colors: [NSColor]) {
        guard colors.count >= 2, colors.count <= 16 else { return nil }
        self.colors = colors
    }

    public convenience init?(starting: NSColor, ending: NSColor) {
        self.init(colors: [starting, ending])
    }

    /// AppKit's radial convenience method ends at the opposite corner of the path bounds.
    /// Evaluate each visible device pixel once, then apply the inherited/path clip once;
    /// overlapping translucent rings would incorrectly accumulate the halo's alpha.
    public func draw(in path: NSBezierPath, relativeCenterPosition position: NSPoint) {
        guard let context = NSGraphicsContext.current else { return }
        precondition(position.x.isFinite && position.y.isFinite, "nonfinite gradient center")
        let rect = path.bounds
        guard !rect.isEmpty else { return }
        let center = NSPoint(x: rect.midX + position.x * rect.width / 2,
                             y: rect.midY + position.y * rect.height / 2)
        let radius = hypot(rect.width / 2 + abs(center.x - rect.midX),
                           rect.height / 2 + abs(center.y - rect.midY))
        let transform = context.transform
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard abs(determinant) > 0.000_000_001 else { return }
        let inverse = transform.inverted()
        let corners = [rect.origin, NSPoint(x: rect.maxX, y: rect.minY),
                       NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)]
            .map(transform.apply)
        let left = Int(max(0, min(CGFloat(context.bitmap.width), floor(corners.map(\.x).min()!))))
        let right = Int(max(0, min(CGFloat(context.bitmap.width), ceil(corners.map(\.x).max()!))))
        let top = Int(max(0, min(CGFloat(context.bitmap.height), floor(corners.map(\.y).min()!))))
        let bottom = Int(max(0, min(CGFloat(context.bitmap.height), ceil(corners.map(\.y).max()!))))
        guard left < right, top < bottom else { return }
        let stops = colors.map { ($0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        path.addClip()
        for y in top..<bottom {
            for x in left..<right {
                let point = inverse.apply(to: NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                let progress = min(1, hypot(point.x - center.x, point.y - center.y) / radius)
                    * CGFloat(stops.count - 1)
                let index = min(stops.count - 2, Int(progress))
                let fraction = progress - CGFloat(index)
                let a = stops[index], b = stops[index + 1]
                context.composite(x: x, y: y, color: (
                    a.0 + (b.0 - a.0) * fraction, a.1 + (b.1 - a.1) * fraction,
                    a.2 + (b.2 - a.2) * fraction,
                    (a.3 + (b.3 - a.3) * fraction) * context.alpha), coverage: 1)
            }
        }
    }

    public func draw(in rect: NSRect, angle: CGFloat, clippedTo visibleRect: NSRect? = nil) {
        precondition(angle == -90 || angle == 90,
                     "Linux NSGradient currently supports vertical chooser gradients")
        guard rect.height > 0, rect.width > 0 else { return }
        let visible = visibleRect.map { rect.intersection($0) } ?? rect
        guard !visible.isEmpty else { return }
        let scale = NSGraphicsContext.current?.scale ?? 1
        let rows = min(4096, max(1, Int(ceil(rect.height * scale))))
        let rowHeight = rect.height / CGFloat(rows)
        // Keep the full gradient's phase while skipping rows outside the ancestor clip.
        // One preceding row preserves the half-device-pixel coverage overlap below.
        let first = max(0, Int(floor((visible.minY - rect.minY) / rowHeight)) - 1)
        let end = min(rows, Int(ceil((visible.maxY - rect.minY) / rowHeight)))
        for row in first..<end {
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
