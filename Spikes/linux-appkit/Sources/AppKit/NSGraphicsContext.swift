import Foundation

/// The drawing destination and its state stack.
///
/// `UI/Design` reaches for `NSGraphicsContext` 293 times, almost always for the same three
/// things: `current`, `saveGraphicsState()`/`restoreGraphicsState()`, and a compositing mode.
/// That is a narrow enough contract to reproduce exactly, which matters more than it sounds:
/// save/restore is what every themed component uses to keep its clip and its colours from
/// leaking into its siblings, and getting it wrong would show up as a picture, not an error.
public final class NSGraphicsContext {

    public enum CompositingOperation: Sendable { case sourceOver, sourceIn, copy, plusLighter }

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

    /// A glyph usually touches four or fewer tiles. A transparency group must not allocate a
    /// window-sized bitmap for each visible mark. The bound also refuses accidentally using this
    /// narrow leaf for an unbounded offscreen surface.
    private final class TransparencyLayer {
        static let tileSide = 16
        var tiles: [Int: Bitmap] = [:]
        let savedDepth: Int
        init(savedDepth: Int) { self.savedDepth = savedDepth }
    }
    private var layers: [TransparencyLayer] = []
    public private(set) var peakTransparencyLayerPixelCount = 0
    private var allocatedLayerPixels = 0
    private static let maximumLayerPixels = 1_048_576

    /// AppKit's current drawing context is thread-local, not a process-global UI value. This
    /// keeps unchanged production image drawing callable from a bounded background renderer.
    public static var current: NSGraphicsContext? {
        get { Thread.current.threadDictionary["ThreadingShim.NSGraphicsContext.current"] as? NSGraphicsContext }
        set {
            if let newValue { Thread.current.threadDictionary["ThreadingShim.NSGraphicsContext.current"] = newValue }
            else { Thread.current.threadDictionary.removeObject(forKey: "ThreadingShim.NSGraphicsContext.current") }
        }
    }

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
        set {
            precondition(newValue == .sourceOver || newValue == .sourceIn,
                         "drawing supports only sourceOver and sourceIn")
            stack[stack.count - 1].compositingOperation = newValue
        }
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
        let polygons = device(polygons)
        if !layers.isEmpty || compositingOperation != .sourceOver {
            let points = polygons.flatMap { $0 }
            guard !points.isEmpty else { return }
            precondition(points.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "nonfinite image-layer geometry")
            let left = Int(max(0, min(CGFloat(bitmap.width), points.map(\.x).min()!.rounded(.down))))
            let right = Int(max(0, min(CGFloat(bitmap.width), points.map(\.x).max()!.rounded(.up))))
            let top = Int(max(0, min(CGFloat(bitmap.height), points.map(\.y).min()!.rounded(.down))))
            let bottom = Int(max(0, min(CGFloat(bitmap.height), points.map(\.y).max()!.rounded(.up))))
            guard left < right, top < bottom else { return }
            let width = right - left, height = bottom - top
            precondition(width * height <= Self.maximumLayerPixels, "image-layer fill exceeds pixel bound")
            // Reuse the real scan converter over only the primitive's visible bounds. In
            // particular, a source-in icon tint never scans or allocates a full-window mask.
            let local = polygons.map { $0.map { NSPoint(x: $0.x - CGFloat(left), y: $0.y - CGFloat(top)) } }
            let mask = Rasterizer.mask(polygons: local, evenOdd: evenOdd, width: width, height: height)
            for row in 0..<height {
                for column in 0..<width where mask[row * width + column] > 0 {
                    composite(x: left + column, y: top + row, color: components,
                              coverage: mask[row * width + column])
                }
            }
            return
        }
        Rasterizer.fill(
            polygons: polygons,
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
        // Each quad filled separately, so overlapping joins do not cancel under nonzero winding.
        for piece in outline {
            fill(polygons: [piece], evenOdd: false, color: color)
        }
    }

    func composite(x: Int, y: Int, color: (CGFloat, CGFloat, CGFloat, CGFloat), coverage: CGFloat) {
        guard x >= 0, x < bitmap.width, y >= 0, y < bitmap.height else { return }
        var coverage = coverage
        if let clip = stack.last?.clip { coverage *= clip[y * bitmap.width + x] }
        guard coverage > 0 else { return }
        let destination: Bitmap
        let localX: Int, localY: Int
        if let layer = layers.last {
            let side = TransparencyLayer.tileSide
            let columns = (bitmap.width + side - 1) / side
            let key = (y / side) * columns + x / side
            if let tile = layer.tiles[key] { destination = tile }
            else {
                // Transparent source-over/source-in cannot create coverage in an empty tile.
                guard color.3 > 0, compositingOperation != .sourceIn else { return }
                precondition(allocatedLayerPixels <= Self.maximumLayerPixels - side * side,
                             "transparency group exceeds the bounded image leaf")
                destination = Bitmap(width: side, height: side)
                layer.tiles[key] = destination
                allocatedLayerPixels += side * side
                peakTransparencyLayerPixelCount = max(peakTransparencyLayerPixelCount, allocatedLayerPixels)
            }
            localX = x % side; localY = y % side
        } else {
            destination = bitmap; localX = x; localY = y
        }
        destination.composite(x: localX, y: localY, color: color,
                              coverage: coverage, operation: compositingOperation)
    }

    fileprivate func beginTransparencyLayer() {
        precondition(layers.count < 8, "transparency nesting exceeds the bounded image leaf")
        precondition(compositingOperation == .sourceOver,
                     "transparency groups require sourceOver parent composition")
        layers.append(TransparencyLayer(savedDepth: stack.count))
        var local = stack[stack.count - 1]
        // Group opacity and inherited clipping apply once, when the isolated result rejoins its
        // parent. Inner draws can add their own opacity/clip without squaring the inherited ones.
        local.alpha = 1
        local.clip = nil
        local.compositingOperation = .sourceOver
        stack.append(local)
    }

    fileprivate func endTransparencyLayer() {
        guard let layer = layers.popLast() else {
            preconditionFailure("endTransparencyLayer without a matching begin")
        }
        precondition(stack.count == layer.savedDepth + 1,
                     "unbalanced graphics state inside transparency layer")
        stack.removeLast()
        let side = TransparencyLayer.tileSide
        let columns = (bitmap.width + side - 1) / side
        for (key, tile) in layer.tiles {
            let originX = key % columns * side, originY = key / columns * side
            for y in 0..<min(side, bitmap.height - originY) {
                for x in 0..<min(side, bitmap.width - originX) {
                    let offset = (y * side + x) * 4
                    let opacity = CGFloat(tile.pixels[offset + 3]) / 255
                    guard opacity > 0 else { continue }
                    composite(x: originX + x, y: originY + y,
                        color: (CGFloat(tile.pixels[offset]) / 255,
                                CGFloat(tile.pixels[offset + 1]) / 255,
                                CGFloat(tile.pixels[offset + 2]) / 255, opacity * alpha), coverage: 1)
                }
            }
        }
        allocatedLayerPixels -= layer.tiles.count * side * side
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

public struct CGContextShim {
    let owner: NSGraphicsContext
    public func setShouldAntialias(_ value: Bool) { owner.shouldAntialias = value }
    public func saveGState() { owner.saveGraphicsState() }
    public func restoreGState() { owner.restoreGraphicsState() }
    public func beginTransparencyLayer(auxiliaryInfo: [String: Any]?) {
        precondition(auxiliaryInfo == nil, "transparency auxiliary options are unsupported")
        owner.beginTransparencyLayer()
    }
    public func endTransparencyLayer() { owner.endTransparencyLayer() }
}

extension NSRect {
    /// AppKit hangs `fill()` and `frame()` off the rect itself; `PlatinumBitmapFont` sets one
    /// pixel per lit bit that way.
    public func fill() { NSBezierPath(rect: self).fill() }
    public func fill(using operation: NSGraphicsContext.CompositingOperation) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        context.compositingOperation = operation
        fill()
    }
    public func frame() { NSBezierPath(rect: self).stroke() }
}
