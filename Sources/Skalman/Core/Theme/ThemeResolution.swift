import Foundation

// MARK: - Theme Scope

/// Where a theme assignment lives.
///
/// The three are a *chain*, not three independent settings: a session follows its project,
/// and a project follows the app. See `ThemeResolution.resolve`.
enum ThemeScope: String, Codable, CaseIterable {
    case session
    case project
    case global

    var displayName: String {
        switch self {
        case .session: return "Session"
        case .project: return "Project"
        case .global: return "Default"
        }
    }
}

// MARK: - Theme Resolution

/// Which theme a terminal draws with, and which scope decided it.
///
/// Pure on purpose, and separate from every store that feeds it: the two rules below are
/// invisible in a screenshot and were reachable only by standing up AppKit and three
/// singletons, which is how they would have gone untested.
enum ThemeResolution {

    /// A resolved theme: its name, and the scope that supplied it.
    struct Assignment: Equatable {
        let scope: ThemeScope
        let themeName: String
    }

    /// Resolves narrowest-first, skipping names that answer to no theme.
    ///
    /// - **Absent means inherit, not copy.** A session with no name of its own follows its
    ///   project, and a project with none follows the global default — so changing the default
    ///   still moves everything that never opted out. Recording the current theme at creation
    ///   would have frozen every session against the one setting most likely to change.
    /// - **A dangling name is not an error.** Themes are identified by name, so a delete leaves
    ///   references behind. A name nothing answers to degrades to inheriting from the next
    ///   scope out, which is indistinguishable from never having chosen — the alternative is a
    ///   terminal that draws nothing, or one that pins a colour scheme the user cannot see in
    ///   any list. (A *rename* re-points its references instead; see `ThemeAssignments.rename`.)
    ///
    /// Returns nil when no scope names a theme that exists, which the caller answers with the
    /// profile's own embedded theme.
    static func resolve(
        session: String?,
        project: String?,
        global: String?,
        available: Set<String>
    ) -> Assignment? {
        let chain: [(ThemeScope, String?)] = [
            (.session, session),
            (.project, project),
            (.global, global)
        ]

        for (scope, name) in chain {
            guard let name, available.contains(name) else { continue }
            return Assignment(scope: scope, themeName: name)
        }

        return nil
    }
}
