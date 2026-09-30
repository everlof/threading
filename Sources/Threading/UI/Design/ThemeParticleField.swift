import AppKit
import QuartzCore

// MARK: - Theme Particle Field

/// An ambient field of a theme's particles under a ground — bubbles rising through the sidebar,
/// snow falling past a pane (`ThemeBackdrop.particles`).
///
/// A layer rather than a view because both of its homes are layer stacks already: the
/// sidebar's dressing (`SidebarBackdropView`) and the material's dressing under every broad
/// ground (`ThemeBackdropDressingLayer`). It sits over the wash and the picture and under
/// everything a person reads.
///
/// **Three states, one owner.** Whether the field moves is `ThemeParticleHold`'s call, never
/// the host's:
///
/// - *running* — a live `CAEmitterLayer`, prewarmed so a theme arrives with its glass already
///   full rather than filling from the bottom over twenty seconds;
/// - *paused* — the same emitter frozen in time (`speed` 0) while its window is unseen, so the
///   render server has nothing to animate and the field resumes exactly where it stood;
/// - *still* — no emitter at all, and a deterministic scatter tiled in its place, while motion
///   is off (Reduce Motion, the Theme Motion setting, Low Power Mode). The theme keeps its
///   look the way a `backdropPattern` does; nothing moves.
///
/// Every configure states the whole emitter, so a theme switch cannot leave the previous
/// theme's cells behind, and the cell colours are restated on each apply like every other
/// frozen layer colour.
public final class ThemeParticleFieldLayer: CALayer, ThemeParticleHolding {

    static let layerName = "threading.particleField"

    enum State: Equatable {
        case empty
        case running
        case paused
        case still
    }

    /// Where a resize stops being a geometry change and needs new lifetimes: a field whose
    /// height moved by more than this re-derives how long a particle takes to cross it.
    private static let lifetimeRederivationRatio: CGFloat = 0.25
    /// The side of the still frame's seamless tile, in points.
    private static let stillTileSide: CGFloat = 240

    private let emitter = CAEmitterLayer()
    private let still = CALayer()

    private var particles: SidebarAppearance.Background.Particles?
    /// The size the emitter's cells were last derived for.
    private var derivedSize: CGSize = .zero
    private var derivedScale: CGFloat = 0
    private(set) var state: State = .empty

    /// The view whose window decides whether the field is seen.
    private weak var host: NSView?

    // MARK: - Initialization

    public override init() {
        super.init()
        name = Self.layerName
        masksToBounds = true
        isHidden = true
        still.isHidden = true
        emitter.isHidden = true
        addSublayer(still)
        addSublayer(emitter)
    }

    public override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Public Methods

    /// States the field: `nil` empties it. `host` is the view whose window and visibility
    /// decide whether it moves.
    @MainActor
    func apply(_ particles: SidebarAppearance.Background.Particles?, host: NSView) {
        self.host = host
        let changed = particles != self.particles
        self.particles = particles
        if changed {
            derivedSize = .zero
            state = .empty
        }
        ThemeParticleHold.shared.register(self)
        refresh()
    }

    /// Re-asks the hold which state the field should be in and moves it there.
    @MainActor
    func refresh() {
        withoutActions {
            guard let particles, bounds.width > 0, bounds.height > 0 else {
                // Nothing to draw into yet (or any more): the cells go, so the next layout
                // with a real size has to start the field again rather than resize it.
                isHidden = particles == nil
                stopEmitting()
                still.isHidden = true
                state = .empty
                derivedSize = .zero
                return
            }
            isHidden = false

            guard ThemeParticleHold.motionAllowed else {
                showStill(particles)
                return
            }
            if state == .still || state == .empty || needsDerivation {
                start(particles)
            }
            if ThemeParticleHold.isSeen(host) {
                resume()
            } else {
                pause()
            }
        }
    }

    /// Whether a live emitter is on screen and moving — what a test asks without pixels.
    var isEmitting: Bool { state == .running }

    @MainActor
    func refreshParticleMotion() {
        refresh()
    }

    // MARK: - Layout

    public override func layoutSublayers() {
        super.layoutSublayers()
        // Core Animation lays out on the thread that committed the transaction, which for a
        // layer in a window's tree is the main thread — the assumption `assumeIsolated` checks.
        // The layer is not `Sendable` (no `CALayer` is), and handing it to the main actor it is
        // already on is the one crossing this opt-out states.
        nonisolated(unsafe) let field = self
        MainActor.assumeIsolated {
            field.layoutField()
        }
    }

    @MainActor
    private func layoutField() {
        withoutActions {
            emitter.frame = bounds
            still.frame = bounds
        }
        guard particles != nil else { return }
        if state == .empty || needsDerivation {
            refresh()
        } else if state == .running || state == .paused {
            // A width change is geometry: the source line follows the edge and the rate
            // follows the width, without restarting a field already in motion.
            updateGeometry()
        }
    }

    // MARK: - Private Methods

    @MainActor
    private var backingScale: CGFloat {
        host?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    @MainActor
    private var needsDerivation: Bool {
        guard derivedSize.height > 0 else { return true }
        let drift = abs(bounds.height - derivedSize.height) / derivedSize.height
        return drift > Self.lifetimeRederivationRatio || derivedScale != backingScale
    }

    private var opacityCeiling: Double {
        ThemeParticleLimits.ambientOpacityCeiling
    }

    @MainActor
    private func start(_ particles: SidebarAppearance.Background.Particles) {
        still.isHidden = true
        still.backgroundColor = nil
        emitter.isHidden = false
        emitter.speed = 1
        emitter.timeOffset = 0
        configureEmitter(particles)

        // Prewarmed: a begin time in the past has Core Animation simulate the field as if it
        // had been running all along (measured — a column is full within the first frame
        // rather than after one crossing).
        let lifetime = CFTimeInterval(emitter.emitterCells?.first?.lifetime ?? 0)
        let now = superlayer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
        emitter.beginTime = now - lifetime
        state = .running
    }

    @MainActor
    private func configureEmitter(_ particles: SidebarAppearance.Background.Particles) {
        let scale = backingScale
        ThemeParticleEmitter.configure(
            emitter,
            particles: particles.spec,
            colors: particles.colors,
            placement: .ambient,
            region: bounds,
            scale: scale,
            rate: ThemeParticleEmitter.ambientRate(for: particles.spec, region: bounds.size),
            opacity: min(particles.spec.opacity, opacityCeiling),
            up: ThemeParticleEmitter.upSign(of: emitter)
        )
        derivedSize = bounds.size
        derivedScale = scale
    }

    @MainActor
    private func updateGeometry() {
        guard let particles else { return }
        let motion = ThemeParticleMotion(
            particles: particles.spec,
            placement: .ambient,
            region: bounds.size
        )
        let rate = ThemeParticleEmitter.ambientRate(for: particles.spec, region: bounds.size)
        let perInk = Float(rate / Double(max(emitter.emitterCells?.count ?? 1, 1)))
        withoutActions {
            ThemeParticleEmitter.place(
                emitter,
                motion: motion,
                region: bounds,
                up: ThemeParticleEmitter.upSign(of: emitter)
            )
            for cell in emitter.emitterCells ?? [] {
                guard let name = cell.name else { continue }
                emitter.setValue(perInk, forKeyPath: "emitterCells.\(name).birthRate")
            }
        }
    }

    private func pause() {
        guard state == .running else { return }
        let now = emitter.convertTime(CACurrentMediaTime(), from: nil)
        emitter.speed = 0
        emitter.timeOffset = now
        state = .paused
    }

    private func resume() {
        guard state == .paused else { return }
        let paused = emitter.timeOffset
        emitter.speed = 1
        emitter.timeOffset = 0
        emitter.beginTime = 0
        let since = emitter.convertTime(CACurrentMediaTime(), from: nil) - paused
        emitter.beginTime = since
        state = .running
    }

    private func stopEmitting() {
        emitter.emitterCells = nil
        emitter.isHidden = true
        emitter.speed = 1
        emitter.timeOffset = 0
    }

    @MainActor
    private func showStill(_ particles: SidebarAppearance.Background.Particles) {
        stopEmitting()
        let scale = backingScale
        guard let tile = ThemeParticleStill.tile(
            particles: particles.spec,
            colors: particles.colors,
            side: Self.stillTileSide,
            scale: scale,
            opacity: min(particles.spec.opacity, opacityCeiling)
        ) else {
            still.isHidden = true
            return
        }
        let image = NSImage(
            cgImage: tile,
            size: NSSize(width: Self.stillTileSide, height: Self.stillTileSide)
        )
        // A pattern colour is how Core Animation tiles at the image's own size; restated on
        // every refresh like every other frozen colour.
        still.backgroundColor = NSColor(patternImage: image).cgColor
        still.isHidden = false
        derivedSize = .zero
        state = .still
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - Theme Particle Holding

/// Anything drawing a theme's particles: it registers with the hold and is re-asked whenever
/// something the hold reads changes. The requirement rather than the protocol is main-actor
/// isolated, so a `CALayer` can conform without its AppKit overrides changing isolation.
protocol ThemeParticleHolding: AnyObject {
    @MainActor func refreshParticleMotion()
}

// MARK: - Theme Particle Hold

/// The one owner of *whether* a theme's particles move.
///
/// Motion is off — every field still, no gesture or transition played — under Reduce Motion,
/// the user's Theme Motion setting, and Low Power Mode. With motion on, each field additionally
/// holds (freezes in time) while its window is unseen: miniaturized, fully occluded, hidden with
/// the app, or the field's own view hidden. That is the frame-cadence rule the extension
/// backdrop plane keeps for its Metal surface, applied here so a glass of bubbles in a window
/// behind another app costs nothing.
///
/// Fields and logos register themselves and are held weakly; the hold re-asks every live one
/// when anything it reads changes, so no host has to remember to.
@MainActor
final class ThemeParticleHold {

    static let shared = ThemeParticleHold()

    private let members = NSHashTable<AnyObject>.weakObjects()
    private var notificationObservers: [NSObjectProtocol] = []
    private let appEvents = AppEventObservations()
    private var isObserving = false

    /// Set only inside `withStillFrames`: a render that must draw fields as their still frame.
    private static var drawsStillFrames = false

    /// Whether motion may play at all right now.
    static var motionAllowed: Bool {
        !drawsStillFrames
            && !Design.Motion.reducesMotion
            && DesignSettings.current.playsThemeMotion
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Runs `body` with every field it builds drawn as its still frame — for a preview or a
    /// render, which cannot capture a live emitter's particles. Scoped to one synchronous body,
    /// so no live field is ever asked to still itself.
    static func withStillFrames<T>(_ body: () throws -> T) rethrows -> T {
        let previous = drawsStillFrames
        drawsStillFrames = true
        defer { drawsStillFrames = previous }
        return try body()
    }

    /// A deterministic seam for behaviour tests, whose windows are never on screen — the same
    /// shape as `Design.Motion.reduceMotionOverrideForTesting`. Production reads the window.
    static var seenOverrideForTesting: Bool?

    /// Whether `view` is somewhere a person could currently see it.
    static func isSeen(_ view: NSView?) -> Bool {
        if let seenOverrideForTesting { return seenOverrideForTesting && view != nil }
        guard let view, let window = view.window else { return false }
        return window.isVisible
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
            && !view.isHiddenOrHasHiddenAncestor
            && !NSApp.isHidden
    }

    func register(_ member: ThemeParticleHolding) {
        members.add(member)
        startObservingIfNeeded()
    }

    /// Re-asks every live member. Called for every change the hold observes; a host whose own
    /// visibility moved (a view unhidden, a window reopened) can say so directly.
    func refreshAll() {
        for case let member as ThemeParticleHolding in members.allObjects {
            member.refreshParticleMotion()
        }
    }

    private func startObservingIfNeeded() {
        guard !isObserving else { return }
        isObserving = true

        let center = NotificationCenter.default
        let windowNotifications: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ]
        let appNotifications: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]
        for name in windowNotifications + appNotifications {
            notificationObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { ThemeParticleHold.shared.refreshAll() }
            })
        }
        // Posted on whichever thread changed the power state.
        notificationObservers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ThemeParticleHold.shared.refreshAll() }
        })

        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { _ in
            ThemeParticleHold.shared.refreshAll()
        }
        appEvents.observe(AppSettingsDidChange.self) { _ in
            ThemeParticleHold.shared.refreshAll()
        }
    }
}
