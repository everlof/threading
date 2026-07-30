import AppKit

/// A switch drawn from the theme, replacing `NSSwitch`.
///
/// `NSSwitch` takes the *system* accent for its on-state, which is the single most visible way a
/// styled app betrays that its theme is only skin deep — a page of system-blue switches on a
/// Cyberpunk-green or Swiss-red surface. This draws the on-track in the theme's own accent.
///
/// A drop-in for the call sites it replaces: it is an `NSControl` with the same `state`
/// property and the same target/action, so `toggle.state == .on` and the action selector keep
/// working unchanged.
///
/// The flip is animated, and from `draw(_:)` rather than Core Animation on purpose: a layer
/// animation interpolates frozen `CGColor`s, which is exactly the staleness `ThemedControl`
/// exists to prevent. An eased progress value drives redraws for the travel — the knob swells
/// slightly mid-flight and settles a hair past its end, while the track crossfades between its
/// two fills so the colour arrives with the knob rather than jumping under it. Only an
/// *interaction* animates; assigning `state` lands in one frame, so a settings page configuring
/// itself does not sweep every switch it builds. Reduce Motion zeroes the duration through
/// `Design.Motion`, leaving one path and one final state.
final class ThemedToggle: ThemedControl {

    // MARK: - Geometry

    /// Internal rather than private: the motion tests pin the knob inside this geometry.
    enum Layout {
        static let width: CGFloat = 38
        static let height: CGFloat = 22
        static let knobInset: CGFloat = 2
        /// How far the knob travels when the theme's corners are square (Swiss), so the switch
        /// picks up the same silhouette as everything else.
        static let squareKnobRadius: CGFloat = 2
    }

    // MARK: - Motion

    /// The travel and the swell as pure curves, so the feel is testable without a clock and
    /// containment — a knob that must never leave its track — is a checkable fact rather than
    /// a tuning accident.
    enum Motion {

        /// Eased travel through the flip: fast to leave, gentle to arrive, and a small settle
        /// past the end and back — the settle is what reads as weight rather than a slide.
        static func position(at phase: CGFloat) -> CGFloat {
            let u = phase - 1
            return 1 + (settle + 1) * u * u * u + settle * u * u
        }

        /// The knob's scale through the flip: swells to `peakKnobScale` mid-travel and lands
        /// at resting size, so both endpoints keep the inset exactly.
        static func knobScale(at phase: CGFloat) -> CGFloat {
            1 + (peakKnobScale - 1) * sin(.pi * min(max(phase, 0), 1))
        }

        static let peakKnobScale: CGFloat = 1.12

        /// Overshoot and swell both spend the knob inset, and they peak near each other, so
        /// this stays small — the tests pin their compound worst case inside the track.
        private static let settle: CGFloat = 1.2
    }

    // MARK: - State

    /// Mirrors `NSSwitch.state`, so `toggle.state == .on` reads unchanged at the call sites this
    /// replaces. Declared here rather than overridden — `NSControl` itself has no `state`.
    var state: NSControl.StateValue = .off {
        didSet {
            if state != oldValue {
                let animated = animatesNextStateChange
                animatesNextStateChange = false
                moveKnob(to: isOn ? 1 : 0, animated: animated)
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
            needsDisplay = true
        }
    }

    private var isOn: Bool { state == .on }

    /// Where the knob is drawn, 0 off → 1 on — briefly outside that range while the settle
    /// carries it past its end. Follows `state` immediately on assignment, eased behind an
    /// interaction.
    private(set) var knobProgress: CGFloat = 0

    /// Time through the in-flight animation, 0 → 1; held at 1 while idle, where the swell
    /// reads as zero.
    private var animationPhase: CGFloat = 1
    private var animationFrom: CGFloat = 0
    private var animationTarget: CGFloat = 0
    private var animationStart: CFTimeInterval = 0
    private var animationDuration: TimeInterval = 0
    private var animatesNextStateChange = false

    /// The frame source while the knob is in flight — a display link on 14+, a 60Hz timer on
    /// 13, the `ThinkingOrbs` pattern. Runs only for the travel itself; both retain the view,
    /// which is why completion and window removal each stop it.
    private var displayLink: Any? // CADisplayLink, stored untyped for macOS 13
    private var fallbackTimer: Timer?

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.width, height: Layout.height)
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        _ = performPrimaryAction()
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        animatesNextStateChange = true
        state = isOn ? .off : .on
        sendAction(action, to: target)
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn }

    /// A drawn control has no cell to inherit this from, so the press has to be routed by hand or
    /// the switch can be read but never flipped without a pointer.
    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    // MARK: - Animation

    private func moveKnob(to target: CGFloat, animated: Bool) {
        stopDriver()
        let duration = Design.Motion.standard
        guard animated, duration > 0, window != nil, knobProgress != target else {
            knobProgress = target
            animationPhase = 1
            return
        }
        animationFrom = knobProgress
        animationTarget = target
        animationDuration = duration
        animationStart = CACurrentMediaTime()
        animationPhase = 0
        startDriver()
    }

    /// One frame of travel, split from the tick so tests can drive the clock by hand. Starting
    /// from the *drawn* position rather than an endpoint is what keeps a rapid re-click smooth:
    /// the knob turns around mid-track instead of jumping to either end first.
    func advanceAnimation(now: CFTimeInterval) {
        guard animationPhase < 1 else { return }
        let phase = min(1, CGFloat((now - animationStart) / animationDuration))
        animationPhase = phase
        knobProgress = animationFrom + (animationTarget - animationFrom) * Motion.position(at: phase)
        if phase >= 1 {
            knobProgress = animationTarget
            stopDriver()
        }
        needsDisplay = true
    }

    @objc private func tick() {
        advanceAnimation(now: CACurrentMediaTime())
    }

    private func startDriver() {
        guard displayLink == nil, fallbackTimer == nil else { return }
        if #available(macOS 14.0, *) {
            let link = self.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(tick),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func stopDriver() {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    /// A driver retains its target, so a toggle leaving the window lands its knob and stops
    /// rather than animating unseen — or, timer-driven, never deallocating.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, animationPhase < 1 {
            knobProgress = animationTarget
            animationPhase = 1
            stopDriver()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(
            x: (bounds.width - Layout.width) / 2,
            y: (bounds.height - Layout.height) / 2,
            width: Layout.width,
            height: Layout.height
        )

        // Square corners follow the theme's material, so a Swiss switch is a rounded-rect and a
        // Cyberpunk one is nearly a stadium — the same corner language as its cards and chips.
        let square = AppThemePalette.current.material.panelRadius == 0
        let trackRadius = square ? Layout.squareKnobRadius : rect.height / 2

        // The drawn position is unclamped — the settle carries the knob a hair past its end —
        // while everything that *fades* reads the clamped value: a fill cannot be 104% accent.
        let arrived = min(max(knobProgress, 0), 1)

        let trackShape = ThemedSurface.Shape(rect: rect, radius: trackRadius)
        let track = trackShape.path
        trackFill(arrived: arrived).setFill()
        track.fill()

        if arrived < 1 {
            // A hairline keeps the off-state legible where the track and the surface behind it
            // are close in tone — a pale switch on a pale card. It fades as the accent arrives.
            faded(Design.Surface.border, to: 1 - arrived).setStroke()
            track.lineWidth = 1
            track.stroke()
        }
        drawKeyboardFocus(
            around: trackShape,
            color: isOn ? Design.Text.selected : Design.Surface.accent
        )

        let knobDiameter = rect.height - Layout.knobInset * 2
        let travel = Layout.width - knobDiameter - Layout.knobInset * 2
        let grow = knobDiameter * (Motion.knobScale(at: animationPhase) - 1) / 2
        let knobRect = NSRect(
            x: rect.minX + Layout.knobInset + travel * knobProgress,
            y: rect.minY + Layout.knobInset,
            width: knobDiameter,
            height: knobDiameter
        ).insetBy(dx: -grow, dy: -grow)
        let knobRadius = square ? Layout.squareKnobRadius : knobRect.height / 2
        let knob = NSBezierPath(roundedRect: knobRect, xRadius: knobRadius, yRadius: knobRadius)

        // The knob is the ground colour, so it reads against both an accent track and a neutral
        // one, on a light theme and a dark one alike — the ground is by definition the tone
        // furthest from the surfaces stacked on it.
        Design.Surface.ground.setFill()
        knob.fill()

        if arrived > 0, Design.Accessibility.differentiatesWithoutColor {
            // Position already distinguishes the state; the tick makes that distinction
            // explicit for a user who asked the system not to rely on colour. It lives inside
            // the knob so the control keeps the active theme's silhouette — its geometry rides
            // `knobRect` so it swells with the knob, and its ink follows arrival so the state
            // fades rather than pops.
            let mark = NSBezierPath()
            mark.move(
                to: NSPoint(x: knobRect.minX + knobRect.width * 0.28, y: knobRect.midY)
            )
            mark.line(
                to: NSPoint(
                    x: knobRect.minX + knobRect.width * 0.44,
                    y: knobRect.minY + knobRect.height * 0.34
                )
            )
            mark.line(
                to: NSPoint(
                    x: knobRect.minX + knobRect.width * 0.73,
                    y: knobRect.minY + knobRect.height * 0.68
                )
            )
            mark.lineWidth = 1.5
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            faded(Design.Surface.accent, to: arrived).setStroke()
            mark.stroke()
        }

        alphaValue = isEnabled ? 1 : 0.5
    }

    // MARK: - Colour

    private func trackFill(arrived: CGFloat) -> NSColor {
        let off = Design.Surface.controlHover
        let on = Design.Surface.accent
        if arrived <= 0 { return off }
        if arrived >= 1 { return on }
        // `blended` resolves under the current drawing appearance, so the crossfade follows a
        // live theme switch like any other draw-time read.
        return off.blended(withFraction: arrived, of: on) ?? (isOn ? on : off)
    }

    /// `withAlphaComponent` *replaces* alpha, and both faded inks here start from roles that
    /// may already be translucent — resolve, then multiply.
    private func faded(_ color: NSColor, to fraction: CGFloat) -> NSColor {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return resolved.withAlphaComponent(resolved.alphaComponent * fraction)
    }
}
