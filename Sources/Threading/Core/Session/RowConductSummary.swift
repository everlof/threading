import Foundation

// MARK: - Row Conduct Summary

/// Whether a sidebar row behaves differently from the rows around it, and in what way.
///
/// **Conduct, not presentation, and the line is deliberate.** A theme and a sound announce
/// themselves the moment they act — you can see the one and hear the other — so marking a row for
/// carrying them would light up most of the sidebar and tell the reader nothing they were not
/// about to find out. The two settings here act *while nobody is watching*: a muted chat says
/// nothing when it finishes, and an armed one types into itself hours later. Their surprise is
/// always the same question — "why did that happen?", or "why didn't it?" — and a row that is
/// going to answer differently should say so at rest.
///
/// Absence is the common case and costs nothing: a row with nothing of its own summarises to nil
/// and materialises no mark. See `SessionRowView.setConductMark`.
///
/// The chain is pure so the rule can be asserted without a store; the `@MainActor` conveniences
/// underneath are the only part that knows where records live.
struct RowConductSummary: Equatable, Sendable {

    // MARK: - Properties

    /// What this row does differently, in the order it should be read: the louder consequence
    /// first. Never empty — a summary with nothing to say is nil rather than blank.
    let statements: [String]

    /// The whole thing as one line, for a hover card or an accessibility label. The same
    /// separator the readings and chips use, so a row's facts read as one series.
    var sentence: String { statements.joined(separator: RowConductDefaults.separator) }

    // MARK: - The Rule

    /// A conversation's own answers, against what it would otherwise have inherited.
    ///
    /// Compared against the inherited value rather than tested for non-nil, because the two are
    /// not the same fact. A record can hold a value that matches what it would have inherited —
    /// an older writer, or a setting toggled twice at a scope whose base is the same — and a mark
    /// for that would be a row claiming to be different while behaving identically.
    static func session(
        muted: Bool?,
        inheritedMuted: Bool,
        limitRecovery: LimitRecoveryPolicy?,
        inheritedLimitRecovery: LimitRecoveryPolicy
    ) -> RowConductSummary? {
        var statements: [String] = []

        if let limitRecovery, limitRecovery != inheritedLimitRecovery {
            statements.append(RowConductStrings.limitRecovery(limitRecovery))
        }
        if let muted, muted != inheritedMuted {
            statements.append(RowConductStrings.mute(muted))
        }

        return statements.isEmpty ? nil : RowConductSummary(statements: statements)
    }

    /// A checkout's own answers. Its inherited mute is "not muted" — the base every project
    /// starts from — while its inherited recovery is whatever Settings says.
    static func project(
        muted: Bool?,
        limitRecovery: LimitRecoveryPolicy?,
        inheritedLimitRecovery: LimitRecoveryPolicy
    ) -> RowConductSummary? {
        session(
            muted: muted,
            inheritedMuted: false,
            limitRecovery: limitRecovery,
            inheritedLimitRecovery: inheritedLimitRecovery
        )
    }

    // MARK: - Reading The Records

    /// Summarises a record the caller already holds.
    ///
    /// The form a sidebar row uses, and the reason it takes the record rather than an id: a row
    /// is configured on the viewport path, once per visible row, and it was handed its session a
    /// line earlier. This resolves both settings from **one** project lookup — asking the store
    /// three times for facts already in hand is how an O(visible) path acquires a constant nobody
    /// notices until the list is long.
    ///
    /// The store is a parameter for `LimitRecoveryResolution`'s reason: a sidebar answers about
    /// the records it was handed, and reaching for the singleton from a row both answers the
    /// wrong question and, in a test, wakes the real database underneath the controller.
    @MainActor
    static func forSession(
        _ session: AgentSession,
        in store: ProjectStore = .shared
    ) -> RowConductSummary? {
        let project = store.project(forSessionID: session.id)
        return self.session(
            muted: session.notificationsMuted,
            inheritedMuted: project?.notificationsMuted ?? false,
            limitRecovery: session.limitRecoveryPolicy,
            inheritedLimitRecovery: LimitRecoveryResolution.resolve(
                session: nil,
                project: project?.limitRecoveryPolicy,
                app: LimitRecoverySettings.policy
            ).policy
        )
    }

    /// The same by identifier, for surfaces that hold one — the hover card builds itself from a
    /// session id after the row has gone.
    @MainActor
    static func forSession(
        _ sessionID: SessionID,
        in store: ProjectStore = .shared
    ) -> RowConductSummary? {
        guard let session = store.session(withID: sessionID) else { return nil }
        return forSession(session, in: store)
    }

    /// Takes the record rather than an id, so a row summarises the checkout it was handed.
    @MainActor
    static func forProject(_ project: Project) -> RowConductSummary? {
        self.project(
            muted: project.notificationsMuted,
            limitRecovery: project.limitRecoveryPolicy,
            inheritedLimitRecovery: LimitRecoveryResolution.inherited(beyondProjectID: project.id)
        )
    }
}

// MARK: - Strings

/// What a differing row says about itself.
///
/// Each statement names the *behaviour*, not the setting: "Continues at reset" rather than
/// "Limit recovery on". A reader glancing at a hover card wants to know what will happen, and the
/// setting's name is only useful to somebody already looking for it.
enum RowConductStrings {

    static func limitRecovery(_ policy: LimitRecoveryPolicy) -> String {
        switch policy {
        case .waitForReset:
            return L10n.string("Continues at reset")
        case .flagOnly:
            return L10n.string("Stops at its limit")
        }
    }

    static func mute(_ muted: Bool) -> String {
        muted ? L10n.string("Notifications muted") : L10n.string("Notifications on")
    }

    /// The mark's own label, which names the category rather than reading the statements aloud:
    /// the hover card is where the detail lives, and a row already states its name and status.
    static var markLabel: String { L10n.string("Has its own settings") }
}

// MARK: - Defaults

enum RowConductDefaults {

    /// The Session Options fold's own mark, so the icon and the menu that sets it read as one
    /// thing rather than as two unrelated pieces of vocabulary.
    static let symbol = "slider.horizontal.3"

    static let sessionIdentifier = "sidebar.session.conduct"
    static let projectIdentifier = "sidebar.project.conduct"

    /// Not localized: it is punctuation between clauses, and the surrounding surfaces already
    /// join their readings with it.
    static let separator = " · "
}
