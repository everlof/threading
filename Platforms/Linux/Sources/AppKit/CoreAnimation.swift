import Foundation

/// Core Animation's small data surface used by shared drawn controls. The Linux raster host
/// paints backing-layer backgrounds before ordinary control drawing. Shadow, animation and
/// floating-target state are retained without claiming a complete Core Animation compositor.
public typealias CGColor = NSColor

public class CGPath {
    let path: NSBezierPath

    init(path: NSBezierPath) { self.path = path }

    public init(ellipseIn rect: CGRect, transform: CGAffineTransform?) {
        path = NSBezierPath(ovalIn: rect)
        precondition(transform == nil, "Linux CGPath cannot apply a Core Graphics transform")
    }

    public init(roundedRect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat,
                transform: CGAffineTransform?) {
        path = NSBezierPath(roundedRect: roundedRect,
                            xRadius: cornerWidth, yRadius: cornerHeight)
        precondition(transform == nil, "Linux CGPath cannot apply a Core Graphics transform")
    }
}

public final class CGMutablePath: CGPath {
    public init() { super.init(path: NSBezierPath()) }

    public func move(to point: CGPoint) { path.move(to: point) }
    public func addLine(to point: CGPoint) { path.line(to: point) }
    public func addCurve(to point: CGPoint, control1: CGPoint, control2: CGPoint) {
        path.curve(to: point, controlPoint1: control1, controlPoint2: control2)
    }
    public func addQuadCurve(to point: CGPoint, control: CGPoint) {
        let start = path.currentPoint
        path.curve(to: point,
                   controlPoint1: CGPoint(x: start.x + (control.x - start.x) * 2 / 3,
                                          y: start.y + (control.y - start.y) * 2 / 3),
                   controlPoint2: CGPoint(x: point.x + (control.x - point.x) * 2 / 3,
                                          y: point.y + (control.y - point.y) * 2 / 3))
    }
    public func closeSubpath() { path.close() }
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
    open var repeatCount: Float = 0
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

    open var isHidden = false
    open var masksToBounds = false
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
    private var animations: [String: (value: CAAnimation, startedAt: TimeInterval)] = [:]

    public init() {}
    public init(layer: Any) {
        guard let source = layer as? CALayer else { return }
        frame = source.frame
        backgroundColor = source.backgroundColor
        isHidden = source.isHidden
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

    open func addSublayer(_ layer: CALayer) {
        insertSublayer(layer, at: UInt32(sublayers.count))
    }

    open func removeFromSuperlayer() {
        superlayer?.sublayers.removeAll { $0 === self }
        superlayer = nil
    }

    open func add(_ animation: CAAnimation, forKey key: String?) {
        if let key { animations[key] = (animation, ProcessInfo.processInfo.systemUptime) }
    }

    open func removeAnimation(forKey key: String) { animations.removeValue(forKey: key) }

    open func animation(forKey key: String) -> CAAnimation? { animations[key]?.value }

    func animationPhase(forKey key: String) -> CGFloat? {
        guard let animation = animations[key], animation.value.duration > 0 else { return nil }
        let elapsed = ProcessInfo.processInfo.systemUptime - animation.startedAt
        return CGFloat((elapsed / animation.value.duration).truncatingRemainder(dividingBy: 1))
    }
}

/// The production spinner uses a shape layer for its partial ring. The shim rasterizes that
/// retained path when the SDL host requests a frame; its animation remains layer-owned.
open class CAShapeLayer: CALayer {
    public enum LineCap { case butt, round, square }
    public enum LineJoin { case miter, round, bevel }

    open var path: CGPath?
    open var fillColor: CGColor?
    open var strokeColor: CGColor?
    open var lineWidth: CGFloat = 1
    open var lineCap: LineCap = .butt
    open var lineJoin: LineJoin = .miter
    open var strokeStart: CGFloat = 0
    open var strokeEnd: CGFloat = 1

    public override init() { super.init() }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    func render(in context: NSGraphicsContext) {
        guard let path else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        context.translateBy(x: frame.minX, y: frame.minY)
        if let phase = animationPhase(forKey: "spin") {
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            context.translateBy(x: centre.x, y: centre.y)
            context.concat(CGAffineTransform(rotationAngle: -2 * .pi * phase))
            context.translateBy(x: -centre.x, y: -centre.y)
        }
        if let fillColor {
            fillColor.setFill()
            path.path.fill()
        }
        guard let strokeColor else { return }
        let stroke = clippedStroke(path.path)
        stroke.lineWidth = lineWidth
        stroke.lineCapStyle = switch lineCap {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
        stroke.lineJoinStyle = switch lineJoin {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
        strokeColor.setStroke()
        stroke.stroke()
    }

    private func clippedStroke(_ source: NSBezierPath) -> NSBezierPath {
        guard strokeStart > 0 || strokeEnd < 1 else { return source }
        let subpaths = source.subpaths(flatness: 0.1)
        let edges = subpaths.flatMap { subpath -> [(CGPoint, CGPoint, CGFloat)] in
            let points = subpath.closed ? subpath.points + [subpath.points[0]] : subpath.points
            return zip(points, points.dropFirst()).map { first, second in
                let distance = hypot(second.x - first.x, second.y - first.y)
                return (first, second, distance)
            }
        }
        let total = edges.reduce(CGFloat.zero) { $0 + $1.2 }
        let lower = min(1, max(0, strokeStart)) * total
        let upper = min(1, max(0, strokeEnd)) * total
        let clipped = NSBezierPath()
        guard upper > lower else { return clipped }
        var distance: CGFloat = 0
        var drawing = false
        for (first, second, length) in edges where length > 0 {
            let start = max(lower, distance)
            let end = min(upper, distance + length)
            if end > start {
                let from = (start - distance) / length
                let to = (end - distance) / length
                let startPoint = CGPoint(x: first.x + (second.x - first.x) * from,
                                         y: first.y + (second.y - first.y) * from)
                let endPoint = CGPoint(x: first.x + (second.x - first.x) * to,
                                       y: first.y + (second.y - first.y) * to)
                if !drawing { clipped.move(to: startPoint); drawing = true }
                clipped.line(to: endPoint)
            }
            distance += length
        }
        return clipped
    }
}

/// An axial gradient. Only its role as a mask is composited here: as a mask, its colours'
/// alpha is interpolated along `startPoint`→`endPoint` in unit layer coordinates. Unit y = 0 is
/// the top of a flipped view and the bottom of an unflipped one, because the coordinates are the
/// backing view's own.
open class CAGradientLayer: CALayer {
    public enum LayerType { case axial }
    open var type: LayerType = .axial
    open var colors: [Any]?
    open var locations: [NSNumber]?
    open var startPoint = CGPoint(x: 0.5, y: 0)
    open var endPoint = CGPoint(x: 0.5, y: 1)

    public override init() { super.init() }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    func render(in context: NSGraphicsContext, clippedTo visibleRect: CGRect) {
        guard !isHidden, frame.width > 0, frame.height > 0,
              let colors = colors as? [NSColor],
              let gradient = NSGradient(colors: colors) else { return }
        precondition(colors.count == 2 &&
                     abs(startPoint.x - endPoint.x) < 0.0001 &&
                     abs(startPoint.y - endPoint.y) == 1 &&
                     (locations == nil || locations == [0, 1]),
                     "Linux gradient drawing supports the exported two-stop vertical sidebar")
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        context.translateBy(x: frame.minX, y: frame.minY)
        let localVisible = visibleRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        gradient.draw(in: bounds, angle: startPoint.y > endPoint.y ? 90 : -90,
                      clippedTo: localVisible)
    }

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
