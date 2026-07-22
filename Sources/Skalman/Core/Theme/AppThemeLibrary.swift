import AppKit

// MARK: - Current Palette

/// The palette every themed colour reads at draw time.
///
/// Held outside `AppThemeLibrary`'s main-actor isolation because the readers are colour
/// providers, which AppKit calls while drawing. Drawing is on main, so this is written and read
/// on one thread in practice; it is a plain static rather than a lock because a torn read of an
/// object reference is not a thing that happens here and a lock in a draw path is.
enum AppThemePalette {

    private(set) nonisolated(unsafe) static var current: AppTheme = .system

    static func set(_ theme: AppTheme) { current = theme }

    /// A colour that resolves through the *current* theme every time it is drawn.
    ///
    /// This is what makes the refactor tractable, and it was measured rather than assumed: a
    /// dynamic `NSColor` re-runs its provider when the theme changes, not only when the system
    /// appearance does. So the ~150 label call sites need nothing but a token swap, and a
    /// redraw picks the new colour up.
    ///
    /// The exception, also measured, is `CALayer.backgroundColor`: a `CGColor` is resolved once
    /// at assignment and frozen. Those sites are re-applied by `AppThemeRefresh`.
    static func color(_ role: AppThemeRole) -> NSColor {
        NSColor(name: NSColor.Name("skalman.\(role.rawValue)")) { _ in
            current.resolved(role)
        }
    }
}

// MARK: - Library

/// The themes the app offers for its own chrome, and which one is in force.
@MainActor
enum AppThemeLibrary {

    private enum Keys {
        static let currentThemeID = "appThemeID"
    }

    // MARK: Catalogue

    /// Stock themes, System first.
    ///
    /// Written in Swift rather than loaded from a bundled JSON on purpose: the roles a theme
    /// states are few enough that a literal is shorter than the document, and it is checked by
    /// the compiler and readable in a diff. The `Codable` path exists for the themes an agent
    /// or a user creates, which live in Application Support.
    static var stock: [AppTheme] { [.system] + AppThemeStyles.all }

    static func theme(withID id: AppThemeID) -> AppTheme? {
        stock.first { $0.id == id }
    }

    // MARK: Current

    private(set) static var current: AppTheme = .system

    /// Reads the stored choice at launch. Called before the first window is built, so nothing
    /// has to be refreshed — everything is created already themed.
    static func restore() {
        let stored = UserDefaults.standard.string(forKey: Keys.currentThemeID)
        let restored = stored.flatMap { theme(withID: AppThemeID($0)) } ?? AppTheme.system
        current = restored
        AppThemePalette.set(restored)
        applyAppearance(for: restored)
    }

    /// Pins the system appearance to the theme's own mode.
    ///
    /// Shared by `restore` and `apply`, because leaving it out of the launch path is a bug that
    /// hides: a dark style launched under a dark system looks correct by luck, and the same
    /// build launches a *light* style as a white app wearing dark scrollers, dark menus and a
    /// dark switch. Every system-drawn control follows this and nothing else.
    private static func applyAppearance(for theme: AppTheme) {
        NSApp.appearance = theme.isSystem ? nil : theme.mode.appearance
    }

    /// Switches the app's theme and repaints everything already on screen.
    static func apply(_ theme: AppTheme) {
        guard theme != current else { return }

        current = theme
        AppThemePalette.set(theme)
        UserDefaults.standard.set(theme.id.rawValue, forKey: Keys.currentThemeID)

        // A dark theme under the light system appearance gets light scrollers, menus and text
        // selection drawn over it, which is the give-away that a theme is a paint job. Setting
        // the app's appearance is what makes the system-drawn parts follow.
        applyAppearance(for: theme)

        AppThemeRefresh.repaintEverything()
        NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
    }
}

// MARK: - Event

struct AppThemeDidChange: AppEvent {
    static let name = Notification.Name("appThemeDidChange")
    let themeID: AppThemeID
}
