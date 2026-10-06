import Foundation

/// Core Animation's small data surface used by shared drawn controls. The Linux raster host
/// paints backing-layer backgrounds before ordinary control drawing. Shadow, animation and
/// floating-target state are retained without claiming a complete Core Animation compositor.
public typealias CGColor = NSColor

public struct CGPath {
    let path: NSBezierPath

    public init(roundedRect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat,
                transform: CGAffineTransform?) {
        let path = NSBezierPath(roundedRect: roundedRect,
                                xRadius: cornerWidth, yRadius: cornerHeight)
        precondition(transform == nil, "Linux CGPath cannot apply a Core Graphics transform")
        self.path = path
    }
}

public final class CGContext {
    public enum PathDrawingMode { case eoFill }

    private let graphics: NSGraphicsContext
    private let path = NSBezierPath()

    public init(graphics: NSGraphicsContext) { self.graphics = graphics }
    public func addPath(_ part: CGPath) { path.append(part.path) }
    public func setFillColor(_ color: CGColor) { graphics.fillColor = color }
    public func drawPath(using mode: PathDrawingMode) {
        switch mode {
        case .eoFill: path.windingRule = .evenOdd
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.current = previous }
        path.fill()
    }
}

public struct CATransform3D: Sendable {
    public var translationX: CGFloat = 0
    public var translationY: CGFloat = 0
    public var translationZ: CGFloat = 0
    public var scaleX: CGFloat = 1
    public var scaleY: CGFloat = 1
    public var scaleZ: CGFloat = 1
}

public func CATransform3DMakeTranslation(_ x: CGFloat, _ y: CGFloat,
                                         _ z: CGFloat) -> CATransform3D {
    CATransform3D(translationX: x, translationY: y, translationZ: z)
}

public func CATransform3DTranslate(_ transform: CATransform3D, _ x: CGFloat,
                                   _ y: CGFloat, _ z: CGFloat) -> CATransform3D {
    var result = transform
    result.translationX += x * transform.scaleX
    result.translationY += y * transform.scaleY
    result.translationZ += z * transform.scaleZ
    return result
}

public func CATransform3DScale(_ transform: CATransform3D, _ x: CGFloat,
                               _ y: CGFloat, _ z: CGFloat) -> CATransform3D {
    var result = transform
    result.scaleX *= x
    result.scaleY *= y
    result.scaleZ *= z
    return result
}

public final class CAMediaTimingFunction: @unchecked Sendable {
    public let controlPoints: (Float, Float, Float, Float)

    public init(controlPoints x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        controlPoints = (x1, y1, x2, y2)
    }
}

open class CAAnimation {
    public enum FillMode { case removed, forwards }
    open var duration: TimeInterval = 0
    open var timingFunction: CAMediaTimingFunction?
    open var fillMode: FillMode = .removed
    open var isRemovedOnCompletion = true
    public init() {}
}

public final class CABasicAnimation: CAAnimation {
    public let keyPath: String
    public var fromValue: Any?
    public var toValue: Any?
    public init(keyPath: String) {
        self.keyPath = keyPath
        super.init()
    }
}

public final class CAAnimationGroup: CAAnimation {
    public var animations: [CAAnimation] = []
}

open class CALayer {
    public enum CornerCurve { case circular, continuous }

    open var frame: CGRect = .zero
    open var backgroundColor: CGColor?
    open var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }
    open var name: String?
    open var needsDisplayOnBoundsChange = false
    open var drawsAsynchronously = false
    open var contentsScale: CGFloat = 1
    open var cornerCurve: CornerCurve = .continuous
    open var shadowPath: CGPath?
    open var anchorPoint = CGPoint(x: 0.5, y: 0.5)
    open var isGeometryFlipped = false
    /// The view-backing layer's mask, in this layer's coordinates. `NSView.render` composites
    /// the view's drawing through it: alpha only, with everything outside its frame cleared.
    open var mask: CALayer?
    public private(set) weak var superlayer: CALayer?
    public private(set) var sublayers: [CALayer] = []
    private var animations: [String: CAAnimation] = [:]

    public init() {}
    public init(layer: Any) {
        guard let source = layer as? CALayer else { return }
        frame = source.frame
        backgroundColor = source.backgroundColor
        name = source.name
        contentsScale = source.contentsScale
        cornerCurve = source.cornerCurve
        shadowPath = source.shadowPath
        anchorPoint = source.anchorPoint
        isGeometryFlipped = source.isGeometryFlipped
    }
    public required init?(coder: NSCoder) {}

    open func draw(in context: CGContext) {}
    open func setNeedsDisplay() {}

    open func insertSublayer(_ layer: CALayer, at index: UInt32) {
        layer.removeFromSuperlayer()
        layer.superlayer = self
        sublayers.insert(layer, at: min(Int(index), sublayers.count))
    }

    open func removeFromSuperlayer() {
        superlayer?.sublayers.removeAll { $0 === self }
        superlayer = nil
    }

    open func add(_ animation: CAAnimation, forKey key: String?) {
        if let key { animations[key] = animation }
    }

    open func removeAnimation(forKey key: String) { animations.removeValue(forKey: key) }
}

/// An axial gradient. Only its role as a mask is composited here: as a mask, its colours'
/// alpha is interpolated along `startPoint`→`endPoint` in unit layer coordinates. Unit y = 0 is
/// the top of a flipped view and the bottom of an unflipped one, because the coordinates are the
/// backing view's own.
open class CAGradientLayer: CALayer {
    open var colors: [Any]?
    open var locations: [NSNumber]?
    open var startPoint = CGPoint(x: 0.5, y: 0)
    open var endPoint = CGPoint(x: 0.5, y: 1)

    public override init() { super.init() }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    /// The interpolated alpha at `point`, in unit coordinates of this layer's frame.
    func alpha(atUnit point: CGPoint) -> CGFloat {
        let stops = (colors ?? []).map { value -> CGFloat in
            guard let color = value as? NSColor else {
                preconditionFailure("gradient colours must be CGColor values")
            }
            return color.alphaComponent
        }
        guard let first = stops.first else { return 0 }
        guard stops.count > 1 else { return first }
        let positions: [CGFloat]
        if let locations {
            positions = locations.map { CGFloat($0.doubleValue) }
        } else {
            let last = CGFloat(stops.count - 1)
            positions = stops.indices.map { CGFloat($0) / last }
        }
        precondition(positions.count == stops.count, "gradient locations must match its colours")
        let dx = endPoint.x - startPoint.x, dy = endPoint.y - startPoint.y
        let length = dx * dx + dy * dy
        let projected = length > 0
            ? ((point.x - startPoint.x) * dx + (point.y - startPoint.y) * dy) / length : 0
        let t = min(1, max(0, projected))
        guard t > positions[0] else { return first }
        for index in 1..<positions.count where t <= positions[index] {
            let span = positions[index] - positions[index - 1]
            let fraction = span > 0 ? (t - positions[index - 1]) / span : 1
            return stops[index - 1] + (stops[index] - stops[index - 1]) * fraction
        }
        return stops[stops.count - 1]
    }
}

extension NSValue {
    public convenience init(caTransform3D value: CATransform3D) {
        var copy = value
        self.init(bytes: &copy, objCType: "{CATransform3D=dddddd}")
    }
}
