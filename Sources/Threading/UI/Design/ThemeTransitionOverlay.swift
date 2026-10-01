import AppKit
import QuartzCore

/// Draws the incoming wash at display time, so a theme colour is never stored in a layer's
/// backgroundColor. The overlay is removed after one transition.
private final class ThemeTransitionWashLayer: CALayer {
    var wash: NSColor = .clear {
        didSet { setNeedsDisplay() }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? ThemeTransitionWashLayer { wash = other.wash }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(in context: CGContext) {
        context.setFillColor(wash.cgColor)
        context.fill(bounds)
    }
}

// MARK: - Theme Transition Overlay

/// The surface a switch *into* a theme is played on — `ThemeTransition` drawn over one window.
///
/// Three layers over the window's whole content root, all colours already resolved from the
/// *incoming* variant before the switch happens:
///
/// 1. a **wash** that rises toward the incoming ground (or the theme's stated wash) and falls
///    away again — at its peak it is what makes the repaint underneath read as a dissolve
///    rather than a cut;
/// 2. an optional **shimmer**, a diagonal band of the particles' first ink with a bright core,
///    sweeping the window and crossing its middle at the swap;
/// 3. the **particles**, born across the window's edge for the first part of the timeline and
///    left to finish their flight.
///
/// The swap itself is not this view's: `ThemeTransitionPresenter` applies the theme at
/// `Design.Motion.themeTransitionSwapFraction` of the duration, when the wash is highest. The
/// three animations run in the render server, so the main-thread repaint the swap costs does
/// not stall them — the stall is hidden under the one thing still moving.
///
/// **Not a cover, not a control.** It takes no clicks (`hitTest` is nil), claims no pointer,
/// is not an accessibility element, and never outlives its timeline: `play` ends in `remove`.
/// A second switch while one plays is the presenter's to settle, by finishing this one first.
///
/// Hosted *inside* the window's content root rather than in a child window of its own, because
/// the window server clips a window's content to its rounded frame and would not clip a child:
/// a full-window wash in a child window showed square corners standing past the host's curve.
final class ThemeTransitionOverlayView: NSView, ThemedComponent {

    // MARK: - Properties

    /// The colours and shape of one play, resolved from the incoming variant.
    struct Palette {
        let transition: ThemeTransition
        let particleColors: [NSColor]
        let wash: NSColor
        let shimmer: NSColor
    }

    private let washLayer = ThemeTransitionWashLayer()
    private let shimmerLayer = CAGradientLayer()
    private let emitter = CAEmitterLayer()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Sized by its host's bounds directly: the timeline starts in the same turn the view is
        // installed, before any layout pass would have given a constrained view a frame.
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.masksToBounds = true
        washLayer.opacity = 0
        shimmerLayer.opacity = 0
        emitter.birthRate = 0
        layer?.addSublayer(washLayer)
        layer?.addSublayer(shimmerLayer)
        layer?.addSublayer(emitter)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - Public Methods

    /// Plays the whole timeline over the view's current bounds. `completion` runs once the
    /// last particle born could have finished its flight.
    func play(_ palette: Palette, completion: @escaping () -> Void) {
        let region = bounds
        let duration = Design.Motion.themeTransition(palette.transition.duration)
        guard duration > 0, region.width > 0, region.height > 0 else {
            completion()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        washLayer.frame = region
        washLayer.wash = palette.wash
        washLayer.displayIfNeeded()
        emitter.frame = region
        configureShimmer(palette, in: region)
        let particles = palette.transition.particles
        ThemeParticleEmitter.configure(
            emitter,
            particles: particles,
            colors: palette.particleColors,
            placement: .transition(duration: duration),
            region: region,
            scale: window?.backingScaleFactor ?? 2,
            rate: ThemeParticleEmitter.transitionRate(
                for: particles,
                region: region.size,
                duration: duration
            ),
            opacity: particles.opacity,
            up: ThemeParticleEmitter.upSign(of: emitter)
        )
        CATransaction.commit()

        let swap = Design.Motion.themeTransitionSwapFraction

        let wash = CAKeyframeAnimation(keyPath: "opacity")
        wash.values = [0, palette.transition.washOpacity, palette.transition.washOpacity, 0]
        wash.keyTimes = [0, NSNumber(value: swap), NSNumber(value: swap + 0.08), 1]
        wash.duration = Design.Motion.themeTransition(palette.transition.duration)
        wash.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeOut)
        ]
        washLayer.add(wash, forKey: "wash")

        // Births stop a little after the swap; the ones already in flight finish, which is
        // what carries the motion across the new theme instead of ending on the cut.
        let births = CAKeyframeAnimation(keyPath: "birthRate")
        births.values = [0, 1, 1, 0]
        births.keyTimes = [0, 0.06, NSNumber(value: swap + 0.08), NSNumber(value: swap + 0.2)]
        births.duration = Design.Motion.themeTransition(palette.transition.duration)
        emitter.add(births, forKey: "births")

        if palette.transition.shimmer {
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = region.minX - region.width
            sweep.toValue = region.maxX + region.width
            sweep.duration = Design.Motion.themeTransition(palette.transition.duration)
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shimmerLayer.add(sweep, forKey: "sweep")

            let presence = CAKeyframeAnimation(keyPath: "opacity")
            presence.values = [0, 1, 1, 0]
            presence.keyTimes = [0, 0.15, 0.85, 1]
            presence.duration = Design.Motion.themeTransition(palette.transition.duration)
            shimmerLayer.add(presence, forKey: "presence")
        }

        let lifetime = TimeInterval(emitter.emitterCells?.first?.lifetime ?? 0)
        let end = max(duration, duration * (swap + 0.2) + lifetime)
        DispatchQueue.main.asyncAfter(deadline: .now() + end) { [weak self] in
            self?.removeFromSuperview()
            completion()
        }
    }

    // MARK: - Private Methods

    /// A band wider than the window's diagonal, tilted, so its sweep crosses every pixel.
    private func configureShimmer(_ palette: Palette, in region: CGRect) {
        guard palette.transition.shimmer else {
            shimmerLayer.isHidden = true
            return
        }
        shimmerLayer.isHidden = false
        let diagonal = hypot(region.width, region.height)
        shimmerLayer.bounds = CGRect(x: 0, y: 0, width: region.width * 0.5, height: diagonal * 1.4)
        shimmerLayer.position = CGPoint(x: region.minX - region.width, y: region.midY)
        shimmerLayer.transform = CATransform3DMakeRotation(-.pi / 9, 0, 0, 1)
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        let ink = palette.shimmer.usingColorSpace(.sRGB) ?? palette.shimmer
        let core = ink.blended(withFraction: 0.65, of: .white) ?? ink
        shimmerLayer.colors = [
            ink.withAlphaComponent(0).cgColor,
            ink.withAlphaComponent(0.35).cgColor,
            core.withAlphaComponent(0.8).cgColor,
            ink.withAlphaComponent(0.35).cgColor,
            ink.withAlphaComponent(0).cgColor
        ]
        shimmerLayer.locations = [0, 0.35, 0.5, 0.65, 1]
    }
}
