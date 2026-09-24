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

extension Design {
    /// Touch marks are drawn over device content, not over the app's chrome, and they are burned
    /// into movies that outlive whichever theme was active — so their colours are fixed values,
    /// and every mark carries an edge of the opposite polarity to stay visible on any screen.
    /// The accent is the one theme-derived choice, resolved at draw time.
    @MainActor
    enum SimulatorTouch {
        private enum Palette {
            static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            static let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            static let red = NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)
            static let orange = NSColor(srgbRed: 1, green: 0.584, blue: 0, alpha: 1)
            static let yellow = NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
            static let green = NSColor(srgbRed: 0.204, green: 0.78, blue: 0.349, alpha: 1)
            static let blue = NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
            static let pink = NSColor(srgbRed: 1, green: 0.176, blue: 0.333, alpha: 1)
        }

        /// How much of the contact disc is filled, so the content under a finger stays readable.
        static let contactFillAlpha: CGFloat = 0.35
        static let trailAlpha: CGFloat = 0.45
        static let edgeAlpha: CGFloat = 0.45

        static func color(_ choice: SimulatorTouchStyle.Color) -> NSColor {
            switch choice {
            case .accent: Surface.accent.withAlphaComponent(1)
            case .white: Palette.white
            case .black: Palette.black
            case .red: Palette.red
            case .orange: Palette.orange
            case .yellow: Palette.yellow
            case .green: Palette.green
            case .blue: Palette.blue
            case .pink: Palette.pink
            }
        }

        /// The contrasting edge: light around the one dark choice, dark around everything else.
        static func edge(_ choice: SimulatorTouchStyle.Color) -> NSColor {
            (choice == .black ? Palette.white : Palette.black).withAlphaComponent(edgeAlpha)
        }

        /// The colour's display name, for menus and accessibility.
        static func name(_ choice: SimulatorTouchStyle.Color) -> String {
            switch choice {
            case .accent: L10n.string("Accent Color")
            case .white: L10n.string("White")
            case .black: L10n.string("Black")
            case .red: L10n.string("Red")
            case .orange: L10n.string("Orange")
            case .yellow: L10n.string("Yellow")
            case .green: L10n.string("Green")
            case .blue: L10n.string("Blue")
            case .pink: L10n.string("Pink")
            }
        }

        static func name(_ size: SimulatorTouchStyle.Size) -> String {
            switch size {
            case .small: L10n.string("Small")
            case .medium: L10n.string("Medium")
            case .large: L10n.string("Large")
            }
        }

        /// A small disc of the colour with its edge, for a menu row. Drawn when the menu paints,
        /// so the accent follows a theme switch rather than freezing at construction.
        static func swatch(_ choice: SimulatorTouchStyle.Color) -> NSImage {
            let side = ThemedMenuMetrics.imageSize
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let disc = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
                color(choice).setFill()
                disc.fill()
                edge(choice).setStroke()
                disc.lineWidth = 1
                disc.stroke()
                return true
            }
            image.accessibilityDescription = name(choice)
            return image
        }
    }
}

/// Draws the indicators into the current `NSGraphicsContext` over the framebuffer rect — used by the
/// live view, the presenter window and the recorder, so the movie matches the screen. The view is
/// not flipped, so normalized (y-down) points map with a y flip, the same as the other overlays.
///
/// Every measurement is a fraction of the screen's short side rather than a point size. The live
/// pane draws a device a few hundred points wide while the recorder draws the full-resolution
/// framebuffer, and fixed radii made a finger in the movie a third of the size it was on screen.
@MainActor
enum SimulatorTouchMarks {
    /// About a fingertip on an iPhone: a 40pt disc on a 393pt-wide screen.
    private static let contactRadiusFraction: CGFloat = 0.05
    private static let minimumContactRadius: CGFloat = 5
    private static let trailWidthFraction: CGFloat = 0.28
    private static let rippleBaseFraction: CGFloat = 0.6
    private static let rippleGrowthFraction: CGFloat = 1.9
    private static let strokeFraction: CGFloat = 0.12
    private static let edgeFraction: CGFloat = 0.1

    /// The contact radius a style gives on a screen of this size, exposed so a test can check the
    /// live view and the recorder agree on proportions.
    static func contactRadius(in target: NSRect, style: SimulatorTouchStyle) -> CGFloat {
        let side = min(target.width, target.height)
        return max(minimumContactRadius, side * contactRadiusFraction * CGFloat(style.size.scale))
    }

    static func draw(
        _ indicators: SimulatorTouchIndicators,
        in target: NSRect,
        style: SimulatorTouchStyle = .standard
    ) {
        guard !target.isEmpty, !indicators.isEmpty else { return }
        func viewPoint(_ normalized: CGPoint) -> CGPoint {
            CGPoint(
                x: target.minX + normalized.x * target.width,
                y: target.maxY - normalized.y * target.height
            )
        }
        let color = Design.SimulatorTouch.color(style.color)
        let edge = Design.SimulatorTouch.edge(style.color)
        let radius = contactRadius(in: target, style: style)
        let stroke = max(1, radius * strokeFraction)
        let edgeWidth = max(0.5, radius * edgeFraction)

        if let contact = indicators.contact {
            if style.showsTrail, contact.trail.count >= 2 {
                let path = NSBezierPath()
                path.move(to: viewPoint(contact.trail[0]))
                for point in contact.trail.dropFirst() { path.line(to: viewPoint(point)) }
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                let width = max(1.5, radius * trailWidthFraction)
                path.lineWidth = width + edgeWidth * 2
                edge.withAlphaComponent(Design.SimulatorTouch.edgeAlpha / 2).setStroke()
                path.stroke()
                path.lineWidth = width
                color.withAlphaComponent(Design.SimulatorTouch.trailAlpha).setStroke()
                path.stroke()
            }
            let head = viewPoint(contact.point)
            let dot = NSBezierPath(ovalIn: NSRect(
                x: head.x - radius, y: head.y - radius,
                width: radius * 2, height: radius * 2
            ))
            color.withAlphaComponent(Design.SimulatorTouch.contactFillAlpha).setFill()
            dot.fill()
            dot.lineWidth = stroke + edgeWidth * 2
            edge.setStroke()
            dot.stroke()
            dot.lineWidth = stroke
            color.setStroke()
            dot.stroke()
        }

        for ripple in indicators.ripples {
            let center = viewPoint(ripple.point)
            let rippleRadius = radius * (rippleBaseFraction + rippleGrowthFraction * CGFloat(ripple.progress))
            let ring = NSBezierPath(ovalIn: NSRect(
                x: center.x - rippleRadius, y: center.y - rippleRadius,
                width: rippleRadius * 2, height: rippleRadius * 2
            ))
            let fade = CGFloat(1 - ripple.progress)
            ring.lineWidth = stroke + edgeWidth * 2
            edge.withAlphaComponent(Design.SimulatorTouch.edgeAlpha * fade).setStroke()
            ring.stroke()
            ring.lineWidth = stroke
            color.withAlphaComponent(fade).setStroke()
            ring.stroke()
        }
    }
}
