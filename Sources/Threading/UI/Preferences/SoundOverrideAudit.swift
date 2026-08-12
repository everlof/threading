import Foundation

// MARK: - Custom Sounds Audit

/// Every record carrying a sound of its own.
///
/// A per-chat sound someone set two weeks ago and forgot is a mystery noise, and the answer this
/// design owes is a list: built from the store on every reading rather than from a cache, so it
/// cannot drift from the records it is describing. A scope that has been reset is gone from the
/// next reading because the record no longer carries the field, not because anything was
/// invalidated.
///
/// It lives beside the settings page rather than beside `SoundScope`, because everything it
/// produces is **copy**: names, a caption, a summary sentence. `SoundScope` is storage and knows
/// nothing about how a choice is spelled; putting the wording next to it would have a lower
/// layer reaching up for the vocabulary a menu invented.
enum SoundOverrideAudit {

    /// One overriding scope, named and summarised.
    struct Entry: Equatable, Sendable {
        let scope: SoundScope
        /// What the scope is called — a project's name, a chat's title, a terminal's.
        let name: String
        /// Which kind of scope it is, and where it lives.
        let detail: String
        /// What its stored say amounts to: a sound, or a count of exceptions.
        let summary: String
    }

    /// The overriding scopes, in the sidebar's own order: each project, then its chats, then its
    /// terminals.
    ///
    /// A scan of the in-memory store, the same shape `ProjectStore.archivedSessions()` already
    /// has. It is bounded by what has been *configured* rather than by what exists — the common
    /// answer is empty — and the section that draws it caps how many rows it will build.
    @MainActor
    static func entries(in store: ProjectStore = .shared) -> [Entry] {
        var result: [Entry] = []
        for project in store.projects {
            if let summary = summary(of: project.soundOverrides) {
                result.append(Entry(
                    scope: .project(project.id),
                    name: project.name,
                    detail: L10n.string("Project"),
                    summary: summary
                ))
            }
            for session in project.sessions {
                guard let summary = summary(of: session.soundOverrides) else { continue }
                result.append(Entry(
                    scope: .session(session.id),
                    name: session.displayTitle,
                    detail: L10n.format("Chat in %@", project.name),
                    summary: summary
                ))
            }
            for terminal in project.terminals {
                guard let summary = summary(of: terminal.soundOverrides) else { continue }
                result.append(Entry(
                    scope: .terminal(terminal.id),
                    name: terminal.displayTitle,
                    detail: L10n.format("Terminal in %@", project.name),
                    summary: summary
                ))
            }
        }
        return result
    }

    /// What one record's stored say amounts to, in the fewest words that stay true — or nil when
    /// it says nothing at all.
    ///
    /// The base coat names itself, because that is the one-click tier's whole answer and the
    /// word people will recognise. Kind entries name their kind, since "Submarine" alone would
    /// be a lie about the half of the app it does not cover. Event entries are counted rather
    /// than listed: nine names do not fit on a row, and the row is a door to the sheet that
    /// shows them.
    @MainActor
    static func summary(of overrides: [String: String]?) -> String? {
        guard let overrides, !overrides.isEmpty else { return nil }

        var parts: [String] = []
        if let all = SoundChoice(storedValue: overrides[SoundOverrideKeys.all]) {
            parts.append(SoundMenuNames.displayName(of: all))
        } else {
            for kind in SoundEvent.Kind.allCases {
                guard let choice = SoundChoice(
                    storedValue: overrides[SoundOverrideKeys.key(for: kind)]
                ) else { continue }
                parts.append(L10n.format(
                    "%@: %@",
                    SoundMenuNames.displayName(of: kind),
                    SoundMenuNames.displayName(of: choice)
                ))
            }
        }

        let events = overrides.keys.reduce(into: 0) { count, key in
            if SoundEvent(rawValue: key) != nil { count += 1 }
        }
        if events > 0 {
            parts.append(events == 1
                ? L10n.format("%lld event", events)
                : L10n.format("%lld events", events))
        }

        // A map holding only keys this build has never heard of still counts as an override —
        // the record says *something*, and dropping it from the list would make the one surface
        // that answers "what is overriding" quietly incomplete.
        return parts.isEmpty ? L10n.string("Set by a later version") : parts.joined(separator: " · ")
    }

    /// One line for a sidebar row's existing tooltip, naming a sound the row does not inherit.
    ///
    /// Nil — the common case — leaves the tooltip exactly the tooltip it was. An override is
    /// configuration rather than status, so a row acquires no decoration for carrying one; what
    /// it acquires is an answer for whoever rests the pointer on it asking where the noise came
    /// from.
    @MainActor
    static func toolTipLine(for scope: SoundScope, overrides: [String: String]?) -> String? {
        guard let summary = summary(of: overrides) else { return nil }
        switch scope {
        case .session:
            return L10n.format("Sounds: %@ (this chat)", summary)
        case .project:
            return L10n.format("Sounds: %@ (this project)", summary)
        case .terminal:
            return L10n.format("Sounds: %@ (this terminal)", summary)
        case .app:
            return nil
        }
    }
}

// MARK: - Custom Sounds Defaults

enum SoundAuditDefaults {
    /// How many rows the Custom sounds section will build.
    ///
    /// Overrides are opt-in and chosen one at a time, so the honest expectation is nought to a
    /// dozen — but the count comes from the store rather than from a schema, which is what the
    /// Scaling Gate calls unbounded. The cap is applied **before** any row is constructed, and
    /// the tail is reported as a count with *Reset All* still covering it, so nothing configured
    /// becomes unreachable by being past the twelfth.
    static let visibleLimit = 12
}
