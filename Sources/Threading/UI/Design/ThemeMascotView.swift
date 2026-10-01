import AppKit
import QuartzCore

// MARK: - Theme Mascot View

/// A theme's mascot (`ThemeMascot`) standing in its box: the picture for the app's current mood,
/// its looping motion, and the particles it gives off.
///
/// **One pose at a time, dissolved into the next.** A mood change swaps the picture under a
/// short fade (`Design.Motion.mascotPoseChange`) and restarts the new pose's loop from rest, so
/// a dog that was mid-hop when a session started waiting lands as the attentive dog rather than
/// being caught in the air.
///
/// **The loop runs in the render server.** A pose's motion is one keyframe animation repeated
/// for ever: the motion played at the start of its period, then rest until the next. Nothing
/// here ticks on the main thread; a mood change is the only main-actor work, and it is O(1).
/// Particles are born behind the picture from the pose's origin and are not clipped to the box.
///
/// **`ThemeParticleHold` decides whether anything moves.** Under Reduce Motion, the Theme
/// animations setting or Low Power Mode the mascot still changes pose with the app's state —
/// that is information — but holds each pose still, with no stream. While its window is unseen
/// the layer tree is frozen in time and resumes where it stood.
///
/// Decorative: no hit-testing, no pointer claim, not an accessibility element.
final class ThemeMascotView: NSView, ThemeParticleHolding {

    // MARK: - Properties

    private enum Keys {
        static let loop = "mascot.loop"
        static let poseFade = "mascot.fade"
    }

    /// The layer the motion animates: its anchor is the mascot's feet, so a sway rocks it on
    /// them and a breath swells it from the ground up.
    private let stage = CALayer()
    private let picture = CALayer()
    /// The pose's stream, behind the picture.
    private let emitter = CAEmitterLayer()

    private var mascot: SidebarAppearance.Mascot?
    private(set) var mood: ThemeMascotMood = .resting
    /// The mood shown when the theme draws no celebration — the monitor's base mood.
    private var fallbackMood: ThemeMascotMood = .resting
    private(set) var pose: SidebarAppearance.Mascot.Pose?
    private var workingIntensity: Double = 0
    private var configuredSize: CGSize = .zero
    private var isFrozen = false

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        picture.contentsGravity = .resizeAspect
        emitter.birthRate = 0
        stage.addSublayer(emitter)
        stage.addSublayer(picture)
        layer?.addSublayer(stage)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// States the mascot and the mood to show. A nil mascot empties the view.
    func configure(
        _ mascot: SidebarAppearance.Mascot?,
        mood: ThemeMascotMood,
        fallbackMood: ThemeMascotMood
    ) {
        let changedMascot = mascot != self.mascot
        self.mascot = mascot
        self.fallbackMood = fallbackMood
        if changedMascot { pose = nil }
        show(mood: mood, animated: !changedMascot)
        ThemeParticleHold.shared.register(self)
    }

    /// The app's mood moved.
    func setMood(_ mood: ThemeMascotMood, fallbackMood: ThemeMascotMood) {
        self.fallbackMood = fallbackMood
        show(mood: mood, animated: true)
    }

    /// How busy the agents are, 0…1 — a working pose's stream follows it.
    func setWorkingIntensity(_ intensity: Double) {
        let clamped = max(0, min(1, intensity))
        guard clamped != workingIntensity else { return }
        workingIntensity = clamped
        updateStream()
    }

    /// Whether the current pose's loop is installed — what a test asks without pixels.
    var isLooping: Bool { stage.animation(forKey: Keys.loop) != nil }

    /// The stream's current multiplier over its full rate.
    var streamRate: Float { emitter.birthRate }

    func refreshParticleMotion() {
        applyMotion()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let up = ThemeParticleEmitter.upSign(of: stage)
        // Feet on the box's bottom edge, whichever way the layer's y axis runs.
        stage.anchorPoint = CGPoint(x: 0.5, y: up > 0 ? 0 : 1)
        stage.bounds = bounds
        stage.position = CGPoint(x: bounds.midX, y: up > 0 ? bounds.minY : bounds.maxY)
        emitter.frame = stage.bounds
        layoutPicture()
        CATransaction.commit()
        guard bounds.size != configuredSize else { return }
        configuredSize = bounds.size
        configureEmitter()
        applyMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        picture.contentsScale = scale
        configureEmitter()
        applyMotion()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - Private Methods

    private func show(mood: ThemeMascotMood, animated: Bool) {
        self.mood = mood
        let next = mascot?.pose(for: mood) ?? mascot?.pose(for: fallbackMood)
        guard next != pose else { return }
        pose = next

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, picture.contents != nil, Design.Motion.mascotPoseChange > 0 {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Design.Motion.mascotPoseChange
            picture.add(fade, forKey: Keys.poseFade)
        }
        if let image = next?.image {
            var rect = CGRect(origin: .zero, size: image.size)
            picture.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        } else {
            picture.contents = nil
        }
        layoutPicture()
        CATransaction.commit()

        configureEmitter()
        applyMotion()
    }

    /// The pose fitted into the box and standing on its bottom edge, so poses of different
    /// proportions share one ground line.
    private func layoutPicture() {
        guard let image = pose?.image,
              let frame = ThemeImageAlignment.bottom.frame(
                  for: image.size,
                  in: stage.bounds,
                  mode: .fit,
                  flipped: ThemeParticleEmitter.upSign(of: stage) < 0
              ) else {
            picture.frame = stage.bounds
            return
        }
        picture.frame = frame
    }

    private var origin: CGPoint {
        let unit = pose?.spec.resolvedOrigin ?? .init(x: 0.5, y: 0)
        let frame = picture.frame
        let up = ThemeParticleEmitter.upSign(of: emitter)
        let y = up > 0
            ? frame.minY + frame.height * CGFloat(1 - unit.y)
            : frame.minY + frame.height * CGFloat(unit.y)
        return CGPoint(x: frame.minX + frame.width * CGFloat(unit.x), y: y)
    }

    private func configureEmitter() {
        guard let particles = pose?.particles, bounds.width > 0 else {
            emitter.emitterCells = nil
            emitter.birthRate = 0
            return
        }
        ThemeParticleEmitter.configure(
            emitter,
            particles: particles.spec,
            colors: particles.colors,
            sprites: particles.sprites,
            placement: .point(origin),
            region: bounds,
            scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            rate: ThemeParticleEmitter.streamRate(for: particles.spec, intensity: 1),
            opacity: particles.spec.opacity,
            up: ThemeParticleEmitter.upSign(of: emitter)
        )
    }

    /// The stream follows the agents while working, and flows steadily in every other mood.
    private func updateStream() {
        guard let particles = pose?.particles,
              ThemeParticleHold.motionAllowed,
              ThemeParticleHold.isSeen(self) else {
            emitter.birthRate = 0
            return
        }
        let intensity = mood == .working ? max(workingIntensity, 0.35) : 1
        let full = ThemeParticleEmitter.streamRate(for: particles.spec, intensity: 1)
        let wanted = ThemeParticleEmitter.streamRate(for: particles.spec, intensity: intensity)
        emitter.birthRate = full > 0 ? Float(wanted / full) : 0
    }

    /// Installs, removes, freezes or resumes the loop as the hold says.
    private func applyMotion() {
        guard ThemeParticleHold.motionAllowed, let pose, let motion = pose.spec.motion else {
            stage.removeAnimation(forKey: Keys.loop)
            stage.transform = CATransform3DIdentity
            thaw()
            updateStream()
            return
        }
        if stage.animation(forKey: Keys.loop) == nil || configuredLoop != loopIdentity(pose) {
            installLoop(motion, pose: pose)
        }
        if ThemeParticleHold.isSeen(self) {
            thaw()
        } else {
            freeze()
        }
        updateStream()
    }

    /// Which pose and size the installed loop was built for; a change rebuilds it.
    private var configuredLoop: String?

    private func loopIdentity(_ pose: SidebarAppearance.Mascot.Pose) -> String {
        "\(pose.spec.asset)|\(pose.spec.motion?.rawValue ?? "")|\(pose.spec.every ?? 0)|\(bounds.height)"
    }

    private func installLoop(_ motion: ThemeMascot.Motion, pose: SidebarAppearance.Mascot.Pose) {
        let period = Design.Motion.mascotLoop(pose.spec)
        let length = Design.Motion.mascotMotion(motion)
        guard period > 0, length > 0, bounds.height > 0 else {
            stage.removeAnimation(forKey: Keys.loop)
            return
        }
        let frames = Self.frames(for: motion, height: bounds.height, up: ThemeParticleEmitter.upSign(of: stage))
        // The motion plays in the first `length / period` of the loop and rests for the rest.
        let share = min(1, length / period)
        var keyTimes = frames.indices.map { index -> NSNumber in
            NSNumber(value: share * Double(index) / Double(max(frames.count - 1, 1)))
        }
        var values = frames.map { NSValue(caTransform3D: $0) }
        if share < 1 {
            keyTimes.append(1)
            values.append(NSValue(caTransform3D: CATransform3DIdentity))
        }
        let loop = CAKeyframeAnimation(keyPath: "transform")
        loop.values = values
        loop.keyTimes = keyTimes
        loop.duration = Design.Motion.mascotLoop(pose.spec)
        loop.repeatCount = .infinity
        loop.calculationMode = .linear
        loop.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: max(values.count - 1, 1)
        )
        loop.isRemovedOnCompletion = false
        stage.add(loop, forKey: Keys.loop)
        configuredLoop = loopIdentity(pose)
    }

    /// Keyframes for one play, about the mascot's feet (the stage's anchor). Amplitudes are a
    /// share of the mascot's height so a 120-point dog hops as far, proportionally, as a
    /// 40-point one.
    static func frames(for motion: ThemeMascot.Motion, height: CGFloat, up: CGFloat) -> [CATransform3D] {
        func lift(_ share: CGFloat) -> CATransform3D {
            CATransform3DMakeTranslation(0, height * share * up, 0)
        }
        func scale(_ x: CGFloat, _ y: CGFloat) -> CATransform3D {
            CATransform3DMakeScale(x, y, 1)
        }
        let rest = CATransform3DIdentity
        switch motion {
        case .breathe:
            return [rest, scale(1.02, 1.045), rest]
        case .bob:
            return [rest, lift(0.05), rest, lift(-0.015), rest]
        case .hop:
            return [
                rest,
                scale(1.06, 0.9),
                CATransform3DConcat(scale(0.96, 1.06), lift(0.2)),
                CATransform3DConcat(scale(0.98, 1.02), lift(0.08)),
                scale(1.07, 0.92),
                rest
            ]
        case .sway:
            return [0, 0.07, 0, -0.07, 0].map { CATransform3DMakeRotation($0 * up, 0, 0, 1) }
        case .shake:
            return [0, -0.045, 0.045, -0.04, 0.035, -0.02, 0].map {
                CATransform3DMakeTranslation(height * $0, 0, 0)
            }
        case .spin:
            // About the feet a turn would swing the mascot through the floor, so a spin turns it
            // about its middle: down half its height to the anchor, round, and back up.
            return [0, CGFloat.pi, CGFloat.pi * 2].map { angle in
                CATransform3DConcat(
                    CATransform3DConcat(lift(-0.5), CATransform3DMakeRotation(angle, 0, 0, 1)),
                    lift(0.5)
                )
            }
        case .pop:
            return [1, 0.88, 1.12, 0.97, 1].map { scale($0, $0) }
        }
    }

    private func freeze() {
        guard !isFrozen, let layer else { return }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = now
        isFrozen = true
    }

    private func thaw() {
        guard isFrozen, let layer else { return }
        let paused = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        isFrozen = false
    }
}
