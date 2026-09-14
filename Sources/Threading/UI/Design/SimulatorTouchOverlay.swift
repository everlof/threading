import AppKit

/// What to draw for input right now: fading tap ripples and the live contact with its recent trail.
/// A plain value so the live pane overlay and the video recorder draw the exact same thing.
struct SimulatorTouchIndicators: Equatable {
    struct Ripple: Equatable {
        /// Normalized device point, top-left origin (the tap space).
        let point: CGPoint
        /// 0 at the tap, 1 as it finishes fading.
        let progress: Double
    }

    struct Contact: Equatable {
        let point: CGPoint
        /// Recent points of the live drag, oldest first.
        let trail: [CGPoint]
    }

    var ripples: [Ripple]
    var contact: Contact?

    var isEmpty: Bool { ripples.isEmpty && contact == nil }
}

/// Accumulates input events (a tap, or a drag's began/moved/ended) with timestamps and answers
/// "what should be drawn now". Single-contact, matching the simulator's one digitizer.
@MainActor
final class SimulatorTouchOverlayModel {
    static let rippleDuration: TimeInterval = 0.45
    static let trailDuration: TimeInterval = 0.35

    private struct TimedPoint { let point: CGPoint; let time: TimeInterval }
    private var ripples: [(point: CGPoint, bornAt: TimeInterval)] = []
    private var trail: [TimedPoint] = []
    private var contactActive = false

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func tap(at point: CGPoint) { ripples.append((point, now())) }

    func contactBegan(at point: CGPoint) {
        contactActive = true
        trail = [TimedPoint(point: point, time: now())]
    }

    func contactMoved(to point: CGPoint) {
        guard contactActive else { return }
        trail.append(TimedPoint(point: point, time: now()))
    }

    func contactEnded(at point: CGPoint) {
        guard contactActive else { return }
        contactActive = false
        trail.append(TimedPoint(point: point, time: now()))
        ripples.append((point, now()))
    }

    /// Whether anything is still animating, so the pane knows when to stop ticking.
    var hasActivity: Bool {
        let time = now()
        if contactActive { return true }
        if ripples.contains(where: { time - $0.bornAt < Self.rippleDuration }) { return true }
        return trail.contains { time - $0.time < Self.trailDuration }
    }

    /// The indicators to draw at the current moment, pruning anything fully faded.
    func indicators() -> SimulatorTouchIndicators {
        let time = now()
        ripples.removeAll { time - $0.bornAt >= Self.rippleDuration }
        let visibleRipples = ripples.compactMap { ripple -> SimulatorTouchIndicators.Ripple? in
            let progress = (time - ripple.bornAt) / Self.rippleDuration
            guard progress >= 0, progress < 1 else { return nil }
            return .init(point: ripple.point, progress: progress)
        }

        var contact: SimulatorTouchIndicators.Contact?
        let recent = trail.filter { time - $0.time < Self.trailDuration }.map(\.point)
        if contactActive || !recent.isEmpty, let head = recent.last ?? trail.last?.point {
            contact = .init(point: head, trail: recent)
        }
        if !contactActive { trail.removeAll { time - $0.time >= Self.trailDuration } }
        return SimulatorTouchIndicators(ripples: visibleRipples, contact: contact)
    }
}

/// Draws the indicators into the current `NSGraphicsContext` over the framebuffer rect — used by the
/// live view and by the recorder, so the movie matches the screen. The view is not flipped, so
/// normalized (y-down) points map with a y flip, the same as the other overlays.
@MainActor
enum SimulatorTouchMarks {
    private static let contactRadius: CGFloat = 15
    private static let rippleBaseRadius: CGFloat = 9
    private static let rippleGrowth: CGFloat = 28

    static func draw(_ indicators: SimulatorTouchIndicators, in target: NSRect) {
        guard !target.isEmpty, !indicators.isEmpty else { return }
        func viewPoint(_ normalized: CGPoint) -> CGPoint {
            CGPoint(
                x: target.minX + normalized.x * target.width,
                y: target.maxY - normalized.y * target.height
            )
        }

        if let contact = indicators.contact {
            if contact.trail.count >= 2 {
                let path = NSBezierPath()
                path.move(to: viewPoint(contact.trail[0]))
                for point in contact.trail.dropFirst() { path.line(to: viewPoint(point)) }
                path.lineWidth = 3
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                Design.Surface.accent.withAlphaComponent(0.35).setStroke()
                path.stroke()
            }
            let head = viewPoint(contact.point)
            let dot = NSBezierPath(ovalIn: NSRect(
                x: head.x - contactRadius, y: head.y - contactRadius,
                width: contactRadius * 2, height: contactRadius * 2
            ))
            Design.Surface.accent.withAlphaComponent(0.35).setFill()
            dot.fill()
            Design.Surface.accent.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }

        for ripple in indicators.ripples {
            let center = viewPoint(ripple.point)
            let radius = rippleBaseRadius + rippleGrowth * CGFloat(ripple.progress)
            let ring = NSBezierPath(ovalIn: NSRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
            ))
            ring.lineWidth = 2
            Design.Surface.accent.withAlphaComponent(CGFloat(1 - ripple.progress)).setStroke()
            ring.stroke()
        }
    }
}
