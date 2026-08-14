import CoreGraphics
import Foundation

/// Reads an animated property at a frame.
///
/// Split from both the parser and the rasterizer because it is the part that has to be exactly
/// right and is cheap to test on its own: an easing curve solved a little wrong looks like a
/// rendering bug and is arithmetic.
enum LottieEvaluator {

    static func value(of scalar: LottieScalar, at frame: Double) -> Double {
        interpolate(scalar, at: frame, fallback: 0) { $0 + ($1 - $0) * $2 }
    }

    static func value(of vector: LottieVector, at frame: Double) -> [Double] {
        interpolate(vector, at: frame, fallback: []) { start, end, progress in
            let count = max(start.count, end.count)
            return (0..<count).map { index in
                let a = index < start.count ? start[index] : 0
                let b = index < end.count ? end[index] : a
                return a + (b - a) * progress
            }
        }
    }

    static func bezier(of path: LottiePath, at frame: Double) -> LottieBezier {
        interpolate(path, at: frame, fallback: .empty) { start, end, progress in
            // Vertex counts have to match for a shape morph to mean anything. When they do not,
            // the nearer keyframe is shown rather than a shape interpolated between two
            // different topologies, which is how a morph turns into a scribble.
            guard start.vertices.count == end.vertices.count,
                  start.inTangents.count == end.inTangents.count,
                  start.outTangents.count == end.outTangents.count else {
                return progress < 0.5 ? start : end
            }
            return LottieBezier(
                vertices: zip(start.vertices, end.vertices).map {
                    lerp($0, $1, progress)
                },
                inTangents: zip(start.inTangents, end.inTangents).map {
                    lerp($0, $1, progress)
                },
                outTangents: zip(start.outTangents, end.outTangents).map {
                    lerp($0, $1, progress)
                },
                isClosed: start.isClosed
            )
        }
    }

    // MARK: - Core

    /// `fallback` is what an empty keyframe list is worth. The parser never builds one, and a
    /// trap here would still be a crash reachable from a document an agent wrote — so the caller
    /// names the type's own zero instead.
    static func interpolate<Value: Sendable>(
        _ animated: LottieAnimated<Value>,
        at frame: Double,
        fallback: Value,
        lerp: (Value, Value, Double) -> Value
    ) -> Value {
        switch animated {
        case .fixed(let value):
            return value
        case .keyframes(let frames):
            guard let first = frames.first else { return fallback }
            if frame <= first.time { return first.value }
            guard let last = frames.last else { return first.value }
            if frame >= last.time { return last.endValue ?? last.value }

            var index = 0
            for (position, keyframe) in frames.enumerated() where keyframe.time <= frame {
                index = position
            }
            let start = frames[index]
            guard index + 1 < frames.count else { return start.endValue ?? start.value }
            let end = frames[index + 1]
            if start.isHold { return start.value }

            let span = end.time - start.time
            guard span > 0 else { return end.value }
            let linear = (frame - start.time) / span
            let eased = ease(
                linear,
                out: start.outControl,
                in: start.inControl
            )
            return lerp(start.value, start.endValue ?? end.value, eased)
        }
    }

    /// The cubic-bezier easing bodymovin writes as an out control on the keyframe being left and
    /// an in control on the one being entered.
    ///
    /// Solved by bisection rather than Newton: the curve is evaluated a few dozen times per
    /// property per frame at most, the interval is known to bracket the answer, and bisection
    /// cannot diverge on the degenerate control points real documents contain.
    static func ease(_ progress: Double, out: CGPoint?, in inControl: CGPoint?) -> Double {
        guard let out, let inControl else { return progress }
        let x1 = min(max(Double(out.x), 0), 1)
        let y1 = Double(out.y)
        let x2 = min(max(Double(inControl.x), 0), 1)
        let y2 = Double(inControl.y)
        if x1 == y1 && x2 == y2 { return progress }

        var low = 0.0
        var high = 1.0
        var t = progress
        for _ in 0..<24 {
            let x = bezierComponent(t, x1, x2)
            if abs(x - progress) < 0.0001 { break }
            if x < progress { low = t } else { high = t }
            t = (low + high) / 2
        }
        return bezierComponent(t, y1, y2)
    }

    private static func bezierComponent(_ t: Double, _ c1: Double, _ c2: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * c1
            + 3 * inverse * t * t * c2
            + t * t * t
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(
            x: a.x + (b.x - a.x) * CGFloat(t),
            y: a.y + (b.y - a.y) * CGFloat(t)
        )
    }
}
