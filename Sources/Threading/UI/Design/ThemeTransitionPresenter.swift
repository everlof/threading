import AppKit

// MARK: - Theme Switch

/// The way a *deliberate* app-theme pick is applied: a choice in Settings or onboarding, the
/// Current Theme page, or an agent's `set_app_theme`/`create_app_theme`. It plays the incoming
/// theme's `ThemeTransition` when it has one and motion may play, and is exactly
/// `AppThemeLibrary.apply` when it does not.
///
/// Deliberately *not* the path for everything that applies a theme: a launch restoring the
/// standing choice, macOS flipping an adaptive theme's variant, an extension's contributed theme
/// reloading, and a live edit repainting the theme already worn all repaint at once. A
/// transition is how a theme *arrives*, and none of those is an arrival.
@MainActor
enum ThemeSwitch {

    static func apply(_ theme: AppTheme) {
        ThemeTransitionPresenter.shared.present(theme)
    }
}

// MARK: - Theme Transition Presenter

/// Plays a theme's arrival over every visible main window and swaps the theme under it.
///
/// One transition at a time, and the rule for a second is the only one that keeps every
/// outcome correct: the playing one is *finished* — its theme applied if the swap had not yet
/// happened, its overlays removed — and the new one starts from a window already wearing the
/// theme it is leaving. Nothing queues, so a burst of picks lands on the last one.
///
/// Every reason not to play falls through to a plain apply, never to nothing: no transition
/// stated, Reduce Motion, the Theme Motion setting, no window a person can see, or the pick
/// being the theme already worn (which still records the choice, as `apply` always has).
@MainActor
final class ThemeTransitionPresenter {

    static let shared = ThemeTransitionPresenter()

    private struct Playing {
        let theme: AppTheme
        var hasSwapped: Bool
        var overlays: [ThemeTransitionOverlayView]
        let generation: Int
    }

    private var playing: Playing?
    private var generation = 0

    /// Windows the presenter plays over: every window a person can see whose content root
    /// hosts in-window overlays, which is the main window in both dresses. Replaceable so a
    /// test can hand it a window of its own.
    var windowsProvider: () -> [NSWindow] = {
        NSApp.windows.filter { window in
            window.contentViewController is InWindowOverlayHosting
                && window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }

    // MARK: - Public Methods

    func present(_ theme: AppTheme) {
        finishPlaying()

        guard theme != AppThemeLibrary.current,
              let palette = Self.palette(for: theme),
              ThemeParticleHold.motionAllowed else {
            AppThemeLibrary.apply(theme)
            return
        }

        let hosts = windowsProvider().filter { $0.contentView != nil }
        guard !hosts.isEmpty else {
            AppThemeLibrary.apply(theme)
            return
        }

        generation += 1
        let generation = generation
        var overlays: [ThemeTransitionOverlayView] = []
        for window in hosts {
            guard let root = window.contentView else { continue }
            let overlay = ThemeTransitionOverlayView(frame: root.bounds)
            root.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlays.append(overlay)
        }
        playing = Playing(theme: theme, hasSwapped: false, overlays: overlays, generation: generation)

        for overlay in overlays {
            overlay.play(palette) { [weak self] in
                self?.overlayDidFinish(overlay, generation: generation)
            }
        }

        let duration = Design.Motion.themeTransition(palette.transition.duration)
        let swapAt = duration * Design.Motion.themeTransitionSwapFraction
        DispatchQueue.main.asyncAfter(deadline: .now() + swapAt) { [weak self] in
            self?.swap(generation: generation)
        }
    }

    /// Whether a transition is on screen — what a test asks.
    var isPlaying: Bool { playing != nil }

    // MARK: - Private Methods

    private func swap(generation: Int) {
        guard var current = playing, current.generation == generation, !current.hasSwapped else {
            return
        }
        current.hasSwapped = true
        playing = current
        AppThemeLibrary.apply(current.theme)
    }

    private func overlayDidFinish(_ overlay: ThemeTransitionOverlayView, generation: Int) {
        guard var current = playing, current.generation == generation else { return }
        current.overlays.removeAll { $0 === overlay }
        playing = current.overlays.isEmpty ? nil : current
    }

    /// Ends whatever is playing now: the theme it carried applied if it had not been yet, every
    /// overlay gone.
    private func finishPlaying() {
        guard let current = playing else { return }
        playing = nil
        for overlay in current.overlays {
            overlay.removeFromSuperview()
        }
        if !current.hasSwapped {
            AppThemeLibrary.apply(current.theme)
        }
    }

    /// The incoming theme's transition with its inks resolved for the appearance it will be
    /// worn in, or nil when the theme states none and no `fallback` is given. The fallback is
    /// resolved against the theme the same way — a gallery playing a sample arrival in the
    /// theme being worn.
    static func palette(
        for theme: AppTheme,
        fallback: ThemeTransition? = nil
    ) -> ThemeTransitionOverlayView.Palette? {
        let appearance = arrivalAppearance(for: theme)
        guard let transition = theme.variant(for: appearance)?.transition ?? fallback else {
            return nil
        }
        var particleColors: [NSColor] = []
        var wash = NSColor.black
        var shimmer = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            particleColors = transition.particles.resolvedInks.map {
                $0.resolved(in: theme, appearance: appearance)
            }
            wash = (transition.wash ?? .role(.ground)).resolved(in: theme, appearance: appearance)
            shimmer = particleColors.first ?? theme.resolved(.accent, appearance: appearance)
        }
        return ThemeTransitionOverlayView.Palette(
            transition: transition,
            particleColors: particleColors,
            wash: wash,
            shimmer: shimmer
        )
    }

    /// The appearance the theme will be worn in: its own when it pins one, the system's when it
    /// follows macOS. The app's current appearance is the *leaving* theme's pin and would answer
    /// for the wrong variant.
    static func arrivalAppearance(for theme: AppTheme) -> NSAppearance {
        if let pinned = theme.mode.appearance { return pinned }
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }
}
