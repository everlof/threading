import ThreadingRemoteKit
import ThreadingExtensionKit
import MetalKit
import CryptoKit
import UIKit
import SwiftUI

/// The dashboard's stationary ground. One layer fills the viewport independently of its
/// virtualized rows. Themes supply decoration; the host retains hit testing, navigation,
/// accessibility, power policy and the exact scroll position.
final class MobileThemeBackdropView: UIView {
    private let gradient = CAGradientLayer()
    private let picture = CALayer()
    private lazy var animator = ThemeGradientAnimator(layer: gradient)
    private var recipe: RemoteThemeGradient?
    private let particles = MobileThemeParticles()
    private var metal: MobileThemeMetalSurface?
    private var metalRecipe: RemoteThemeSurface?
    private var theme = RemoteThemePalette(nil)
#if DEBUG
    private static let evidencePhase: Double? = {
        guard let id = ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"] else { return nil }
        return id.contains("drift-quarter") ? 0.25 : 0
    }()
#endif
    var isPresentationActive = false {
        didSet {
            guard oldValue != isPresentationActive else { return }
            MobileBackdropOwnership.changed(self)
        }
    }
    var workingCount = 0 { didSet { if oldValue != workingCount { updateDrift() } } }
    var attentionCount = 0 { didSet { if oldValue != attentionCount { updateDrift() } } }
    private var frozenPhase: Double?
    private var ownsMotion = false
    fileprivate func setMotionOwner(_ value: Bool) { ownsMotion = value; refreshMotion() }
    var permitsMotion: () -> Bool = {
        MobileThemeMotionPreferences.motionEnabled
            && !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    var sceneIsActive: (UIWindow) -> Bool = { $0.windowScene?.activationState == .foregroundActive }
    /// Reduce Transparency and Increase Contrast ask for a quieter ground: the picture, particles
    /// and extension surface go, and the authored gradient (or the flat ground) stays.
    var prefersPlainGround: () -> Bool = {
        UIAccessibility.isReduceTransparencyEnabled || UIAccessibility.isDarkerSystemColorsEnabled
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        gradient.isHidden = true
        layer.addSublayer(gradient)
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        let center = NotificationCenter.default
        for name in [MobileThemeAssets.didLoad,
                     UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                     UIAccessibility.darkerSystemColorsStatusDidChangeNotification] {
            center.addObserver(self, selector: #selector(assetsChanged), name: name, object: nil)
        }
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification,
                     UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            center.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        // Not `UserDefaults.didChangeNotification`: that is posted on whichever thread wrote,
        // including actors, and for every key. The relay answers on main, only for these values.
        center.addObserver(self, selector: #selector(preferencesChanged),
            name: MobileThemeMotionPreferences.didChange, object: nil)
        MobileThemeMotionPreferences.startObserving()
        center.addObserver(
            self, selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        picture.frame = bounds
        metal?.frame = bounds
        updateParticles()
        CATransaction.commit()
    }

    override func didMoveToWindow() { super.didMoveToWindow(); MobileBackdropOwnership.changed(self) }

    override var isHidden: Bool { didSet { refreshMotion() } }

    func apply(_ theme: RemoteThemePalette, frozenPhase: Double? = nil) {
        var phase = frozenPhase
#if DEBUG
        phase = phase ?? Self.evidencePhase
#endif
        self.theme = theme
        updatePicture()
        updateMetal()
        backgroundColor = theme.uiGround
        let candidate = theme.source?.material.backdropGradient
        let valid = candidate.flatMap { $0.hasValidGeometry ? $0 : nil }
        // Only a theme replacement sorts/decodes stops. Routine catalogue updates keep both
        // the layer and its animation, and cannot reset the phase.
        if valid != recipe {
            recipe = valid
            let ordered = valid?.stops.sorted { $0.position < $1.position } ?? []
            let colors = ordered.compactMap { UIColor(remoteHex: $0.color)?.cgColor }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.isHidden = colors.isEmpty || colors.count != ordered.count
            gradient.colors = gradient.isHidden ? nil : colors
            gradient.locations = ordered.map { NSNumber(value: $0.position) }
            CATransaction.commit()
        }
        self.frozenPhase = phase
        updateDrift()
    }

    private func updateDrift() {
        let drift = recipe?.drift
        animator.configure(angleDegrees: recipe?.angleDegrees ?? 180, flipped: true,
            drift: drift, frozenPhase: frozenPhase)
        // Work quickens the drift through the layer's clock, never by restating the animation:
        // a new duration restarts the keyframes at phase zero and snapped the gradient whenever
        // a session started or finished.
        setDriftSpeed(drift.map {
            min(1 + MobileThemeMotionPreferences.reaction(workingCount: workingCount),
                $0.duration / ThemeGradientDrift.durationRange.lowerBound)
        } ?? 1)
        updateParticles()
        metal?.configure(theme: theme, workingCount: workingCount, attentionCount: attentionCount,
            texture: MobileThemeAssets.shared.image(theme.asset(MobileThemeMotionPreferences.surfaceTextureSlot))?.cgImage)
        refreshMotion()
    }

    /// Changes the gradient's clock rate from where its drift is now. A layer's local time is
    /// `(parent − beginTime) × speed + timeOffset`, so restating both offsets at this instant
    /// keeps the running keyframes at their current phase.
    private func setDriftSpeed(_ speed: Double) {
        let rate = Float(max(speed, 1))
        guard gradient.speed != rate else { return }
        let now = CACurrentMediaTime()
        gradient.timeOffset = gradient.convertTime(now, from: nil)
        gradient.beginTime = layer.convertTime(now, from: nil)
        gradient.speed = rate
    }

    @objc private func assetsChanged() {
        updatePicture()
        updateMetal()
        updateParticles()
    }

    @objc private func preferencesChanged() {
        updateMetal()
        updateDrift()
    }

    /// The reviewed extension surface this screen may build, if any: the phone's own switch,
    /// the accessibility ground and a process-wide GPU withdrawal can each refuse it.
    private var admittedSurface: RemoteThemeSurface? {
        guard MobileThemeMotionPreferences.extensionBackdropsEnabled, !prefersPlainGround(),
              let surface = theme.source?.surface,
              !MobileThemeMetalSurface.isWithdrawn(surface.sourceDigest) else { return nil }
        return surface
    }

    private func updateMetal() {
        let candidate = admittedSurface
        if metalRecipe != candidate {
            metal?.removeFromSuperview()
            metal = nil
            metalRecipe = candidate
        }
        if let candidate, let source = MobileThemeAssets.shared.source(for: candidate), metal == nil {
            metal = MobileThemeMetalSurface(recipe: candidate, source: source)
            if let metal {
                addSubview(metal)
                layer.insertSublayer(metal.layer, above: picture.superlayer == nil ? gradient : picture)
                metal.frame = bounds
            }
        }
        metal?.configure(theme: theme, workingCount: workingCount, attentionCount: attentionCount,
            texture: MobileThemeAssets.shared.image(theme.asset(MobileThemeMotionPreferences.surfaceTextureSlot))?.cgImage)
        refreshMotion()
    }

    private func updatePicture() {
        guard !prefersPlainGround(),
              let asset = theme.asset("backdrop") ?? theme.asset("sidebarImage"),
              let image = MobileThemeAssets.shared.image(asset) else {
            picture.contents = nil
            picture.removeFromSuperlayer()
            return
        }
        if picture.superlayer == nil { layer.insertSublayer(picture, above: gradient) }
        picture.contents = image.cgImage
        // A phone reads labels over broad grounds at smaller sizes. Pictures stay subdued,
        // even when the Mac author has deliberately chosen stronger photographic imagery.
        picture.opacity = Float(min(asset.opacity ?? 1, 0.25))
        picture.frame = bounds
    }

    private func updateParticles() {
        particles.apply(prefersPlainGround() ? nil : theme.source?.material.particles, theme: theme, region: bounds,
            scale: traitCollection.displayScale,
            reaction: MobileThemeMotionPreferences.reaction(workingCount: workingCount), parent: layer)
    }

    @objc private func environmentChanged(_ notification: Notification) {
        // willDeactivate is delivered before activationState changes. Stop immediately, and
        // only resume on didActivate once this particular scene reports itself active.
        if notification.name == UIScene.willDeactivateNotification,
           let scene = notification.object as? UIScene, scene === window?.windowScene {
            animator.setActive(false)
            particles.setActive(false)
            metal?.setPresentation(visible: false, moving: false)
        } else {
            updateDrift()
        }
    }

    func refreshMotion() {
        let active = ownsMotion && isPresentationActive && !isHidden
            && window.map(sceneIsActive) == true && permitsMotion() && frozenPhase == nil
        animator.setActive(active && !gradient.isHidden)
        particles.setActive(active)
        let visible = ownsMotion && isPresentationActive && !isHidden
            && window.map(sceneIsActive) == true && !ProcessInfo.processInfo.isLowPowerModeEnabled
        metal?.setPresentation(visible: visible, moving: active)
    }

    @objc nonisolated private func powerStateChanged() {
        Task { @MainActor [weak self] in self?.refreshMotion() }
    }

    var isAnimating: Bool { gradient.animation(forKey: ThemeGradientAnimator.animationKey) != nil }
    var showsGradient: Bool { !gradient.isHidden }
}


/// A window has one decorative motion owner. A pushed/covered screen relinquishes its lease;
/// a pop can restore the previous attached screen without allocating another animator.
@MainActor
private enum MobileBackdropOwnership {
    private static var candidates: [WeakBackdrop] = []
    private final class WeakBackdrop {
        weak var value: MobileThemeBackdropView?
        init(_ value: MobileThemeBackdropView) { self.value = value }
    }

    static func changed(_ view: MobileThemeBackdropView) {
        candidates.removeAll { $0.value == nil || $0.value === view }
        view.setMotionOwner(false)
        if view.isPresentationActive, view.window != nil { candidates.append(WeakBackdrop(view)) }
        var windows = Set<ObjectIdentifier>()
        for entry in candidates.reversed() {
            guard let candidate = entry.value, let window = candidate.window else { continue }
            candidate.setMotionOwner(windows.insert(ObjectIdentifier(window)).inserted)
        }
    }
}

enum MobileThemeMotionPreferences {
    static let motionKey = "theme.motion.enabled"
    static let reactionsKey = "theme.reactions.enabled"
    static let strengthKey = "theme.reactions.strength"
    static let extensionBackdropsKey = "theme.extensionBackdrops.enabled"
    /// Posted on the main actor when one of the values above changes, never for other keys.
    static let didChange = Notification.Name("MobileThemeMotionPreferencesDidChange")
    /// Where a theme's extension surface keeps its assets: the shader source and its texture.
    static let surfaceSlotPrefix = "surface."
    static let surfaceSourceSlot = surfaceSlotPrefix + "source"
    static let surfaceTextureSlot = surfaceSlotPrefix + "texture"

    static var motionEnabled: Bool { UserDefaults.standard.object(forKey: motionKey) as? Bool ?? true }
    /// The theme's own motion on this phone: the Theme motion switch, and Low Power Mode.
    static var decorativeMotionEnabled: Bool {
        motionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    static var reactsToActivity: Bool { UserDefaults.standard.bool(forKey: reactionsKey) }
    /// Whether the Mac's reviewed extension backdrop may run on this phone. Off, its shader
    /// source is never fetched and no surface is built.
    static var extensionBackdropsEnabled: Bool {
        UserDefaults.standard.object(forKey: extensionBackdropsKey) as? Bool ?? true
    }
    static var reactionStrength: Double {
        guard reactsToActivity else { return 0 }
        let stated = UserDefaults.standard.object(forKey: strengthKey) as? Double ?? 100
        return stated.isFinite ? min(max(stated / 100, 0), 2) : 1
    }

    /// The theme the asset loader is given. With extension backdrops off the surface recipe and
    /// its assets are left out, so neither the shader nor its texture is requested.
    static func assetRequest(for theme: RemoteThemeDTO?) -> RemoteThemeDTO? {
        guard let theme, theme.surface != nil, !extensionBackdropsEnabled else { return theme }
        return RemoteThemeDTO(
            id: theme.id, name: theme.name, mode: theme.mode, colors: theme.colors,
            material: theme.material, words: theme.words, titleMorph: theme.titleMorph,
            assets: theme.assets?.filter { !$0.slot.hasPrefix(surfaceSlotPrefix) }, surface: nil
        )
    }

    struct Snapshot: Equatable {
        var motion = MobileThemeMotionPreferences.motionEnabled
        var reactions = MobileThemeMotionPreferences.reactsToActivity
        var strength = MobileThemeMotionPreferences.reactionStrength
        var extensionBackdrops = MobileThemeMotionPreferences.extensionBackdropsEnabled
    }

    @MainActor static func startObserving() { _ = MobileThemePreferenceRelay.shared }
    static func reaction(workingCount: Int) -> Double {
        let strength = reactionStrength
        let reading = Double(max(workingCount, 0)) / 3
        let workingFloor = workingCount > 0 ? 0.08 * min(strength, 1) : 0
        return min(max(reading * strength, workingFloor), 1)
    }
}

/// One process-wide listener for preference writes. UserDefaults reports every key, on the
/// writing thread — the dashboard cache store writes from an actor — so the relay hops to main
/// and speaks only when the decoration preferences actually differ from the last reading.
@MainActor
private final class MobileThemePreferenceRelay {
    static let shared = MobileThemePreferenceRelay()
    private var last = MobileThemeMotionPreferences.Snapshot()

    private init() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MobileThemePreferenceRelay.shared.defaultsChanged() }
        }
    }

    private func defaultsChanged() {
        let next = MobileThemeMotionPreferences.Snapshot()
        guard next != last else { return }
        last = next
        NotificationCenter.default.post(name: MobileThemeMotionPreferences.didChange, object: nil)
    }
}

/// Reuses the UIKit background and its lifecycle gates for every SwiftUI page. The controller
/// stays fixed size; none of the page's rows allocate background views or timers.
struct MobileThemeBackdrop: UIViewControllerRepresentable {
    @Environment(\.mobileThemeWorkload) private var workload
    let theme: RemoteThemePalette
    var frozen = false

    func makeUIViewController(context: Context) -> MobileThemeBackdropController {
        MobileThemeBackdropController()
    }
    func updateUIViewController(_ controller: MobileThemeBackdropController, context: Context) {
        controller.permitsPresentationMotion = !frozen
        controller.backdrop.workingCount = workload.working
        controller.backdrop.attentionCount = workload.attention
        controller.backdrop.apply(theme, frozenPhase: frozen ? 0 : nil)
    }
}

final class MobileThemeBackdropController: UIViewController {
    let backdrop = MobileThemeBackdropView()
    var permitsPresentationMotion = true
    override func loadView() { view = backdrop }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        backdrop.isPresentationActive = permitsPresentationMotion
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        backdrop.isPresentationActive = false
    }
}

extension View {
    func mobileThemeBackdrop(_ theme: RemoteThemePalette) -> some View {
        background { MobileThemeBackdrop(theme: theme).ignoresSafeArea() }
    }
}

struct MobileThemeWorkload: Equatable {
    var working = 0
    var attention = 0
}

private struct MobileThemeWorkloadKey: EnvironmentKey {
    static let defaultValue = MobileThemeWorkload()
}

extension EnvironmentValues {
    var mobileThemeWorkload: MobileThemeWorkload {
        get { self[MobileThemeWorkloadKey.self] }
        set { self[MobileThemeWorkloadKey.self] = newValue }
    }
}

/// One emitter per screen, with the same numeric recipe as macOS. UIKit owns only raster
/// artwork and y-axis direction. The deterministic still keeps decoration under reduced motion.
@MainActor
private final class MobileThemeParticles {
    let emitter = CAEmitterLayer()
    let still = CALayer()
    private var recipe: RemoteThemeParticles?
    private var colors: [UIColor] = []
    private var region = CGRect.zero
    private var scale: CGFloat = 1
    private var active = false
    private var reaction: Double = 0
    private var imageRevision = -1
    private var assets: [RemoteThemeAsset] = []
    private var spritePictures: [(image: UIImage, tinted: Bool)] = []
    private static let images = NSCache<NSString, UIImage>()

    func apply(_ stated: RemoteThemeParticles?, theme: RemoteThemePalette, region: CGRect, scale: CGFloat,
               reaction: Double, parent: CALayer) {
        let next = stated?.isValid == true ? stated : nil
        let colors = (next?.colors.isEmpty == false ? next!.colors : ["accent"]).compactMap {
            UIColor(remoteHex: $0.hasPrefix("#") ? $0 : (theme.source?.colors[$0] ?? ""))
        }
        guard recipe != next || self.colors != colors || self.region != region
                || self.scale != scale || self.reaction != reaction
                || imageRevision != MobileThemeAssets.shared.revision
                || assets != (theme.source?.assets ?? []) else { return }
        self.recipe = next; self.colors = colors; self.region = region
        self.scale = scale; self.reaction = reaction
        imageRevision = MobileThemeAssets.shared.revision
        assets = theme.source?.assets ?? []
        spritePictures = (next?.sprites ?? []).prefix(4).compactMap { slot in
            guard let asset = theme.asset(slot), let image = MobileThemeAssets.shared.image(asset) else { return nil }
            return (image, asset.tinted ?? true)
        }
        guard let next, next.density > 0, next.opacity > 0, !colors.isEmpty, !region.isEmpty else {
            emitter.removeFromSuperlayer(); still.removeFromSuperlayer()
            return
        }
        if emitter.superlayer == nil { parent.addSublayer(emitter); parent.addSublayer(still) }
        configure(next)
        setActive(active)
    }

    func setActive(_ value: Bool) {
        active = value
        emitter.isHidden = !value
        // Speed zero holds simulation as well as stopping births. No hidden GPU simulation.
        emitter.speed = value ? 1 : 0
        still.isHidden = value
    }

    private func configure(_ particles: RemoteThemeParticles) {
        let motion = ThemeParticleMotion(style: particles.style, speed: particles.speed,
            size: particles.size, placement: .ambient, region: region.size)
        let baseRate: Double
        switch motion.source {
        case .area: baseRate = particles.density * Double(region.width * region.height) / 9_000
        default: baseRate = particles.density * Double(region.width) / 26
        }
        let aliveBudget = min(120, max(1, Double(region.width * region.height) / 3_000))
        let lifetimeRange = min(motion.lifetime * 0.15, max(0, 24 - motion.lifetime))
        let longestLifetime = max(motion.lifetime + lifetimeRange, 0.1)
        let rate = min(baseRate * (1 + reaction), aliveBudget / Double(longestLifetime))
        emitter.frame = region
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .volume
        switch motion.source {
        case .above:
            emitter.emitterPosition = CGPoint(x: region.width / 2, y: -motion.size)
            emitter.emitterSize = CGSize(width: region.width, height: 1)
        case .below:
            emitter.emitterPosition = CGPoint(x: region.width / 2, y: region.height + motion.size)
            emitter.emitterSize = CGSize(width: region.width, height: 1)
        case .area, .point:
            emitter.emitterPosition = CGPoint(x: region.width / 2, y: region.height / 2)
            emitter.emitterSize = region.size
        }
        let image = Self.artwork(particles.resolvedShape, size: motion.size, scale: scale)
        let opacity = min(particles.opacity, 0.6)
        let pictures: [(image: UIImage, color: UIColor)] = spritePictures.isEmpty
            ? colors.map { (image, $0) }
            : spritePictures.flatMap { sprite in
                sprite.tinted
                    ? colors.map { (sprite.image.withTintColor(.white, renderingMode: .alwaysOriginal), $0) }
                    : [(sprite.image, UIColor.white)]
            }
        emitter.emitterCells = pictures.enumerated().map { index, picture in
            let cell = CAEmitterCell()
            let color = picture.color
            cell.name = "theme-\(index)"
            cell.contents = picture.image.cgImage
            cell.contentsScale = CGFloat(max(picture.image.cgImage?.width ?? 1, picture.image.cgImage?.height ?? 1)) / motion.size
            cell.birthRate = Float(rate / Double(pictures.count))
            cell.lifetime = motion.lifetime; cell.lifetimeRange = lifetimeRange
            cell.velocity = motion.velocity; cell.velocityRange = motion.velocity * motion.velocitySpread
            cell.xAcceleration = motion.xAcceleration; cell.yAcceleration = -motion.yAcceleration
            cell.emissionLongitude = motion.headingUp ? -.pi / 2 : .pi / 2
            cell.emissionRange = motion.emissionRange
            cell.spin = motion.spin; cell.spinRange = motion.spinRange
            cell.scaleRange = motion.scaleRange; cell.scaleSpeed = motion.scaleSpeed
            cell.alphaRange = motion.alphaRange; cell.alphaSpeed = motion.alphaSpeed
            cell.color = color.withAlphaComponent(color.cgColor.alpha * opacity).cgColor
            return cell
        }
        // Fixed-size tile, independent of screen size and catalogue length; deterministic for QA.
        let side: CGFloat = 240
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        let tile = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let count = Int(4 + 26 * particles.density)
            for index in 0..<count {
                let x = CGFloat((index * 97 + 29) % 229)
                let y = CGFloat((index * 53 + 83) % 229)
                let picture = pictures[index % pictures.count]
                let stamp = picture.color == .white ? picture.image
                    : picture.image.withTintColor(picture.color, renderingMode: .alwaysOriginal)
                let aspect = stamp.size.width / max(stamp.size.height, 1)
                let size = CGSize(width: motion.size * min(aspect, 1),
                                  height: motion.size / max(aspect, 1))
                stamp.draw(in: CGRect(origin: CGPoint(x: x, y: y), size: size),
                          blendMode: .normal, alpha: opacity * 0.7)
            }
        }
        still.frame = region
        // The named tiled-pattern boundary rebuilds this colour on every theme/geometry update.
        // swiftlint:disable:next frozen_layer_colour
        still.backgroundColor = UIColor(patternImage: tile).cgColor
    }

    private static func artwork(_ shape: RemoteThemeParticles.Shape, size: CGFloat, scale: CGFloat) -> UIImage {
        let pixels = ceil(size * scale)
        let key = "\(shape.rawValue)-\(pixels)-\(scale)" as NSString
        if let value = images.object(forKey: key) { return value }
        images.countLimit = 32
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        let value = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            UIColor.white.setFill(); UIColor.white.setStroke()
            let box = CGRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.84)
            switch shape {
            case .dot: UIBezierPath(ovalIn: box).fill()
            case .bubble:
                let ring = UIBezierPath(ovalIn: box); ring.lineWidth = max(0.6, size * 0.1); ring.stroke()
            case .ribbon:
                UIBezierPath(roundedRect: CGRect(x: size * 0.28, y: size * 0.04,
                    width: size * 0.44, height: size * 0.92), cornerRadius: size * 0.08).fill()
            case .spark:
                let path = UIBezierPath()
                for step in 0..<8 {
                    let angle = Double(step) * .pi / 4
                    let radius = size * (step.isMultiple(of: 2) ? 0.46 : 0.12)
                    let point = CGPoint(x: size / 2 + cos(angle) * radius, y: size / 2 + sin(angle) * radius)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.close(); path.fill()
            case .flake:
                let path = UIBezierPath(); path.lineWidth = max(0.6, size * 0.09); path.lineCapStyle = .round
                for step in 0..<6 {
                    let angle = Double(step) * .pi / 3
                    let center = CGPoint(x: size / 2, y: size / 2)
                    path.move(to: center)
                    path.addLine(to: CGPoint(x: center.x + cos(angle) * size * 0.46,
                                            y: center.y + sin(angle) * size * 0.46))
                }
                path.stroke()
            }
        }
        images.setObject(value, forKey: key)
        return value
    }
}

/// The phone's passive, bounded interpretation of a reviewed Mac backdrop. Compilation and
/// texture preparation stay off the main actor; frames read twelve prepared scalar values.
@MainActor
final class MobileThemeMetalSurface: MTKView, MTKViewDelegate {
    private let recipe: RemoteThemeSurface
    private let commands: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var preparation: Task<Void, Never>?
    private var texturePreparation: Task<Void, Never>?
    private var image: MTLTexture?
    private var sampler: MTLSamplerState?
    private var imageIdentity: ObjectIdentifier?
    private let frames = DispatchSemaphore(value: 2)
    private var uniforms = [Float](repeating: 0, count: 12)
    private var beganAt = ProcessInfo.processInfo.systemUptime
    private var finishedAt: TimeInterval?
    private var attentionAt: TimeInterval?
    private var previousWorking = 0
    private var previousAttention = 0
    /// The person's reaction strength, or nil with activity reactions off — then reactive
    /// bindings read their fallback, as `ExtensionMetalSurfaceView.reacted` does on the Mac.
    private var reactionScale: Double?
    private var dayClock = MobileThemeDayClock()
    private var visible = false
    private var moving = false
    private var slowFrames = 0
    /// Shaders withdrawn for GPU cost, by source digest, for the life of the process. Every
    /// pushed page and sheet builds its own surface, so a per-surface flag let a withdrawn
    /// shader come back on the next screen. Bounded: only a digest that misbehaved is kept.
    private static var withdrawnDigests: [String] = []
    private static let maximumWithdrawnDigests = 32
    static func isWithdrawn(_ digest: String) -> Bool { withdrawnDigests.contains(digest) }
    var exceedsFrameBudget: Bool { Self.isWithdrawn(recipe.sourceDigest) }
#if DEBUG
    static func forgetWithdrawnShadersForTesting() { withdrawnDigests.removeAll() }
    var inputUniformsForTesting: [Float] { Array(uniforms.dropFirst(4)) }
    private(set) var completedFrameCount = 0
    var hasPreparedPipeline: Bool { pipeline != nil }
#endif

    init?(recipe: RemoteThemeSurface, source: String) {
        guard !Self.isWithdrawn(recipe.sourceDigest), recipe.isValid,
              source.utf8.count <= RemoteThemeAsset.maximumShaderBytes,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.recipe = recipe
        commands = queue
        super.init(frame: .zero, device: device)
        delegate = self
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        alpha = 0.25
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = false
        preferredFramesPerSecond = min(recipe.specification.preferredFramesPerSecond, 24)
        let definition = recipe.specification
        if definition.texture != nil {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear; descriptor.magFilter = .linear
            descriptor.sAddressMode = .clampToEdge; descriptor.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: descriptor)
        }
        let complete = ExtensionMetalSource.completeSource(extensionSource: source,
            fragmentFunction: definition.fragmentFunction, isTextured: definition.texture != nil)
        preparation = Task { [weak self] in
            guard let prepared = try? await MobileThemeMetalPipelineCache.shared.prepare(source: complete),
                  let self, !Task.isCancelled else { return }
            pipeline = prepared.state
            if definition.texture != nil, image == nil {
                let placeholder = await MobileThemeMetalPipelineCache.shared.texture(nil, device: prepared.device)
                if image == nil { image = placeholder }
            }
            setPresentation(visible: visible, moving: moving)
            setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(traitCollection.displayScale, 1_290 / max(bounds.width, bounds.height, 1))
        let next = CGSize(width: max(1, ceil(bounds.width * scale)), height: max(1, ceil(bounds.height * scale)))
        if drawableSize != next { drawableSize = next; setNeedsDisplay() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { setPresentation(visible: false, moving: false) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    func configure(theme: RemoteThemePalette, workingCount: Int, attentionCount: Int = 0, texture: CGImage?) {
        if previousWorking > 0, workingCount == 0 { finishedAt = ProcessInfo.processInfo.systemUptime }
        if attentionCount > previousAttention { attentionAt = ProcessInfo.processInfo.systemUptime }
        previousWorking = workingCount
        previousAttention = attentionCount
        reactionScale = MobileThemeMotionPreferences.reactsToActivity
            ? MobileThemeMotionPreferences.reactionStrength : nil
        // The clock and the moments are sampled per frame in `draw(in:)`.
        var readings: [ExtensionHostSignal: Double] = [
            .audioAvailable: 0, .themeDark: theme.colorScheme == .dark ? 1 : 0
        ]
        if let reactionScale {
            readings[.workloadIntensity] = MobileThemeMotionPreferences.reaction(workingCount: workingCount)
            readings[.workloadWorkingCount] = Double(max(workingCount, 0)) * reactionScale
        }
        for (color, signals) in [(theme.uiGround, [ExtensionHostSignal.themeGroundRed, .themeGroundGreen, .themeGroundBlue]),
                                  (UIColor(theme.accent), [ExtensionHostSignal.themeAccentRed, .themeAccentGreen, .themeAccentBlue])] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
                for (signal, value) in zip(signals, [r, g, b]) { readings[signal] = Double(value) }
            }
        }
        for (index, input) in recipe.specification.inputs.enumerated() {
            uniforms[4 + index] = Float(Self.resolve(input.value, readings: readings))
        }
        let identity = texture.map(ObjectIdentifier.init)
        if identity != imageIdentity, let device {
            imageIdentity = identity
            texturePreparation?.cancel()
            texturePreparation = Task { [weak self] in
                let prepared = await MobileThemeMetalPipelineCache.shared.texture(texture, device: device)
                guard let self, !Task.isCancelled, imageIdentity == identity else { return }
                image = prepared
                setNeedsDisplay()
            }
        }
        setNeedsDisplay()
    }

    func setPresentation(visible: Bool, moving: Bool) {
        self.visible = visible
        self.moving = moving
        isHidden = !visible || exceedsFrameBudget
        isPaused = !visible || !moving || pipeline == nil || exceedsFrameBudget
        enableSetNeedsDisplay = isPaused
        if visible && !moving { setNeedsDisplay() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard visible, !exceedsFrameBudget, let pipeline,
              frames.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let command = commands.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            frames.signal(); return
        }
        uniforms[0] = Float(drawableSize.width); uniforms[1] = Float(drawableSize.height)
        uniforms[2] = moving ? Float(ProcessInfo.processInfo.systemUptime - beganAt) : 0
        let uptime = ProcessInfo.processInfo.systemUptime
        for (index, input) in recipe.specification.inputs.enumerated() {
            guard case .signal(let signal, let mapping) = input.value else { continue }
            switch signal {
            case .timeOfDayFraction:
                uniforms[4 + index] = Float(Self.mapped(dayClock.fraction(at: Date()), mapping))
            case .momentTurnFinished, .momentNeedsAttention:
                // A moment is motion and a reaction: held motion or reactions off read the
                // binding's fallback, otherwise the Mac's smoothstep pulse at the person's strength.
                let eventAt = signal == .momentTurnFinished ? finishedAt : attentionAt
                let pulse = moving ? reactionScale.map {
                    min(max(Self.momentPulse(since: eventAt, at: uptime) * $0, 0), 1)
                } : nil
                uniforms[4 + index] = Float(Self.mapped(pulse, mapping))
            default:
                continue
            }
        }
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        if recipe.specification.texture != nil {
            encoder.setFragmentTexture(image, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        let frames = frames
        command.addCompletedHandler { [weak self] command in
            frames.signal()
            let duration = command.gpuEndTime - command.gpuStartTime
            let failed = command.status == .error
            Task { @MainActor [weak self] in
                if failed { self?.withdraw() } else { self?.recordGPUTime(duration) }
            }
        }
        command.commit()
    }

    func recordGPUTime(_ duration: Double) {
#if DEBUG
        completedFrameCount &+= 1
#endif
        slowFrames = duration > 0.004 ? slowFrames + 1 : 0
        if slowFrames >= 3 { withdraw() }
    }

    private func withdraw() {
        if !Self.isWithdrawn(recipe.sourceDigest) {
            Self.withdrawnDigests.append(recipe.sourceDigest)
            if Self.withdrawnDigests.count > Self.maximumWithdrawnDigests {
                Self.withdrawnDigests.removeFirst()
            }
        }
        setPresentation(visible: visible, moving: moving)
    }

    func waitForPreparation() async { await preparation?.value }

    /// `1` at the event, easing to `0` over `momentPulseDuration` with a smoothstep; `0` before
    /// any event — the Mac's `ExtensionHostSignals.momentPulse`.
    private static func momentPulse(since occurredAt: TimeInterval?, at time: TimeInterval) -> Double {
        guard let occurredAt else { return 0 }
        let elapsed = time - occurredAt
        let duration = ExtensionHostSignal.momentPulseDuration
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let progress = elapsed / duration
        return 1 - progress * progress * (3 - 2 * progress)
    }

    private static func resolve(_ scalar: ExtensionSurfaceScalar, readings: [ExtensionHostSignal: Double]) -> Double {
        switch scalar {
        case .constant(let value): return value
        case .signal(let signal, let mapping): return mapped(readings[signal], mapping)
        }
    }

    private static func mapped(_ reading: Double?, _ mapping: ExtensionScalarMapping) -> Double {
        guard let reading else { return mapping.fallback }
        let position = min(max((reading - mapping.inputMinimum) / (mapping.inputMaximum - mapping.inputMinimum), 0), 1)
        let curved: Double = switch mapping.curve {
        case .linear: position
        case .easeIn: position * position
        case .easeOut: 1 - (1 - position) * (1 - position)
        case .easeInOut: position * position * (3 - 2 * position)
        }
        return mapping.outputMinimum + curved * (mapping.outputMaximum - mapping.outputMinimum)
    }
}

/// Midnight to midnight as `0...1` against the day's real length, so a daylight-saving change
/// moves the fraction rather than letting it run past one. The day's bounds are looked up once a
/// day, which keeps a per-frame reading to one `Date()`.
struct MobileThemeDayClock {
    private var start = Date.distantPast
    private var end = Date.distantPast

    mutating func fraction(at now: Date) -> Double {
        if now < start || now >= end {
            let calendar = Calendar.current
            start = calendar.startOfDay(for: now)
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        }
        return min(max(now.timeIntervalSince(start) / max(end.timeIntervalSince(start), 1), 0), 1)
    }
}

/// Metal pipeline objects are immutable after creation and may be shared across render threads.
struct MobileThemeMetalPipeline: @unchecked Sendable {
    let device: MTLDevice
    let state: MTLRenderPipelineState
}

/// Two compilations at once, at most 32 pending distinct sources and 16 retained pipelines.
/// Identical requests share a task; failures are not cached. Neither compiler touches AppKit.
actor MobileThemeMetalPipelineCache {
    static let shared = MobileThemeMetalPipelineCache()
    private let maximumPending = 32
    private let maximumCached = 16
    private var cached: [String: MobileThemeMetalPipeline] = [:]
    private var order: [String] = []
    private var pending: [String: Task<MobileThemeMetalPipeline, Error>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    enum Failure: Error { case busy, unavailable, missingFunction }

    /// Transfers a fresh shader-read texture after its bytes are populated. The cache keeps
    /// no alias to this resource; the renderer owns it after the actor returns.
    func texture(_ image: CGImage?, device: MTLDevice) -> sending MTLTexture? {
        let width = image?.width ?? 1, height = image?.height ?? 1
        guard (1...1_024).contains(width), (1...1_024).contains(height) else { return nil }
        var bytes = Data(count: width * height * 4)
        if let image {
            let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let pixels = buffer.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    let alpha = Int(pixels[offset + 3])
                    if alpha != 255 {
                        for channel in 0..<3 {
                            pixels[offset + channel] = UInt8(alpha == 0 ? 0 : min(255, (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha))
                        }
                    }
                }
                return true
            }
            guard success else { return nil }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return texture
    }

    func prepare(source: String) async throws -> MobileThemeMetalPipeline {
        let key = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        if let value = cached[key] {
            order.removeAll { $0 == key }; order.append(key)
            return value
        }
        if let task = pending[key] { return try await task.value }
        guard pending.count < maximumPending else { throw Failure.busy }
        let task = Task { try await self.compile(source: source) }
        pending[key] = task
        do {
            let value = try await task.value
            pending[key] = nil
            cached[key] = value
            order.append(key)
            while order.count > maximumCached { cached[order.removeFirst()] = nil }
            return value
        } catch {
            pending[key] = nil
            throw error
        }
    }

    private func compile(source: String) async throws -> MobileThemeMetalPipeline {
        if active < 2 { active += 1 }
        else { await withCheckedContinuation { waiters.append($0) } }
        defer {
            if waiters.isEmpty { active -= 1 }
            else { waiters.removeFirst().resume() }
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.unavailable }
        let library = try await device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "threadingHostSurfaceVertex"),
              let fragment = library.makeFunction(name: "threadingHostSurfaceFragment") else {
            throw Failure.missingFunction
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state = try await device.makeRenderPipelineState(descriptor: descriptor)
        return MobileThemeMetalPipeline(device: device, state: state)
    }
}
