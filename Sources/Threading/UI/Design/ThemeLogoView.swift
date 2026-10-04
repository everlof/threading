import AppKit
import QuartzCore

// MARK: - Theme Logo View

/// A theme's own logo in the sidebar's brand slot — and, when the theme says so, a logo that
/// moves (`SidebarStyle.Brand.LogoMotion`).
///
/// It answers the same three moments the Threading mark does — the pointer arriving, a press,
/// the sidebar's first appearance — with whichever beat the theme names for each, and it gives
/// off the theme's particles: a stream while hovered, a burst on a press and at launch, and,
/// when the theme asks, a stream that follows the agents at work (quiet at one, busier at
/// five). A bottle that fizzes harder the more is going on is the case this was built for.
///
/// **Everything returns to where it started.** Beats are presentation-only keyframes; the one
/// held gesture, `lift`, is a model change reversed on exit. An interrupted beat therefore
/// never leaves the logo askew, and a theme switch mid-gesture repaints a logo at rest.
///
/// Particles are born *behind* the image, so fizz leaving a bottle's neck appears to come out
/// of it rather than to be painted over the glass, and they are not clipped to the 24-point
/// slot — a stream that ended at the slot's edge would read as a rendering fault. The view is
/// decorative: the brand row carries the accessible name, and nothing here takes a click.
///
/// Motion is `ThemeParticleHold`'s call like every theme particle: Reduce Motion, the Theme
/// Motion setting and Low Power Mode leave the logo still, and the streams stop while the
/// window is unseen.
final class ThemeLogoView: NSView, ThemedComponent, ThemeParticleHolding {

    // MARK: - Properties

    private enum Layout {
        /// How far the held `lift` raises and grows the logo.
        static let liftScale: CGFloat = 1.08
        static let liftRise: CGFloat = 1.5
    }

    private let imageLayer = CALayer()
    /// The continuous streams: hover and working, whichever asks for more.
    private let streamEmitter = CAEmitterLayer()
    /// One burst at a time: press and launch.
    private let burstEmitter = CAEmitterLayer()

    private var motion: SidebarAppearance.Brand.LogoMotion?
    private var isHovered = false
    private var workingIntensity: Double = 0
    /// The size the emitters were last stated for — layout runs far more often than the slot
    /// changes size, and restating the cells mid-stream would restart it.
    private var configuredSize: CGSize = .zero

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        imageLayer.contentsGravity = .resizeAspect
        streamEmitter.birthRate = 0
        burstEmitter.birthRate = 0
        layer?.addSublayer(streamEmitter)
        layer?.addSublayer(burstEmitter)
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// States what the slot shows and how it moves. A nil motion is a logo at rest.
    func configure(image: NSImage?, motion: SidebarAppearance.Brand.LogoMotion?) {
        self.motion = motion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var rect = CGRect(origin: .zero, size: image?.size ?? .zero)
        imageLayer.contents = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        imageLayer.transform = CATransform3DIdentity
        imageLayer.removeAllAnimations()
        CATransaction.commit()
        isHovered = false
        configureEmitters()
        updateStream()
        if motion?.particles != nil {
            ThemeParticleHold.shared.register(self)
        }
    }

    /// The pointer arriving at, or leaving, the brand row.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        if let beat = motion?.spec.hover, ThemeParticleHold.motionAllowed {
            if beat == .lift {
                applyLift(hovered)
            } else if hovered {
                play(beat)
            }
        }
        updateStream()
    }

    /// A press anywhere on the brand row.
    func playPress() {
        guard ThemeParticleHold.motionAllowed else { return }
        if let beat = motion?.spec.press { play(beat) }
        burst()
    }

    /// Once per run, when the sidebar first appears.
    func playLaunch() {
        guard ThemeParticleHold.motionAllowed else { return }
        if let beat = motion?.spec.launch { play(beat) }
        if motion?.spec.launch != nil { burst() }
    }

    /// How busy the agents are, 0…1 — the stream a `working` logo gives off follows it.
    func setWorkingIntensity(_ intensity: Double) {
        let clamped = max(0, min(1, intensity))
        guard clamped != workingIntensity else { return }
        workingIntensity = clamped
        updateStream()
    }

    /// Whether a stream is flowing — what a test can ask without pixels.
    var streamRate: Float { streamEmitter.birthRate }

    func refreshParticleMotion() {
        updateStream()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = bounds
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        streamEmitter.frame = bounds
        burstEmitter.frame = bounds
        CATransaction.commit()
        guard bounds.size != configuredSize else { return }
        configureEmitters()
        updateStream()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        updateStream()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - Private Methods

    private var origin: CGPoint {
        let unit = motion?.spec.resolvedOrigin ?? .init(x: 0.5, y: 0)
        let up = ThemeParticleEmitter.upSign(of: streamEmitter)
        let y = up > 0
            ? bounds.height * CGFloat(1 - unit.y)
            : bounds.height * CGFloat(unit.y)
        return CGPoint(x: bounds.width * CGFloat(unit.x), y: y)
    }

    private func configureEmitters() {
        configuredSize = bounds.size
        guard let particles = motion?.particles, bounds.width > 0 else {
            streamEmitter.emitterCells = nil
            burstEmitter.emitterCells = nil
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let up = ThemeParticleEmitter.upSign(of: streamEmitter)
        let burstRate = Double(ThemeParticleEmitter.burstCount(for: particles.spec))
            / max(Design.Motion.logoBurstWindow, 0.01)
        for (emitter, rate) in [
            (streamEmitter, ThemeParticleEmitter.streamRate(for: particles.spec, intensity: 1)),
            (burstEmitter, burstRate)
        ] {
            ThemeParticleEmitter.configure(
                emitter,
                particles: particles.spec,
                colors: particles.colors,
                sprites: particles.sprites,
                placement: .point(origin),
                region: bounds,
                scale: scale,
                rate: rate,
                opacity: particles.spec.opacity,
                up: up
            )
        }
    }

    /// The stream's multiplier: the larger of hover and working, scaled into the cells' rate.
    private func updateStream() {
        guard let particles = motion?.particles,
              ThemeParticleHold.motionAllowed,
              ThemeParticleHold.isSeen(self) else {
            streamEmitter.birthRate = 0
            return
        }
        let hover = isHovered ? 1.0 : 0
        // The person's reaction settings decide whether and how hard the stream answers the agents.
        let working = (motion?.spec.working ?? false)
            ? ThemeReactions.scaledActivity(workingIntensity) : 0
        let full = ThemeParticleEmitter.streamRate(for: particles.spec, intensity: 1)
        let wanted = ThemeParticleEmitter.streamRate(
            for: particles.spec,
            intensity: max(hover, working)
        )
        streamEmitter.birthRate = full > 0 ? Float(wanted / full) : 0
    }

    private func burst() {
        guard motion?.particles != nil, ThemeParticleHold.isSeen(self) else { return }
        let burst = CAKeyframeAnimation(keyPath: "birthRate")
        burst.values = [1, 0]
        burst.keyTimes = [0, 1]
        burst.calculationMode = .discrete
        burst.duration = Design.Motion.logoBurstWindow
        burst.isRemovedOnCompletion = true
        burstEmitter.add(burst, forKey: "burst")
    }

    private func applyLift(_ lifted: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.Motion.quick)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        let up = ThemeParticleEmitter.upSign(of: imageLayer)
        imageLayer.transform = lifted
            ? CATransform3DScale(
                CATransform3DMakeTranslation(0, Layout.liftRise * up, 0),
                Layout.liftScale,
                Layout.liftScale,
                1
            )
            : CATransform3DIdentity
        CATransaction.commit()
    }

    /// Plays a beat as presentation-only keyframes over the logo's current model transform, so
    /// it composes with a held lift and ends exactly where it began.
    private func play(_ beat: SidebarStyle.Brand.LogoMotion.Beat) {
        let base = imageLayer.transform
        let up = ThemeParticleEmitter.upSign(of: imageLayer)
        let height = bounds.height
        let frames: [CATransform3D]
        switch beat {
        case .lift:
            frames = [
                base,
                CATransform3DConcat(base, lifted(up: up)),
                base
            ]
        case .tilt:
            frames = [0, -0.16, 0.06, 0].map { pivoted(base, angle: $0, height: height, up: up) }
        case .wobble:
            frames = [0, 0.13, -0.11, 0.07, -0.03, 0].map {
                pivoted(base, angle: $0, height: height, up: up)
            }
        case .bounce:
            frames = [0, -3, 2, -1, 0].map { rise in
                CATransform3DConcat(base, CATransform3DMakeTranslation(0, rise * up, 0))
            }
        case .spin:
            frames = [0, CGFloat.pi, CGFloat.pi * 2].map {
                CATransform3DConcat(base, CATransform3DMakeRotation($0, 0, 0, 1))
            }
        case .shake:
            frames = [0, -2, 2, -2, 2, -1, 0].map { offset in
                CATransform3DConcat(base, CATransform3DMakeTranslation(offset, 0, 0))
            }
        case .pop:
            frames = [1, 0.86, 1.14, 0.97, 1].map { scale in
                CATransform3DConcat(base, CATransform3DMakeScale(scale, scale, 1))
            }
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = frames.map { NSValue(caTransform3D: $0) }
        animation.duration = Design.Motion.logoBeat(beat)
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = true
        imageLayer.add(animation, forKey: "beat")
    }

    private func lifted(up: CGFloat) -> CATransform3D {
        CATransform3DScale(
            CATransform3DMakeTranslation(0, Layout.liftRise * up, 0),
            Layout.liftScale,
            Layout.liftScale,
            1
        )
    }

    /// A rotation about the logo's base rather than its centre — a bottle rocks on its foot.
    private func pivoted(
        _ base: CATransform3D,
        angle: CGFloat,
        height: CGFloat,
        up: CGFloat
    ) -> CATransform3D {
        let foot = -height / 2 * up
        let toFoot = CATransform3DMakeTranslation(0, -foot, 0)
        let rotate = CATransform3DMakeRotation(angle, 0, 0, 1)
        let back = CATransform3DMakeTranslation(0, foot, 0)
        let about = CATransform3DConcat(CATransform3DConcat(toFoot, rotate), back)
        return CATransform3DConcat(about, base)
    }
}
