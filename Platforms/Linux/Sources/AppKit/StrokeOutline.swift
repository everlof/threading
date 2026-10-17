import Foundation

/// Expands bounded, flattened UI paths in user space before the context applies its transform.
/// All pieces share a winding so their overlap is a union, including between separate subpaths.
enum StrokeOutline {
    private struct Segment {
        let start: NSPoint
        let end: NSPoint
        let direction: NSPoint
        var normal: NSPoint { NSPoint(x: -direction.y, y: direction.x) }
    }

    static func polygons(subpaths: [NSBezierPath.Subpath], width: CGFloat,
                         cap: NSLineCapStyle, join: NSLineJoinStyle,
                         miterLimit: CGFloat) -> [[NSPoint]] {
        precondition(width.isFinite && width >= 0 && miterLimit.isFinite && miterLimit >= 1,
                     "invalid stroke geometry")
        let half = max(width, 0.1) / 2
        var pieces: [[NSPoint]] = []
        for path in subpaths {
            var points: [NSPoint] = []
            for point in path.points where point != points.last { points.append(point) }
            if path.closed, points.count > 1, points.first == points.last { points.removeLast() }
            guard points.count > 1 else {
                if !path.closed, cap == .round, path.points.count > 1, let point = points.first {
                    pieces.append(disc(at: point, radius: half))
                }
                continue
            }
            let endpoints = path.closed ? points + [points[0]] : points
            let segments = zip(endpoints, endpoints.dropFirst()).map { start, end in
                let dx = end.x - start.x, dy = end.y - start.y
                let length = hypot(dx, dy)
                return Segment(start: start, end: end, direction: NSPoint(x: dx / length, y: dy / length))
            }
            for (index, segment) in segments.enumerated() {
                let start = offset(segment.start, along: segment.direction,
                                   by: !path.closed && cap == .square && index == 0 ? -half : 0)
                let end = offset(segment.end, along: segment.direction,
                                 by: !path.closed && cap == .square && index == segments.count - 1 ? half : 0)
                pieces.append([offset(start, along: segment.normal, by: half),
                               offset(end, along: segment.normal, by: half),
                               offset(end, along: segment.normal, by: -half),
                               offset(start, along: segment.normal, by: -half)])
            }
            let firstJoin = path.closed ? 0 : 1
            for index in firstJoin..<segments.count {
                let previous = segments[(index + segments.count - 1) % segments.count]
                pieces.append(contentsOf: joint(previous, segments[index], half: half,
                                                 style: join, miterLimit: miterLimit))
            }
            if !path.closed, cap == .round {
                pieces.append(disc(at: points[0], radius: half))
                pieces.append(disc(at: points[points.count - 1], radius: half))
            }
        }
        return pieces.map { polygon in
            let area = zip(polygon, polygon.dropFirst() + [polygon[0]])
                .reduce(CGFloat.zero) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
            return area > 0 ? Array(polygon.reversed()) : polygon
        }
    }

    private static func joint(_ incoming: Segment, _ outgoing: Segment, half: CGFloat,
                              style: NSLineJoinStyle, miterLimit: CGFloat) -> [[NSPoint]] {
        let vertex = outgoing.start
        if style == .round { return [disc(at: vertex, radius: half)] }
        let cross = incoming.direction.x * outgoing.direction.y - incoming.direction.y * outgoing.direction.x
        guard abs(cross) > 1e-10 else { return [] }
        let side: CGFloat = cross > 0 ? -1 : 1
        let first = offset(vertex, along: incoming.normal, by: side * half)
        let last = offset(vertex, along: outgoing.normal, by: side * half)
        if style == .miter {
            let dot = incoming.direction.x * outgoing.direction.x + incoming.direction.y * outgoing.direction.y
            let denominator = 1 + dot
            if denominator > 1e-10 {
                let x = (incoming.normal.x + outgoing.normal.x) * side * half / denominator
                let y = (incoming.normal.y + outgoing.normal.y) * side * half / denominator
                if hypot(x, y) <= half * miterLimit {
                    return [[vertex, first, NSPoint(x: vertex.x + x, y: vertex.y + y), last]]
                }
            }
        }
        return [[vertex, first, last]]
    }

    private static func offset(_ point: NSPoint, along vector: NSPoint, by distance: CGFloat) -> NSPoint {
        NSPoint(x: point.x + vector.x * distance, y: point.y + vector.y * distance)
    }

    private static func disc(at point: NSPoint, radius: CGFloat) -> [NSPoint] {
        NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                   width: radius * 2, height: radius * 2)).polygons()[0]
    }
}
