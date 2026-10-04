import Foundation

public enum NSBezierPathWindingRule: Sendable { case nonZero, evenOdd }
public enum NSLineCapStyle: Sendable { case butt, round, square }
public enum NSLineJoinStyle: Sendable { case miter, round, bevel }

/// Path construction with AppKit's spelling, including the two pieces `UI/Design` actually
/// depends on for its silhouettes: `init(roundedRect:xRadius:yRadius:)` clamping each axis
/// independently (the behaviour `ThemedSurface.Shape` documents and compensates for), and
/// `appendArc(from:to:radius:)`, the tangent arc its welded-plate `portion(in:)` is written in.
public final class NSBezierPath {

    public enum ElementType: Sendable {
        case moveTo, lineTo, curveTo, closePath
        case cubicCurveTo, quadraticCurveTo
    }

    private enum Element {
        case move(NSPoint)
        case line(NSPoint)
        case curve(to: NSPoint, c1: NSPoint, c2: NSPoint)
        case close
    }

    private var elements: [Element] = []

    public var lineWidth: CGFloat = 1
    public func setLineDash(_ pattern: [CGFloat], count: Int, phase: CGFloat) {
        preconditionFailure("Linux NSBezierPath does not yet rasterize dashed strokes")
    }
    public var windingRule: NSBezierPathWindingRule = .nonZero
    public var lineCapStyle: NSLineCapStyle = .butt
    public var lineJoinStyle: NSLineJoinStyle = .miter
    public var isEmpty: Bool { elements.isEmpty }
    public var elementCount: Int { elements.count }

    /// The geometric bounds of the path, including a cubic's extrema rather than its control
    /// handles. An empty path has no AppKit-valid bounds; the spike returns zero so callers can
    /// inspect it without an Objective-C exception.
    public var bounds: NSRect {
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        var current = NSPoint.zero
        var subpathStart = NSPoint.zero

        func include(_ point: NSPoint) {
            xs.append(point.x)
            ys.append(point.y)
        }

        for element in elements {
            switch element {
            case .move(let point):
                current = point
                subpathStart = point
                include(point)
            case .line(let point):
                include(point)
                current = point
            case .curve(let point, let c1, let c2):
                include(point)
                for t in Self.cubicExtrema(current.x, c1.x, c2.x, point.x) {
                    include(Self.cubic(current, c1, c2, point, t))
                }
                for t in Self.cubicExtrema(current.y, c1.y, c2.y, point.y) {
                    include(Self.cubic(current, c1, c2, point, t))
                }
                current = point
            case .close:
                current = subpathStart
            }
        }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public init() {}

    // MARK: - Construction

    public var currentPoint: NSPoint {
        var closed = false
        for element in elements.reversed() {
            switch element {
            case .move(let point): return point
            case .line(let point): if !closed { return point }
            case .curve(let point, _, _): if !closed { return point }
            case .close: closed = true
            }
        }
        return .zero
    }

    public func move(to point: NSPoint) { elements.append(.move(point)) }
    public func line(to point: NSPoint) { elements.append(.line(point)) }
    public func close() { elements.append(.close) }

    public func curve(to point: NSPoint, controlPoint1: NSPoint, controlPoint2: NSPoint) {
        elements.append(.curve(to: point, c1: controlPoint1, c2: controlPoint2))
    }

    public func append(_ other: NSBezierPath) { elements.append(contentsOf: other.elements) }

    public func element(at index: Int, associatedPoints points: inout [NSPoint]) -> ElementType {
        if points.count < 3 { points.append(contentsOf: repeatElement(.zero, count: 3 - points.count)) }
        return points.withUnsafeMutableBufferPointer { buffer in
            element(at: index, associatedPoints: buffer.baseAddress!)
        }
    }

    public func element(at index: Int, associatedPoints points: UnsafeMutablePointer<NSPoint>) -> ElementType {
        precondition(elements.indices.contains(index), "NSBezierPath element index out of bounds")
        switch elements[index] {
        case .move(let point):
            points[0] = point
            return .moveTo
        case .line(let point):
            points[0] = point
            return .lineTo
        case .curve(let point, let c1, let c2):
            points[0] = c1
            points[1] = c2
            points[2] = point
            return .curveTo
        case .close:
            return .closePath
        }
    }

    public var flattened: NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.windingRule = windingRule
        path.lineCapStyle = lineCapStyle
        path.lineJoinStyle = lineJoinStyle
        var current = NSPoint.zero
        var subpathStart = NSPoint.zero
        for element in elements {
            switch element {
            case .move(let point):
                path.move(to: point)
                current = point
                subpathStart = point
            case .line(let point):
                path.line(to: point)
                current = point
            case .curve(let point, let c1, let c2):
                let steps = Self.flatteningSteps(from: current, c1: c1, c2: c2, to: point)
                for step in 1...steps {
                    path.line(to: Self.cubic(current, c1, c2, point, CGFloat(step) / CGFloat(steps)))
                }
                current = point
            case .close:
                path.close()
                current = subpathStart
            }
        }
        return path
    }

    public func transform(using transform: AffineTransform) {
        elements = elements.map { element in
            switch element {
            case .move(let point): return .move(transform.transform(point))
            case .line(let point): return .line(transform.transform(point))
            case .curve(let point, let c1, let c2):
                return .curve(to: transform.transform(point),
                              c1: transform.transform(c1), c2: transform.transform(c2))
            case .close: return .close
            }
        }
    }

    public func appendRect(_ rect: NSRect) {
        move(to: NSPoint(x: rect.minX, y: rect.minY))
        line(to: NSPoint(x: rect.maxX, y: rect.minY))
        line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        line(to: NSPoint(x: rect.minX, y: rect.maxY))
        close()
    }

    public func appendOval(in rect: NSRect) {
        let k: CGFloat = 0.552_284_749_831
        let (rx, ry) = (rect.width / 2, rect.height / 2)
        let c = NSPoint(x: rect.midX, y: rect.midY)
        move(to: NSPoint(x: c.x, y: rect.minY))
        curve(to: NSPoint(x: rect.maxX, y: c.y),
              controlPoint1: NSPoint(x: c.x + rx * k, y: rect.minY),
              controlPoint2: NSPoint(x: rect.maxX, y: c.y - ry * k))
        curve(to: NSPoint(x: c.x, y: rect.maxY),
              controlPoint1: NSPoint(x: rect.maxX, y: c.y + ry * k),
              controlPoint2: NSPoint(x: c.x + rx * k, y: rect.maxY))
        curve(to: NSPoint(x: rect.minX, y: c.y),
              controlPoint1: NSPoint(x: c.x - rx * k, y: rect.maxY),
              controlPoint2: NSPoint(x: rect.minX, y: c.y + ry * k))
        curve(to: NSPoint(x: c.x, y: rect.minY),
              controlPoint1: NSPoint(x: rect.minX, y: c.y - ry * k),
              controlPoint2: NSPoint(x: c.x - rx * k, y: rect.minY))
        close()
    }

    /// AppKit clamps `xRadius` and `yRadius` **independently** against each axis, which is the
    /// asymmetry `ThemedSurface.Shape` exists to fit. Reproduced rather than corrected: the spike
    /// is testing whether our code is portable, not whether AppKit was right.
    public convenience init(roundedRect rect: NSRect, xRadius: CGFloat, yRadius: CGFloat) {
        self.init()
        let rx = max(0, min(xRadius, rect.width / 2))
        let ry = max(0, min(yRadius, rect.height / 2))
        guard rx > 0 || ry > 0 else { appendRect(rect); return }
        let k: CGFloat = 0.552_284_749_831
        move(to: NSPoint(x: rect.minX + rx, y: rect.minY))
        line(to: NSPoint(x: rect.maxX - rx, y: rect.minY))
        curve(to: NSPoint(x: rect.maxX, y: rect.minY + ry),
              controlPoint1: NSPoint(x: rect.maxX - rx + rx * k, y: rect.minY),
              controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + ry - ry * k))
        line(to: NSPoint(x: rect.maxX, y: rect.maxY - ry))
        curve(to: NSPoint(x: rect.maxX - rx, y: rect.maxY),
              controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - ry + ry * k),
              controlPoint2: NSPoint(x: rect.maxX - rx + rx * k, y: rect.maxY))
        line(to: NSPoint(x: rect.minX + rx, y: rect.maxY))
        curve(to: NSPoint(x: rect.minX, y: rect.maxY - ry),
              controlPoint1: NSPoint(x: rect.minX + rx - rx * k, y: rect.maxY),
              controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - ry + ry * k))
        line(to: NSPoint(x: rect.minX, y: rect.minY + ry))
        curve(to: NSPoint(x: rect.minX + rx, y: rect.minY),
              controlPoint1: NSPoint(x: rect.minX, y: rect.minY + ry - ry * k),
              controlPoint2: NSPoint(x: rect.minX + rx - rx * k, y: rect.minY))
        close()
    }

    public convenience init(rect: NSRect) {
        self.init()
        appendRect(rect)
    }

    public convenience init(ovalIn rect: NSRect) {
        self.init()
        appendOval(in: rect)
    }

    /// The tangent arc: turn from the current point towards `point1`, then away to `point2`,
    /// rounded by `radius`. Degenerate cases fall back to a corner, as AppKit's does.
    public func appendArc(from point1: NSPoint, to point2: NSPoint, radius: CGFloat) {
        let start = currentPoint
        guard radius > 0 else { line(to: point1); return }
        let v1 = normalize(NSPoint(x: start.x - point1.x, y: start.y - point1.y))
        let v2 = normalize(NSPoint(x: point2.x - point1.x, y: point2.y - point1.y))
        let dot = max(-1, min(1, v1.x * v2.x + v1.y * v2.y))
        let angle = acos(dot)
        guard angle > 0.000_1, angle < .pi - 0.000_1 else { line(to: point1); return }
        let distance = radius / tan(angle / 2)
        let entry = NSPoint(x: point1.x + v1.x * distance, y: point1.y + v1.y * distance)
        let exit = NSPoint(x: point1.x + v2.x * distance, y: point1.y + v2.y * distance)
        line(to: entry)
        // One cubic is within a rasterizer's tolerance for a corner of ≤ 90°, which is every
        // corner a rounded rect or a welded plate turns.
        let k = (4.0 / 3.0) * tan((.pi - angle) / 4)
        curve(to: exit,
              controlPoint1: NSPoint(x: entry.x + (point1.x - entry.x) * k, y: entry.y + (point1.y - entry.y) * k),
              controlPoint2: NSPoint(x: exit.x + (point1.x - exit.x) * k, y: exit.y + (point1.y - exit.y) * k))
    }

    private func normalize(_ point: NSPoint) -> NSPoint {
        let length = (point.x * point.x + point.y * point.y).squareRoot()
        guard length > 0 else { return .zero }
        return NSPoint(x: point.x / length, y: point.y / length)
    }

    // MARK: - Flattening

    /// Subpaths as polygons in this path's own coordinate space.
    func polygons(flatness: CGFloat = 0.2) -> [[NSPoint]] {
        var result: [[NSPoint]] = []
        var current: [NSPoint] = []
        var start = NSPoint.zero
        for element in elements {
            switch element {
            case .move(let point):
                if current.count > 1 { result.append(current) }
                current = [point]; start = point
            case .line(let point):
                current.append(point)
            case .curve(let point, let c1, let c2):
                let from = current.last ?? start
                let steps = Self.flatteningSteps(from: from, c1: c1, c2: c2, to: point, flatness: flatness)
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    current.append(Self.cubic(from, c1, c2, point, t))
                }
            case .close:
                if current.count > 1 { result.append(current) }
                current = [start]
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    private static func flatteningSteps(
        from: NSPoint, c1: NSPoint, c2: NSPoint, to: NSPoint, flatness: CGFloat = 0.2
    ) -> Int {
        let estimated = (distance(from, c1) + distance(c1, c2) + distance(c2, to)) / max(flatness, 0.001) / 3
        return min(96, max(4, Int(min(estimated, 96))))
    }

    private static func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    private static func cubic(_ p0: NSPoint, _ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint, _ t: CGFloat) -> NSPoint {
        let u = 1 - t
        let (a, b, c, d) = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
        return NSPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private static func cubicExtrema(_ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat) -> [CGFloat] {
        let a = -p0 + 3 * p1 - 3 * p2 + p3
        let b = 2 * (p0 - 2 * p1 + p2)
        let c = p1 - p0
        if abs(a) < 1e-12 {
            guard abs(b) >= 1e-12 else { return [] }
            let t = -c / b
            return t > 0 && t < 1 ? [t] : []
        }
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return [] }
        let root = discriminant.squareRoot()
        return [(-b + root) / (2 * a), (-b - root) / (2 * a)].filter { $0 > 0 && $0 < 1 }
    }

    // MARK: - Painting

    public func fill() {
        guard let context = NSGraphicsContext.current else { return }
        context.fill(polygons: polygons(), evenOdd: windingRule == .evenOdd, color: context.fillColor)
    }

    public func stroke() {
        guard let context = NSGraphicsContext.current else { return }
        context.stroke(polygons: polygons(), width: lineWidth, color: context.strokeColor)
    }

    public func addClip() {
        NSGraphicsContext.current?.intersectClip(polygons: polygons(), evenOdd: windingRule == .evenOdd)
    }

    public func setClip() { addClip() }

    public static func fill(_ rect: NSRect) { NSBezierPath(rect: rect).fill() }
    public static func stroke(_ rect: NSRect) { NSBezierPath(rect: rect).stroke() }
    public static func clip(_ rect: NSRect) { NSBezierPath(rect: rect).addClip() }
}

public func NSRectFill(_ rect: NSRect) { NSBezierPath.fill(rect) }
