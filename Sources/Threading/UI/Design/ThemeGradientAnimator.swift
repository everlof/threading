import QuartzCore
import ThreadingRemoteKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Shared compositor adapter. Platforms own visibility/accessibility policy; this owns the
/// motion geometry and never schedules a timer or calls back into a view tree.
@MainActor
final class ThemeGradientAnimator {
    static let animationKey = "threading.backdrop.drift"
    private weak var layer: CAGradientLayer?
    private var angleDegrees = 180.0
    private var flipped = false
    private var drift: ThemeGradientDrift?
    private var active = false
    private var frozenPhase: Double?

    init(layer: CAGradientLayer) { self.layer = layer }

    func configure(
        angleDegrees: Double,
        flipped: Bool,
        drift: ThemeGradientDrift?,
        frozenPhase: Double? = nil
    ) {
        let validDrift = drift.flatMap { $0.isValid ? $0 : nil }
        guard self.angleDegrees != angleDegrees || self.flipped != flipped
            || self.drift != validDrift || self.frozenPhase != frozenPhase else { return }
        self.angleDegrees = angleDegrees
        self.flipped = flipped
        self.drift = validDrift
        self.frozenPhase = frozenPhase
        apply()
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        apply()
    }

    /// The owner is replacing/removing this decoration and has already stated its new model
    /// geometry. Remove only our presentation, without restoring the departing theme's points.
    func stop() {
        active = false
        layer?.removeAnimation(forKey: Self.animationKey)
    }

    private func apply() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        let points = ThemeGradientGeometry.endpoints(
            angleDegrees: angleDegrees, flipped: flipped,
            drift: drift, phase: frozenPhase ?? 0
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.startPoint = points.start
        layer.endPoint = points.end
        CATransaction.commit()
        guard active, frozenPhase == nil, let drift else { return }
        let frames = ThemeGradientDrift.phases.map {
            ThemeGradientGeometry.endpoints(
                angleDegrees: angleDegrees, flipped: flipped, drift: drift, phase: $0
            )
        }
        func animation(_ keyPath: String, points: [CGPoint]) -> CAKeyframeAnimation {
            let result = CAKeyframeAnimation(keyPath: keyPath)
            result.values = points.map {
                #if canImport(UIKit)
                NSValue(cgPoint: $0)
                #else
                NSValue(point: $0)
                #endif
            }
            result.keyTimes = ThemeGradientDrift.phases.map(NSNumber.init(value:))
            // Slow at the two turning points, keep travelling through the centre. Easing
            // in and out at every keyframe would pause twice more during each cycle.
            result.timingFunctions = (0..<(frames.count - 1)).map {
                CAMediaTimingFunction(name: $0.isMultiple(of: 2) ? .easeOut : .easeIn)
            }
            result.duration = drift.duration
            return result
        }
        let group = CAAnimationGroup()
        group.animations = [
            animation("startPoint", points: frames.map(\.start)),
            animation("endPoint", points: frames.map(\.end))
        ]
        group.duration = drift.duration
        group.repeatCount = .infinity
        layer.add(group, forKey: Self.animationKey)
    }
}
