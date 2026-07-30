import AppKit

// MARK: - App Icon Presenter

/// Keeps the Dock tile wearing the app theme.
///
/// **Only `applicationIconImage`, deliberately.** Three tiers of runtime icon exist on macOS and
/// this is the cheapest one: it reaches the Dock tile, the ⌘-Tab switcher and the About panel,
/// for the lifetime of the process, and costs nothing. The tier above it —
/// `NSWorkspace.setIcon(_:forFile:)` on our own bundle, plus an `NSDockTilePlugin` so the Dock
/// keeps the icon while the app is not running — buys a themed Finder icon in exchange for
/// writing into a bundle built with `ENABLE_HARDENED_RUNTIME`, which invalidates its signature,
/// and a private call to make the Dock drop its icon cache. The premise does not survive the
/// trade: the icon matches the chrome the user is looking at, and there is no chrome to match
/// when the app is not running.
///
/// `dockTile.contentView` is the other half of tier one and is **not** used with this. Setting
/// both makes the tile flicker between them; the choice here is the one that needs no view to
/// stay alive and no `display()` call to stay correct.
///
/// Nil restores the bundle icon, which is what the System theme asks for — see
/// `GeneratedAppIcon`.
@MainActor
enum AppIconPresenter {

    // MARK: - Properties

    private static var observations: AppEventObservations?
    private static var appearanceObservation: NSKeyValueObservation?

    // MARK: - Public Methods

    /// Draws the current theme's icon and follows it from then on.
    ///
    /// Two triggers, because neither implies the other. A theme change need not move the
    /// appearance — Cyberpunk to Art Deco is dark to dark, and `effectiveAppearance` never
    /// fires — and a system appearance change need not be a theme change, but decides which
    /// variant an adaptive theme draws with.
    static func install() {
        guard observations == nil else { return }

        let observations = AppEventObservations()
        // Hopped rather than asserted. Most callers of `AppThemeLibrary.apply` are already on
        // the main actor, but the remote server's is not until it hops itself — and a redrawn
        // Dock tile is not worth a trap on the one future path that forgets.
        observations.observe(AppThemeDidChange.self) { _ in
            DispatchQueue.main.async { refresh() }
        }
        self.observations = observations

        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { refresh() }
        }

        refresh()
    }

    /// Redraws the Dock tile for whatever theme and appearance are current.
    static func refresh() {
        NSApp.applicationIconImage = GeneratedAppIcon.image(
            for: AppThemeLibrary.current,
            appearance: NSApp.effectiveAppearance
        )
    }
}
