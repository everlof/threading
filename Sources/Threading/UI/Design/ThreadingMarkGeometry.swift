import AppKit

typealias ThreadingMarkPath = CGPath
private typealias MutableThreadingMarkPath = CGMutablePath

// MARK: - Threading Mark Geometry

/// The Threading mark stated as normalized geometry: the hexagonal shield, six thread strands
/// curving into the middle, and the solid core they meet at.
///
/// The same silhouette `Brand/ThreadingMark.svg` and `GeneratedAppIcon.drawThreadingMark`
/// state — coordinates in 0...1 with y up, so one set of numbers draws any size. Stated here
/// as `CGPath`s because this copy exists to *animate*: the icon draws once into a bitmap,
/// while the sidebar's mark strokes itself in on launch, and a `CAShapeLayer` needs each
/// strand as its own path.
enum ThreadingMarkGeometry {

    enum ParticleRole: Equatable {
        case outline
        case strand(Int)
        case core
    }

    struct ParticleSeed: Equatable {
        let point: CGPoint
        let role: ParticleRole
        /// Position on the path, from its outer/start point to its inner/end point. It is also
        /// the phase offset that keeps a run of dots evenly distributed while it travels.
        let progress: CGFloat
    }

    /// The display SVG's stroke weights on its 128pt canvas.
    static let outlineStrokeRatio: CGFloat = 7.0 / 128.0
    static let strandStrokeRatio: CGFloat = 7.5 / 128.0

    static let strandCount = 6

    /// The shield: six quadratic edges from the top vertex, stated as (end, control) pairs.
    private static let outlineStart = CGPoint(x: 0.5, y: 0.921875)
    private static let outlineEdges: [(end: CGPoint, control: CGPoint)] = [
        (CGPoint(x: 0.865390625, y: 0.7109375), CGPoint(x: 0.667109375, y: 0.789375)),
        (CGPoint(x: 0.865390625, y: 0.2890625), CGPoint(x: 0.834140625, y: 0.5)),
        (CGPoint(x: 0.5, y: 0.078125), CGPoint(x: 0.667109375, y: 0.210625)),
        (CGPoint(x: 0.134609375, y: 0.2890625), CGPoint(x: 0.332890625, y: 0.210625)),
        (CGPoint(x: 0.134609375, y: 0.7109375), CGPoint(x: 0.165859375, y: 0.5)),
        (CGPoint(x: 0.5, y: 0.921875), CGPoint(x: 0.332890625, y: 0.789375))
    ]

    /// One strand, outer end first — so a stroke-end animation draws it *inward*, which is
    /// the stitch the launch animation wants.
    private static let strandStart = CGPoint(x: 0.5, y: 0.90625)
    private static let strandControl1 = CGPoint(x: 0.515625, y: 0.7734375)
    private static let strandControl2 = CGPoint(x: 0.5234375, y: 0.6640625)
    private static let strandEnd = CGPoint(x: 0.45703125, y: 0.54296875)

    /// Slightly larger than the SVG's junction, for the same reason the app icon's is: it has
    /// to cover the strands' endpoints so the centre reads genuinely solid.
    private static let coreVertices: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.575),
        CGPoint(x: 0.5649519, y: 0.5375),
        CGPoint(x: 0.5649519, y: 0.4625),
        CGPoint(x: 0.5, y: 0.425),
        CGPoint(x: 0.4350481, y: 0.4625),
        CGPoint(x: 0.4350481, y: 0.5375)
    ]

    static func outlinePath(in rect: CGRect) -> ThreadingMarkPath {
        let path = MutableThreadingMarkPath()
        path.move(to: point(outlineStart, rect))
        for edge in outlineEdges {
            path.addQuadCurve(to: point(edge.end, rect), control: point(edge.control, rect))
        }
        path.closeSubpath()
        return path
    }

    /// The six strands as separate paths, so each can draw in on its own beat.
    static func strandPaths(in rect: CGRect) -> [ThreadingMarkPath] {
        (0..<strandCount).map { turn in
            let path = MutableThreadingMarkPath()
            path.move(to: point(rotated(strandStart, turns: turn), rect))
            path.addCurve(
                to: point(rotated(strandEnd, turns: turn), rect),
                control1: point(rotated(strandControl1, turns: turn), rect),
                control2: point(rotated(strandControl2, turns: turn), rect)
            )
            return path
        }
    }

    static func corePath(in rect: CGRect) -> ThreadingMarkPath {
        let path = MutableThreadingMarkPath()
        path.move(to: point(coreVertices[0], rect))
        for vertex in coreVertices.dropFirst() {
            path.addLine(to: point(vertex, rect))
        }
        path.closeSubpath()
        return path
    }

    /// An adaptive dotted statement of the canonical mark. The counts are chosen by the view:
    /// the sidebar needs fewer, larger points than the gallery's inspection size, but neither
    /// invents geometry here. Core returns its six vertices plus the knot at their centre.
    static func particleSeeds(outlineCount: Int, strandCount: Int) -> [ParticleSeed] {
        let safeOutlineCount = max(outlineEdges.count, outlineCount)
        let safeStrandCount = max(2, strandCount)

        let outline = (0..<safeOutlineCount).map { index in
            let progress = CGFloat(index) / CGFloat(safeOutlineCount)
            return ParticleSeed(
                point: outlinePoint(at: progress),
                role: .outline,
                progress: progress
            )
        }

        let strands = (0..<self.strandCount).flatMap { turn in
            (0..<safeStrandCount).map { index in
                // The moving field is periodic: including both 0 and 1 would place two dots
                // on the same outer endpoint as soon as the animation wraps. The core's own
                // seven points close the tiny gap at the inner end.
                let progress = CGFloat(index) / CGFloat(safeStrandCount)
                return ParticleSeed(
                    point: strandPoint(turn: turn, at: progress),
                    role: .strand(turn),
                    progress: progress
                )
            }
        }

        let core = coreVertices.enumerated().map { index, vertex in
            ParticleSeed(
                point: vertex,
                role: .core,
                progress: CGFloat(index) / CGFloat(coreVertices.count)
            )
        } + [ParticleSeed(point: CGPoint(x: 0.5, y: 0.5), role: .core, progress: 1)]

        return outline + strands + core
    }

    static func particlePoint(for seed: ParticleSeed, progress: CGFloat, in rect: CGRect) -> CGPoint {
        let wrapped = progress - floor(progress)
        let normalized: CGPoint
        switch seed.role {
        case .outline:
            normalized = outlinePoint(at: wrapped)
        case .strand(let turn):
            normalized = strandPoint(turn: turn, at: min(max(progress, 0), 1))
        case .core:
            normalized = seed.point
        }
        return point(normalized, rect)
    }

    // MARK: - Private Methods

    private static func rotated(_ value: CGPoint, turns: Int) -> CGPoint {
        let angle = -CGFloat(turns) * .pi / 3
        let dx = value.x - 0.5
        let dy = value.y - 0.5
        return CGPoint(
            x: 0.5 + dx * cos(angle) - dy * sin(angle),
            y: 0.5 + dx * sin(angle) + dy * cos(angle)
        )
    }

    private static func point(_ normalized: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * normalized.x,
            y: rect.minY + rect.height * normalized.y
        )
    }

    private static func outlinePoint(at progress: CGFloat) -> CGPoint {
        let wrapped = progress - floor(progress)
        let scaled = wrapped * CGFloat(outlineEdges.count)
        let index = min(outlineEdges.count - 1, Int(scaled))
        let local = scaled - CGFloat(index)
        let start = index == 0 ? outlineStart : outlineEdges[index - 1].end
        let edge = outlineEdges[index]
        return quadratic(from: start, control: edge.control, to: edge.end, at: local)
    }

    private static func strandPoint(turn: Int, at progress: CGFloat) -> CGPoint {
        rotated(
            cubic(
                from: strandStart,
                control1: strandControl1,
                control2: strandControl2,
                to: strandEnd,
                at: min(max(progress, 0), 1)
            ),
            turns: turn
        )
    }

    private static func quadratic(
        from start: CGPoint,
        control: CGPoint,
        to end: CGPoint,
        at progress: CGFloat
    ) -> CGPoint {
        let remaining = 1 - progress
        return CGPoint(
            x: remaining * remaining * start.x
                + 2 * remaining * progress * control.x
                + progress * progress * end.x,
            y: remaining * remaining * start.y
                + 2 * remaining * progress * control.y
                + progress * progress * end.y
        )
    }

    private static func cubic(
        from start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to end: CGPoint,
        at progress: CGFloat
    ) -> CGPoint {
        let remaining = 1 - progress
        return CGPoint(
            x: remaining * remaining * remaining * start.x
                + 3 * remaining * remaining * progress * control1.x
                + 3 * remaining * progress * progress * control2.x
                + progress * progress * progress * end.x,
            y: remaining * remaining * remaining * start.y
                + 3 * remaining * remaining * progress * control1.y
                + 3 * remaining * progress * progress * control2.y
                + progress * progress * progress * end.y
        )
    }
}
