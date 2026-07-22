import AppKit

/// Reads and writes which theme a session, a project, or the app as a whole draws with.
///
/// The assignments live on the records they theme — `AgentSession.themeName` and
/// `Project.themeName` in `projects.json`, the default on the profile in `UserDefaults` — so
/// each is saved, restored and deleted with the thing it applies to, rather than in a side
/// table that would outlive it and re-theme whatever later reused the identifier.
///
/// Everything that draws a terminal reads through here rather than reaching for
/// `ProfileStorage.defaultProfile.theme`, which is now only the *last* answer in the chain.
@MainActor
enum ThemeAssignments {

    // MARK: - Resolution

    /// The theme the app falls back to: the one the profile carries.
    ///
    /// Stored as an embedded copy rather than a name, which is deliberate — it is what keeps a
    /// terminal drawing after the theme it names has been deleted from the list.
    static var defaultTheme: TerminalTheme {
        ProfileStorage.shared.defaultProfile.theme
    }

    /// The theme a session's terminal draws with.
    static func theme(for sessionID: SessionID?) -> TerminalTheme {
        guard let sessionID, let assignment = resolution(for: sessionID) else {
            return defaultTheme
        }
        return ThemeManager.shared.theme(named: assignment.themeName) ?? defaultTheme
    }

    /// The whole profile a session's terminal runs with: the user's own profile — font, cursor,
    /// scrollback, shell — carrying that session's resolved theme.
    ///
    /// Only the theme is scoped. The rest of a profile describes how the user works rather than
    /// how one conversation looks, and a per-session shell is a different feature.
    static func profile(for sessionID: SessionID?) -> TerminalProfile {
        var profile = ProfileStorage.shared.defaultProfile
        profile.theme = theme(for: sessionID)
        return profile
    }

    /// Which theme applies to a session and which scope decided it.
    static func resolution(for sessionID: SessionID) -> ThemeResolution.Assignment? {
        let store = ProjectStore.shared
        return ThemeResolution.resolve(
            session: store.session(withID: sessionID)?.themeName,
            project: store.project(forSessionID: sessionID)?.themeName,
            global: defaultTheme.name,
            available: availableNames
        )
    }

    /// What a session would draw with if its own assignment were cleared — the label the
    /// menu's "Inherit" item wears, so inheriting says what it inherits.
    static func inheritedName(forSession sessionID: SessionID) -> String {
        let store = ProjectStore.shared
        let resolved = ThemeResolution.resolve(
            session: nil,
            project: store.project(forSessionID: sessionID)?.themeName,
            global: defaultTheme.name,
            available: availableNames
        )
        return resolved?.themeName ?? defaultTheme.name
    }

    /// The same, one scope out: what a project falls back to.
    static func inheritedName(forProject projectID: ProjectID) -> String {
        defaultTheme.name
    }

    // MARK: - Assignments

    static func themeName(forSession sessionID: SessionID) -> String? {
        ProjectStore.shared.session(withID: sessionID)?.themeName
    }

    static func themeName(forProject projectID: ProjectID) -> String? {
        ProjectStore.shared.project(withID: projectID)?.themeName
    }

    /// Assigns a theme to one session, or clears it with nil so it inherits again.
    static func setTheme(named name: String?, forSession sessionID: SessionID) {
        ProjectStore.shared.setThemeName(name, forSessionID: sessionID)
        notifyChanged()
    }

    /// Assigns a theme to every session in a project that has not chosen its own.
    static func setTheme(named name: String?, forProject projectID: ProjectID) {
        ProjectStore.shared.setThemeName(name, forProjectID: projectID)
        notifyChanged()
    }

    /// Sets the app-wide default, which every unassigned session follows.
    static func setDefaultTheme(_ theme: TerminalTheme) {
        // `setTheme` posts `.profileDidChange`, which the terminals re-resolve on.
        ProfileStorage.shared.setTheme(theme)
    }

    // MARK: - Theme Lifecycle

    static var availableNames: Set<String> {
        Set(ThemeManager.shared.allThemes.map(\.name))
    }

    /// Renames a theme and re-points every assignment naming it.
    ///
    /// Resolution treats an unknown name as "inherit", which is the right answer for a theme
    /// that was *deleted* and the wrong one for a theme that was merely renamed: without this,
    /// renaming would silently reset every session and project using it. This is the only
    /// rename path — `ThemeManager.renameTheme` alone leaves the references behind.
    @discardableResult
    static func rename(_ theme: TerminalTheme, to newName: String) -> Bool {
        let oldName = theme.name
        guard ThemeManager.shared.renameTheme(theme, to: newName) else { return false }

        ProjectStore.shared.renameTheme(from: oldName, to: newName)

        // The default is an embedded copy, so it carries the old name until it is re-saved.
        if defaultTheme.name == oldName, let renamed = ThemeManager.shared.theme(named: newName) {
            ProfileStorage.shared.setTheme(renamed)
        }

        notifyChanged()
        return true
    }

    /// Stores a *new* theme, refusing to replace one that already exists.
    ///
    /// `ThemeManager.addTheme` replaces silently by name, which is what an editor wants when
    /// saving an edit and exactly what a creator must not do: a clobbered custom theme is
    /// unrecoverable, and the caller most likely to hit this is an agent inventing a name.
    static func create(_ theme: TerminalTheme) -> Bool {
        guard ThemeManager.shared.theme(named: theme.name) == nil else { return false }
        ThemeManager.shared.addTheme(theme)
        return true
    }

    /// Whether a foreground and background can be told apart at terminal text sizes.
    ///
    /// A theme is the one setting that can make the app's own input surface unreadable, and the
    /// terminal is where the user would have to type to undo it. Only this pair is checked: an
    /// ANSI colour close to the background is ordinary — a dark "black" on a dark ground is how
    /// most themes are built — while text the colour of its own background is never intended.
    static func hasLegibleContrast(foreground: NSColor, background: NSColor) -> Bool {
        contrastRatio(foreground, background) >= ThemeDefaults.minimumContrastRatio
    }

    /// WCAG relative-luminance contrast, in the sRGB space both colours are stored in.
    static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }

        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    // MARK: - Notification

    private static func notifyChanged() {
        NotificationCenter.default.post(name: .themeAssignmentsDidChange, object: nil)
    }
}

// MARK: - Defaults

enum ThemeDefaults {
    /// WCAG's floor for large text. Terminal type is small, but a theme is a deliberate
    /// aesthetic choice and holding it to body-text contrast would reject palettes people
    /// genuinely use — this rejects the unreadable, not the low-contrast.
    static let minimumContrastRatio: CGFloat = 3.0
}

// MARK: - Notifications

extension Notification.Name {
    /// A session's or project's theme assignment changed. Terminals re-resolve their own
    /// theme rather than adopting anything the notification carries, since a broadcast value
    /// is exactly what a per-session override must not be overwritten by.
    static let themeAssignmentsDidChange = Notification.Name("themeAssignmentsDidChange")
}
