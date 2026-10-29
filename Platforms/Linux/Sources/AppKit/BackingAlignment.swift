import Foundation

/// The edge-alignment operation used by production glyph and file-icon views.
public struct NSAlignmentOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let alignAllEdgesInward = NSAlignmentOptions(rawValue: 1)
    public static let alignAllEdgesNearest = NSAlignmentOptions(rawValue: 2)
}

extension NSView {
    /// Aligns a local rectangle to device pixels using the active drawing transform. A nested
    /// view's fractional origin and a flipped view both affect the pixel grid, so rounding the
    /// local coordinates alone would still leave its image blurred. The current raster backend
    /// draws axis-aligned views; a rotated/sheared transform cannot be represented by an aligned
    /// local NSRect and is returned unchanged.
    public func backingAlignedRect(_ rect: NSRect, options: NSAlignmentOptions) -> NSRect {
        precondition(options == .alignAllEdgesInward || options == .alignAllEdgesNearest,
                     "unsupported backing alignment option")
        guard rect.width > 0, rect.height > 0 else { return rect }
        let transform: CGAffineTransform
        if let context = NSGraphicsContext.current {
            transform = context.transform
        } else {
            // Auto Layout commonly measures before rasterization. Use the attached window's
            // backing scale then, just as AppKit does when aligning a view outside draw(_:).
            let scale = window?.backingScaleFactor ?? 1
            transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        guard transform.b == 0, transform.c == 0,
              transform.a.isFinite, transform.d.isFinite,
              transform.tx.isFinite, transform.ty.isFinite,
              transform.a != 0, transform.d != 0 else { return rect }

        func inward(_ lower: CGFloat, _ upper: CGFloat, scale: CGFloat, offset: CGFloat)
            -> (CGFloat, CGFloat) {
            let first = lower * scale + offset
            let second = upper * scale + offset
            let low = min(first, second).rounded(.up)
            let high = max(first, second).rounded(.down)
            // A subpixel rectangle has no complete device pixel to contain. Preserve a valid
            // zero-area rectangle inside it instead of expanding beyond either source edge.
            guard high > low else { return (lower, lower) }
            let a = (low - offset) / scale
            let b = (high - offset) / scale
            return (min(a, b), max(a, b))
        }

        func nearest(_ lower: CGFloat, _ upper: CGFloat, scale: CGFloat, offset: CGFloat)
            -> (CGFloat, CGFloat) {
            let first = (lower * scale + offset).rounded()
            let second = (upper * scale + offset).rounded()
            let a = (first - offset) / scale
            let b = (second - offset) / scale
            return (min(a, b), max(a, b))
        }

        let x = options == .alignAllEdgesNearest
            ? nearest(rect.minX, rect.maxX, scale: transform.a, offset: transform.tx)
            : inward(rect.minX, rect.maxX, scale: transform.a, offset: transform.tx)
        let y = options == .alignAllEdgesNearest
            ? nearest(rect.minY, rect.maxY, scale: transform.d, offset: transform.ty)
            : inward(rect.minY, rect.maxY, scale: transform.d, offset: transform.ty)
        return NSRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
    }
}
