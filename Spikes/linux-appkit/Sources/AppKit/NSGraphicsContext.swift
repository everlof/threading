import Foundation

/// The drawing destination and its state stack.
///
/// `UI/Design` reaches for `NSGraphicsContext` 293 times, almost always for the same three
/// things: `current`, `saveGraphicsState()`/`restoreGraphicsState()`, and a compositing mode.
/// That is a narrow enough contract to reproduce exactly, which matters more than it sounds:
/// save/restore is what every themed component uses to keep its clip and its colours from
/// leaking into its siblings, and getting it wrong would show up as a picture, not an error.
@MainActor
public final class NSGraphicsContext {

    public enum CompositingOperation: Sendable { case sourceOver, copy, plusLighter }

    private struct State {
        var fillColor: NSColor
        var strokeColor: NSColor
        var transform: CGAffineTransform
        var clip: [CGFloat]?
        var compositingOperation: CompositingOperation
        var alpha: CGFloat
    }

    public let bitmap: Bitmap
    /// Device pixels per point — the spike's stand-in for a backing scale factor.
    public let scale: CGFloat

    private var stack: [State]

    public static var current: NSGraphicsContext?

    public init(bitmap: Bitmap, scale: CGFloat = 2) {
        self.bitmap = bitmap
        self.scale = scale
        // The root transform carries AppKit's unflipped, y-up user space into a y-down buffer,
        // and the backing scale. Every view's own flip is a translation on top of this.
        stack = [State(
            fillColor: .black,
            strokeColor: .black,
            transform: CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: CGFloat(bitmap.height)),
            clip: nil,
            compositingOperation: .sourceOver,
            alpha: 1
        )]
    }

    // MARK: - State

    public var fillColor: NSColor {
        get { stack[stack.count - 1].fillColor }
        set { stack[stack.count - 1].fillColor = newValue }
    }

    public var strokeColor: NSColor {
        get { stack[stack.count - 1].strokeColor }
        set { stack[stack.count - 1].strokeColor = newValue }
    }

    public var compositingOperation: CompositingOperation {
        get { stack[stack.count - 1].compositingOperation }
        set { stack[stack.count - 1].compositingOperation = newValue }
    }

    public var shouldAntialias: Bool = true

    /// `NSView.alphaValue` folded into the context, the way a layer-free AppKit view tree gets it.
    public var alpha: CGFloat {
        get { stack[stack.count - 1].alpha }
        set { stack[stack.count - 1].alpha = newValue }
    }

    var transform: CGAffineTransform {
        get { stack[stack.count - 1].transform }
        set { stack[stack.count - 1].transform = newValue }
    }

    public func saveGraphicsState() { stack.append(stack[stack.count - 1]) }

    public func restoreGraphicsState() {
        if stack.count > 1 { stack.removeLast() }
    }

    public func concat(_ transform: CGAffineTransform) {
        stack[stack.count - 1].transform = transform.concatenating(self.transform)
    }

    public func translateBy(x: CGFloat, y: CGFloat) {
        concat(CGAffineTransform(translationX: x, y: y))
    }

    public func flipVertically(in height: CGFloat) {
        concat(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height))
    }

    // MARK: - Painting

    private func device(_ polygons: [[NSPoint]]) -> [[NSPoint]] {
        let transform = self.transform
        return polygons.map { $0.map { transform.apply(to: $0) } }
    }

    func fill(polygons: [[NSPoint]], evenOdd: Bool, color: NSColor) {
        var components = color.components
        components.3 *= alpha
        Rasterizer.fill(
            polygons: device(polygons),
            evenOdd: evenOdd,
            color: components,
            clip: stack[stack.count - 1].clip,
            into: bitmap
        )
    }

    func stroke(polygons: [[NSPoint]], width: CGFloat, color: NSColor) {
        // A stroke is filled as its outline: each segment becomes a quad, each joint a disc.
        // Coarse next to a real backend's stroker, and enough for the hairlines and rings the
        // themed surfaces draw.
        let half = max(width, 0.1) / 2
        var outline: [[NSPoint]] = []
        for polygon in polygons {
            guard polygon.count > 1 else { continue }
            for index in 0..<polygon.count where index + 1 < polygon.count || polygon.count > 2 {
                let a = polygon[index]
                let b = polygon[(index + 1) % polygon.count]
                let dx = b.x - a.x, dy = b.y - a.y
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0 else { continue }
                let nx = -dy / length * half, ny = dx / length * half
                outline.append([
                    NSPoint(x: a.x + nx, y: a.y + ny), NSPoint(x: b.x + nx, y: b.y + ny),
                    NSPoint(x: b.x - nx, y: b.y - ny), NSPoint(x: a.x - nx, y: a.y - ny)
                ])
                let joint = NSBezierPath(ovalIn: NSRect(x: b.x - half, y: b.y - half, width: half * 2, height: half * 2))
                outline.append(contentsOf: joint.polygons())
            }
        }
        var components = color.components
        components.3 *= alpha
        // Each quad filled separately, so overlapping joins do not cancel under nonzero winding.
        for piece in outline {
            Rasterizer.fill(
                polygons: device([piece]),
                evenOdd: false,
                color: components,
                clip: stack[stack.count - 1].clip,
                into: bitmap
            )
        }
    }

    func intersectClip(polygons: [[NSPoint]], evenOdd: Bool) {
        let mask = Rasterizer.mask(
            polygons: device(polygons),
            evenOdd: evenOdd,
            width: bitmap.width,
            height: bitmap.height
        )
        if let existing = stack[stack.count - 1].clip {
            stack[stack.count - 1].clip = zip(existing, mask).map(*)
        } else {
            stack[stack.count - 1].clip = mask
        }
    }
}

// MARK: - The static face

extension NSGraphicsContext {

    public static func saveGraphicsState() { current?.saveGraphicsState() }
    public static func restoreGraphicsState() { current?.restoreGraphicsState() }

    /// Whether the context's user space runs top-down. `PlatinumBitmapFont` asks this to decide
    /// which way its QuickDraw baseline grows, which is the one place in the vendored set where
    /// a drawing routine branches on the coordinate system rather than being handed it.
    public var isFlipped: Bool { transform.d > 0 }

    /// The escape hatch every AppKit drawing routine eventually reaches for. Kept to the members
    /// our code actually calls, so the spike measures the real surface rather than an imagined one.
    public var cgContext: CGContextShim { CGContextShim(owner: self) }
}

@MainActor
public struct CGContextShim {
    let owner: NSGraphicsContext
    public func setShouldAntialias(_ value: Bool) { owner.shouldAntialias = value }
    public func saveGState() { owner.saveGraphicsState() }
    public func restoreGState() { owner.restoreGraphicsState() }
}

extension NSRect {
    /// AppKit hangs `fill()` and `frame()` off the rect itself; `PlatinumBitmapFont` sets one
    /// pixel per lit bit that way.
    @MainActor public func fill() { NSBezierPath(rect: self).fill() }
    @MainActor public func frame() { NSBezierPath(rect: self).stroke() }
}
