import Foundation

public enum NSBezierPathWindingRule: Sendable { case nonZero, evenOdd }
public enum NSLineCapStyle: Sendable { case butt, round, square }
public enum NSLineJoinStyle: Sendable { case miter, round, bevel }

/// Path construction with AppKit's spelling, including the two pieces `UI/Design` actually
/// depends on for its silhouettes: `init(roundedRect:xRadius:yRadius:)` clamping each axis
/// independently (the behaviour `ThemedSurface.Shape` documents and compensates for), and
/// `appendArc(from:to:radius:)`, the tangent arc its welded-plate `portion(in:)` is written in.
public final class NSBezierPath {

    private enum Element {
        case move(NSPoint)
        case line(NSPoint)
        case curve(to: NSPoint, c1: NSPoint, c2: NSPoint)
        case close
    }

    private var elements: [Element] = []

    public var lineWidth: CGFloat = 1
    public var windingRule: NSBezierPathWindingRule = .nonZero
    public var lineCapStyle: NSLineCapStyle = .butt
    public var lineJoinStyle: NSLineJoinStyle = .miter
    public var isEmpty: Bool { elements.isEmpty }

    public init() {}

    // MARK: - Construction

    public var currentPoint: NSPoint {
        for element in elements.reversed() {
            switch element {
            case .move(let p), .line(let p): return p
            case .curve(let p, _, _): return p
            case .close: continue
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
                let steps = max(4, Int((distance(from, c1) + distance(c1, c2) + distance(c2, point)) / flatness / 3))
                for step in 1...min(steps, 96) {
                    let t = CGFloat(step) / CGFloat(min(steps, 96))
                    current.append(cubic(from, c1, c2, point, t))
                }
            case .close:
                if current.count > 1 { result.append(current) }
                current = [start]
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    private func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    private func cubic(_ p0: NSPoint, _ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint, _ t: CGFloat) -> NSPoint {
        let u = 1 - t
        let (a, b, c, d) = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
        return NSPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
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
