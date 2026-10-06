import AppKit

// MARK: - Theme Scope

/// Where a theme assignment lives.
///
/// The three are a *chain*, not three independent settings: a session follows its project,
/// and a project follows the app. See `ThemeResolution.resolve`.
public enum ThemeScope: String, Codable, CaseIterable {
    case session
    case project
    case global

    public var displayName: String {
        switch self {
        case .session: return L10n.string("Session")
        case .project: return L10n.string("Project")
        case .global: return L10n.string("Default")
        }
    }
}

// MARK: - Theme Resolution

/// Which theme a terminal draws with, and which scope decided it.
///
/// Pure on purpose, and separate from every store that feeds it: the two rules below are
/// invisible in a screenshot and were reachable only by standing up AppKit and three
/// singletons, which is how they would have gone untested.
public enum ThemeResolution {

    /// A resolved theme: its durable ID, and the scope that supplied it.
    public struct Assignment: Equatable {
        public let scope: ThemeScope
        public let themeID: TerminalThemeID
    }

    /// Resolves narrowest-first, skipping IDs that answer to no theme.
    ///
    /// - **Absent means inherit, not copy.** A session with no ID of its own follows its
    ///   project, and a project with none follows the global default — so changing the default
    ///   still moves everything that never opted out. Recording the current theme at creation
    ///   would have frozen every session against the one setting most likely to change.
    /// - **A dangling ID is not an error.** Deleting a theme leaves references behind. An ID
    ///   nothing answers to degrades to inheriting from the next
    ///   scope out, which is indistinguishable from never having chosen — the alternative is a
    ///   terminal that draws nothing, or one that pins a colour scheme the user cannot see in
    ///   any list. A rename cannot create this state because the assignment keeps the same ID.
    ///
    /// Returns nil when no scope names a theme that exists, which the caller answers with the
    /// profile's own embedded theme.
    public static func resolve(
        session: TerminalThemeID?,
        project: TerminalThemeID?,
        global: TerminalThemeID?,
        available: Set<TerminalThemeID>
    ) -> Assignment? {
        let chain: [(ThemeScope, TerminalThemeID?)] = [
            (.session, session),
            (.project, project),
            (.global, global)
        ]

        for (scope, id) in chain {
            guard let id, available.contains(id) else { continue }
            return Assignment(scope: scope, themeID: id)
        }

        return nil
    }
}
