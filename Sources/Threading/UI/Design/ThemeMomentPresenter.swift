import AppKit

// MARK: - Theme Moment Presenter

/// Plays the current theme's answer to an app event (`ThemeMoments`): a shower of its particles
/// across every visible main window, and its own short sound.
///
/// **One at a time, then quiet.** Agents finish together more often than not, and five showers
/// in five seconds would be a theme shouting. The first event plays; everything after it is
/// absorbed until `ThemeMomentLimits.cooldown` has passed, whichever event it was. A moment never
/// interrupts a theme's arrival either — while a transition plays, events are absorbed too.
///
/// **Particles are motion and obey the hold.** Under Reduce Motion, the Theme animations setting
/// or Low Power Mode, or with no window a person can see, nothing is drawn. The shower is the
/// arrival overlay's timeline with no wash and a fraction of its budget
/// (`ThemeParticleBudget.momentMaximumAlive`), so its cost is bounded the same way.
///
/// **Sounds speak only inside the app.** A theme sound plays while Threading is frontmost, the
/// Theme sounds setting is on and the global silence is off. Outside the app the person's own
/// notification sounds already answer these events; a theme adding a second voice there would
/// be the theme overriding a choice the person made.
@MainActor
final class ThemeMomentPresenter {

    static let shared = ThemeMomentPresenter()

    private let appEvents = AppEventObservations()
    private var installed = false
    private var lastPlayed: TimeInterval?
    /// Decoded sounds by stored file; emptied when the theme changes.
    private var sounds: [String: NSSound] = [:]

    /// Seams for tests: the clock, the windows to play over, and whether the app is in front.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var windowsProvider: () -> [NSWindow] = { ThemeTransitionPresenter.shared.windowsProvider() }
    var isAppActive: () -> Bool = { NSApp.isActive }
    var soundPlayer: (NSSound) -> Void = { sound in
        sound.stop()
        sound.play()
    }

    /// What the last event did — for a test, and for the event log.
    enum Outcome: Equatable {
        case noTheme
        case nothingStated
        case coolingDown
        case played(particles: Bool, sound: Bool)
    }

    // MARK: - Public Methods

    /// Observes the app's moments for the life of the process. Called from the real startup;
    /// the mood monitor is only started while the theme in force states moments.
    func install() {
        guard !installed else { return }
        installed = true
        appEvents.observe(AgentMomentDidOccur.self) { [weak self] event in
            self?.handle(event.event)
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.sounds.removeAll()
            self?.startMonitorIfNeeded()
        }
        startMonitorIfNeeded()
    }

    /// Plays `event` in the current theme's voice, if it has one and the cooldown allows.
    @discardableResult
    func handle(_ event: ThemeMomentEvent) -> Outcome {
        let theme = AppThemePalette.current
        guard !theme.isSystem,
              let variant = theme.variant(for: NSApp.effectiveAppearance) else { return .noTheme }
        guard let moment = variant.moments?[event] else { return .nothingStated }
        let time = now()
        if let lastPlayed, time - lastPlayed < ThemeMomentLimits.cooldown {
            return .coolingDown
        }
        guard !ThemeTransitionPresenter.shared.isPlaying else { return .coolingDown }
        lastPlayed = time

        let showered = shower(moment, theme: theme)
        let sounded = sound(moment, theme: theme)
        return .played(particles: showered, sound: sounded)
    }

    /// Forgets the cooldown — a test's way of playing two moments in a row.
    func resetCooldown() {
        lastPlayed = nil
    }

    // MARK: - Private Methods

    private func startMonitorIfNeeded() {
        let states = AppThemePalette.current.variants.values.contains { $0.moments != nil }
        if states { AgentMoodMonitor.shared.start() }
    }

    private func shower(_ moment: ThemeMoments.Moment, theme: AppTheme) -> Bool {
        guard let particles = moment.particles,
              ThemeParticleHold.motionAllowed,
              Design.Motion.themeMoment(moment.duration) > 0 else { return false }
        let hosts = windowsProvider().filter { $0.contentView != nil }
        guard !hosts.isEmpty else { return false }

        let appearance = NSApp.effectiveAppearance
        var colors: [NSColor] = []
        appearance.performAsCurrentDrawingAppearance {
            colors = particles.resolvedInks.map { $0.resolved(in: theme, appearance: appearance) }
        }
        let palette = ThemeTransitionOverlayView.Palette(
            transition: ThemeTransition(
                particles: particles,
                duration: Design.Motion.themeMoment(moment.duration),
                washOpacity: 0,
                shimmer: false
            ),
            particleColors: colors,
            particleSprites: ThemeBackdropAppearance.sprites(
                particles.sprites,
                theme: theme,
                appearance: appearance
            ),
            wash: .clear,
            shimmer: .clear,
            budgetShare: Double(ThemeParticleBudget.momentMaximumAlive)
                / Double(ThemeParticleBudget.transitionMaximumAlive)
        )
        for window in hosts {
            guard let root = window.contentView else { continue }
            let overlay = ThemeTransitionOverlayView(frame: root.bounds)
            root.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlay.play(palette) {}
        }
        return true
    }

    private func sound(_ moment: ThemeMoments.Moment, theme: AppTheme) -> Bool {
        guard let name = moment.sound,
              AppSettings.shared.playsThemeSounds,
              !SoundResolution.isSilenced,
              isAppActive(),
              let sound = decodedSound(named: name, themeID: theme.id) else { return false }
        soundPlayer(sound)
        return true
    }

    /// The stored sound, decoded once per theme. The file is at most
    /// `ThemeMomentLimits.maximumSoundBytes`, and the read is bounded like every theme asset's.
    private func decodedSound(named name: String, themeID: AppThemeID) -> NSSound? {
        if let cached = sounds[name] { return cached }
        guard let data = ThemeAssetStore.pngData(named: name, for: themeID),
              let sound = NSSound(data: data) else { return nil }
        sounds[name] = sound
        return sound
    }
}
