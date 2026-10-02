import Foundation

// MARK: - What Linux Foundation already provides

// `NSPoint`, `NSSize`, `NSRect`, `NSEdgeInsets` and `CGFloat` are real types in
// swift-corelibs-foundation, with `insetBy(dx:dy:)`, `integral`, `intersection(_:)`, `isNull`,
// `midX`/`maxY` and the rest already implemented. They are the three most-referenced symbols in
// `UI/Design` (816 + 313 + 215 sites) and the shim owes them nothing.
//
// What is missing is the affine transform and the handful of C-style constructors AppKit code
// still uses.

public struct CGAffineTransform: Equatable, Sendable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat

    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        (self.a, self.b, self.c, self.d, self.tx, self.ty) = (a, b, c, d, tx, ty)
    }

    public static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public init(translationX: CGFloat, y: CGFloat) {
        self.init(a: 1, b: 0, c: 0, d: 1, tx: translationX, ty: y)
    }

    public init(scaleX: CGFloat, y: CGFloat) {
        self.init(a: scaleX, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }

    public init(rotationAngle radians: CGFloat) {
        let (s, c) = (sin(radians), cos(radians))
        self.init(a: c, b: s, c: -s, d: c, tx: 0, ty: 0)
    }

    public func concatenating(_ other: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    public func translatedBy(x: CGFloat, y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: x, y: y).concatenating(self)
    }

    public func scaledBy(x: CGFloat, y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(scaleX: x, y: y).concatenating(self)
    }

    public func apply(to point: NSPoint) -> NSPoint {
        NSPoint(x: a * point.x + c * point.y + tx, y: b * point.x + d * point.y + ty)
    }
}

public func NSMakeRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: y, width: w, height: h)
}

public func NSMakePoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
public func NSMakeSize(_ w: CGFloat, _ h: CGFloat) -> NSSize { NSSize(width: w, height: h) }

extension NSRect {
    /// AppKit spells this `NSInsetRect`'s inverse; `UI/Design` uses it through `NSEdgeInsets`.
    public func inset(by insets: NSEdgeInsets) -> NSRect {
        NSRect(
            x: minX + insets.left,
            y: minY + insets.bottom,
            width: max(0, width - insets.left - insets.right),
            height: max(0, height - insets.top - insets.bottom)
        )
    }
}
