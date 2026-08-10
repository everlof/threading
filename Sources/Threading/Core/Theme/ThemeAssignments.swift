import AppKit

/// Reads and writes which theme a session, standalone terminal, project, or the app draws with.
///
/// The assignments live on the records they theme — `AgentSession.themeID` and
/// `Project.themeID` in `projects.json`, the default on the profile in `UserDefaults` — so
/// each is saved, restored and deleted with the thing it applies to, rather than in a side
/// table that would outlive it and re-theme whatever later reused the identifier.
///
/// Everything that draws a terminal reads through here rather than reaching for
/// `ProfileStorage.defaultProfile.theme`, which is now only the *last* answer in the chain.
@MainActor
enum ThemeAssignments {

    // MARK: - Resolution

    /// The terminal-theme list's dynamic entry. Its palette is only a preview of what following
    /// the app means right now; the reserved ID is the durable choice, so changing app themes
    /// later re-resolves instead of leaving terminals on a snapshot.
    static var followsAppTheme: TerminalTheme {
        AppThemeLibrary.current.terminalPalette.identified(
            .followsAppTheme,
            named: TerminalThemeNames.followsAppTheme
        )
    }

    /// Everything a user or agent may select, including the dynamic app-linked entry that is
    /// deliberately not stored in `ThemeManager` as an editable palette.
    static var selectableThemes: [TerminalTheme] {
        [followsAppTheme] + ThemeManager.shared.allThemes
    }

    static func selectableTheme(withID id: TerminalThemeID) -> TerminalTheme? {
        id == .followsAppTheme ? followsAppTheme : ThemeManager.shared.theme(withID: id)
    }

    /// Compatibility for persisted names and older MCP clients. New assignments use IDs.
    static func selectableTheme(named name: String) -> TerminalTheme? {
        name.caseInsensitiveCompare(TerminalThemeNames.followsAppTheme) == .orderedSame
            ? followsAppTheme
            : ThemeManager.shared.theme(named: name)
    }

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
            return palette(withID: defaultTheme.id)
        }
        return palette(withID: assignment.themeID)
    }

    /// An ID to a palette, with the dynamic app-theme entry answered first.
    static func palette(withID id: TerminalThemeID) -> TerminalTheme {
        if id == .followsAppTheme {
            return AppThemeLibrary.current.terminalPalette
        }
        guard let identified = ThemeManager.shared.theme(withID: id) else {
            // The stored default is an embedded copy, so it answers even when the theme it was
            // copied from is gone — but if *it* is the app-theme entry, that resolves first.
            let fallback = defaultTheme
            return fallback.id == .followsAppTheme
                ? AppThemeLibrary.current.terminalPalette
                : fallback
        }
        return identified
    }

    /// Compatibility for pre-ID callers and migration tests.
    static func palette(named name: String) -> TerminalTheme {
        guard let theme = selectableTheme(named: name) else { return defaultTheme }
        return palette(withID: theme.id)
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

    /// A standalone terminal follows the project at its current cwd, then the app, unless it
    /// carries its own override.
    static func theme(forTerminal terminalID: TerminalID) -> TerminalTheme {
        guard let assignment = resolution(forTerminal: terminalID) else {
            return palette(withID: defaultTheme.id)
        }
        return palette(withID: assignment.themeID)
    }

    static func profile(forTerminal terminalID: TerminalID) -> TerminalProfile {
        var profile = ProfileStorage.shared.defaultProfile
        profile.theme = theme(forTerminal: terminalID)
        return profile
    }

    static func resolution(forTerminal terminalID: TerminalID) -> ThemeResolution.Assignment? {
        let store = ProjectStore.shared
        return ThemeResolution.resolve(
            session: canonicalID(store.terminal(withID: terminalID)?.themeID),
            project: canonicalID(store.displayProject(forTerminalID: terminalID)?.themeID),
            global: canonicalID(defaultTheme.id),
            available: availableIDs
        )
    }

    /// Which theme applies to a session and which scope decided it.
    static func resolution(for sessionID: SessionID) -> ThemeResolution.Assignment? {
        let store = ProjectStore.shared
        return ThemeResolution.resolve(
            session: canonicalID(store.session(withID: sessionID)?.themeID),
            project: canonicalID(store.project(forSessionID: sessionID)?.themeID),
            global: canonicalID(defaultTheme.id),
            available: availableIDs
        )
    }

    /// What a session would draw with if its own assignment were cleared — the label the
    /// menu's "Inherit" item wears, so inheriting says what it inherits.
    static func inheritedName(forSession sessionID: SessionID) -> String {
        inheritedTheme(forSession: sessionID).name
    }

    /// The palette a session would draw with if its own assignment were cleared.
    static func inheritedTheme(forSession sessionID: SessionID) -> TerminalTheme {
        let store = ProjectStore.shared
        let resolved = ThemeResolution.resolve(
            session: nil,
            project: canonicalID(store.project(forSessionID: sessionID)?.themeID),
            global: canonicalID(defaultTheme.id),
            available: availableIDs
        )
        return resolved.map { palette(withID: $0.themeID) } ?? defaultTheme
    }

    static func inheritedName(forTerminal terminalID: TerminalID) -> String {
        inheritedTheme(forTerminal: terminalID).name
    }

    static func inheritedTheme(forTerminal terminalID: TerminalID) -> TerminalTheme {
        let store = ProjectStore.shared
        let resolved = ThemeResolution.resolve(
            session: nil,
            project: canonicalID(store.displayProject(forTerminalID: terminalID)?.themeID),
            global: canonicalID(defaultTheme.id),
            available: availableIDs
        )
        return resolved.map { palette(withID: $0.themeID) } ?? defaultTheme
    }

    /// The same, one scope out: what a project falls back to.
    static func inheritedName(forProject projectID: ProjectID) -> String {
        defaultTheme.name
    }

    // MARK: - Assignments

    static func themeID(forSession sessionID: SessionID) -> TerminalThemeID? {
        canonicalID(ProjectStore.shared.session(withID: sessionID)?.themeID)
    }

    static func themeID(forProject projectID: ProjectID) -> TerminalThemeID? {
        canonicalID(ProjectStore.shared.project(withID: projectID)?.themeID)
    }

    static func themeID(forTerminal terminalID: TerminalID) -> TerminalThemeID? {
        canonicalID(ProjectStore.shared.terminal(withID: terminalID)?.themeID)
    }

    /// Assigns a theme to one session, or clears it with nil so it inherits again.
    @discardableResult
    static func setTheme(
        id: TerminalThemeID?,
        forSession sessionID: SessionID
    ) -> ProjectMutationResult {
        let result = ProjectStore.shared.setThemeID(id, forSessionID: sessionID)
        if result == .applied { notifyChanged() }
        return result
    }

    /// Assigns a theme to every session in a project that has not chosen its own.
    @discardableResult
    static func setTheme(
        id: TerminalThemeID?,
        forProject projectID: ProjectID
    ) -> ProjectMutationResult {
        let result = ProjectStore.shared.setThemeID(id, forProjectID: projectID)
        if result == .applied { notifyChanged() }
        return result
    }

    @discardableResult
    static func setTheme(
        id: TerminalThemeID?,
        forTerminal terminalID: TerminalID
    ) -> ProjectMutationResult {
        let result = ProjectStore.shared.setThemeID(id, forTerminalID: terminalID)
        if result == .applied { notifyChanged() }
        return result
    }

    /// Sets the app-wide default, which every unassigned session follows.
    static func setDefaultTheme(_ theme: TerminalTheme) {
        // `setTheme` posts `ProfileDidChange`, which the terminals re-resolve on.
        ProfileStorage.shared.setTheme(theme)
    }

    // MARK: - Theme Lifecycle

    /// Includes the app-theme entry, or resolution would treat it as dangling and inherit.
    static var availableIDs: Set<TerminalThemeID> {
        Set(selectableThemes.map(\.id))
    }

    /// Renames only the label. Session and project assignments keep pointing at the same ID.
    @discardableResult
    static func rename(_ theme: TerminalTheme, to newName: String) -> Bool {
        guard ThemeManager.shared.renameTheme(theme, to: newName) else { return false }

        // The default is an embedded copy, so it carries the old name until it is re-saved.
        if defaultTheme.id == theme.id,
           let renamed = ThemeManager.shared.theme(withID: theme.id) {
            ProfileStorage.shared.setTheme(renamed)
        }

        notifyChanged()
        return true
    }

    /// Stores a *new* theme, refusing to replace one that already exists.
    ///
    /// `ThemeManager.addTheme` replaces silently by ID, which is what an editor wants when
    /// saving an edit and exactly what a creator must not do. Creation checks both the durable
    /// identity and the human label so an agent cannot accidentally overwrite or ambiguously
    /// shadow an existing theme.
    static func create(_ theme: TerminalTheme) -> Bool {
        guard !ThemeManager.shared.isReserved(theme.name),
              theme.id != .followsAppTheme,
              ThemeManager.shared.theme(withID: theme.id) == nil,
              ThemeManager.shared.theme(named: theme.name) == nil else { return false }
        return ThemeManager.shared.addTheme(theme)
    }

    static func displayName(for id: TerminalThemeID) -> String {
        selectableTheme(withID: id)?.name ?? id.rawValue
    }

    private static func canonicalID(_ stored: TerminalThemeID?) -> TerminalThemeID? {
        stored.flatMap { ThemeManager.shared.canonicalID(for: $0) }
    }

    // MARK: - Notification

    private static func notifyChanged() {
        NotificationCenter.default.post(ThemeAssignmentsDidChange())
    }
}
