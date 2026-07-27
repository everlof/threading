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
        NSColor(name: NSColor.Name("skalman.\(role.rawValue)")) { appearance in
            current.resolved(role, appearance: appearance)
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
    /// the compiler and readable in a diff. The `Codable` path serves the persistent themes an
    /// agent or a user creates through `AppThemeStore`.
    static var stock: [AppTheme] { [.system] + AppThemeStyles.all }

    /// Themes enabled extensions contribute — a third tier between stock and custom: present
    /// while their extension is enabled, never editable (an update to the package is how they
    /// change), and namespaced ids (`ext.<extension>.<theme>`) so they cannot collide with or
    /// impersonate anything in the other two tiers.
    static var contributed: [AppTheme] { ExtensionAppearanceRegistry.shared.themes }

    static var custom: [AppTheme] { AppThemeStore.shared.themes }

    static var all: [AppTheme] { stock + contributed + custom }

    static func theme(withID id: AppThemeID) -> AppTheme? {
        all.first { $0.id == id }
    }

    static func isStock(_ theme: AppTheme) -> Bool {
        stock.contains { $0.id == theme.id }
    }

    static func isContributed(_ theme: AppTheme) -> Bool {
        contributed.contains { $0.id == theme.id }
    }

    /// The name of the extension a contributed theme came from, for the picker and MCP listing.
    static func contributorName(of theme: AppTheme) -> String? {
        ExtensionAppearanceRegistry.shared.contributorName(forThemeID: theme.id)
    }

    static func isCustom(_ theme: AppTheme) -> Bool {
        custom.contains { $0.id == theme.id }
    }

    /// Called by the appearance registry when the contributed tier changes.
    ///
    /// A vanished theme falls back exactly the way a deleted custom theme does — to System,
    /// recorded as the new choice, so it does not snap back on a later re-enable. The one
    /// divergence `restore()` can leave — the stored choice unresolvable at launch because its
    /// extension had not started the session enabled — heals here: the moment the standing
    /// choice becomes resolvable again it is taken again. A *deliberate* pick made while
    /// fallen back is safe from that, because `apply` records even a pick that changed
    /// nothing on screen.
    static func contributedThemesDidChange() {
        if theme(withID: current.id) == nil {
            apply(.system)
        } else if let stored = UserDefaults.standard.string(forKey: Keys.currentThemeID),
                  stored != current.id.rawValue,
                  let standing = theme(withID: AppThemeID(stored)) {
            apply(standing)
        }
        NotificationCenter.default.post(AppThemeLibraryDidChange())
    }

    static func uniqueCopyName(of theme: AppTheme) -> String {
        let names = Set(all.map { $0.name.lowercased() })
        var candidate = "\(theme.name) Copy"
        var index = 2
        while names.contains(candidate.lowercased()) {
            candidate = "\(theme.name) Copy \(index)"
            index += 1
        }
        return candidate
    }

    static func makeCustomID() -> AppThemeID {
        AppThemeID("custom-\(UUID().uuidString.lowercased())")
    }

    static func create(_ theme: AppTheme) throws {
        guard theme.id != .system, self.theme(withID: theme.id) == nil else {
            throw AppThemeEditingError.invalid(
                "An app theme with id \"\(theme.id.rawValue)\" already exists."
            )
        }
        guard !all.contains(where: {
            $0.name.caseInsensitiveCompare(theme.name) == .orderedSame
        }) else {
            throw AppThemeEditingError.invalid(
                "An app theme named \"\(theme.name)\" already exists."
            )
        }
        try AppThemeEditing.validate(theme)
        AppThemeStore.shared.insert(theme)
        NotificationCenter.default.post(AppThemeLibraryDidChange())
    }

    static func update(_ theme: AppTheme) throws {
        guard isCustom(theme) else {
            throw AppThemeEditingError.invalid(
                isContributed(theme)
                    ? "Extension-contributed app themes cannot be edited here. Duplicate this "
                        + "theme to make an editable copy, or update the extension that ships it."
                    : "Built-in app themes cannot be edited. Duplicate this theme first."
            )
        }
        guard !all.contains(where: {
            $0.id != theme.id && $0.name.caseInsensitiveCompare(theme.name) == .orderedSame
        }) else {
            throw AppThemeEditingError.invalid(
                "Another app theme is already named \"\(theme.name)\"."
            )
        }
        try AppThemeEditing.validate(theme)
        guard AppThemeStore.shared.replace(theme) else {
            throw AppThemeEditingError.invalid("The custom app theme no longer exists.")
        }
        NotificationCenter.default.post(AppThemeLibraryDidChange())
        if current.id == theme.id {
            apply(theme)
        }
    }

    @discardableResult
    static func delete(_ theme: AppTheme) -> Bool {
        guard isCustom(theme), AppThemeStore.shared.remove(id: theme.id) else { return false }
        if current.id == theme.id {
            apply(.system)
        }
        NotificationCenter.default.post(AppThemeLibraryDidChange())
        return true
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
        NSApp.appearance = theme.mode.appearance
    }

    /// Switches the app's theme and repaints everything already on screen.
    static func apply(_ theme: AppTheme) {
        // Recorded before the no-op guard: a pick that changes nothing on screen is still the
        // user's answer. The case that found this: launch falls back because a contributed
        // theme's extension is disabled, the user then picks System deliberately — a choice
        // the early return used to swallow, leaving the stored id pointing at the old theme.
        UserDefaults.standard.set(theme.id.rawValue, forKey: Keys.currentThemeID)
        guard theme != current else { return }

        current = theme
        AppThemePalette.set(theme)

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

struct AppThemeLibraryDidChange: AppEvent {
    static let name = Notification.Name("appThemeLibraryDidChange")
}
