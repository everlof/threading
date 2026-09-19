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
    ///
    /// The two clock-driven statements — a curfew and a park by the user's own limit — enter as
    /// ready sentences rather than as records, so this stays the one place that decides *order*
    /// while remaining assertable with no store, no preferences suite and no account usage.
    static func session(
        muted: Bool?,
        inheritedMuted: Bool,
        limitRecovery: LimitRecoveryPolicy?,
        inheritedLimitRecovery: LimitRecoveryPolicy,
        curfew: RowCurfewStatement? = nil,
        parkedByOwnLimit: String? = nil
    ) -> RowConductSummary? {
        var statements: [String] = []

        // A hold leads, ahead even of a park: the curfew names *this row* while a park names the
        // account behind it, and the reader looking at one idle session wants the reason that
        // belongs to it first. See `RowCurfewStatement.leads`.
        if let curfew, curfew.leads {
            statements.append(curfew.text)
        }
        if let parkedByOwnLimit {
            statements.append(parkedByOwnLimit)
        }
        if let limitRecovery, limitRecovery != inheritedLimitRecovery {
            statements.append(RowConductStrings.limitRecovery(limitRecovery))
        }
        if let muted, muted != inheritedMuted {
            statements.append(RowConductStrings.mute(muted))
        }
        // A fence that has not closed yet, or an exemption from one, is the quietest thing here:
        // nothing has happened to this session, and nothing will until the named time.
        if let curfew, !curfew.leads {
            statements.append(curfew.text)
        }

        return statements.isEmpty ? nil : RowConductSummary(statements: statements)
    }

    /// A checkout's own answers. Its inherited mute is "not muted" — the base every project
    /// starts from — while its inherited recovery is whatever Settings says.
    static func project(
        muted: Bool?,
        limitRecovery: LimitRecoveryPolicy?,
        inheritedLimitRecovery: LimitRecoveryPolicy,
        curfew: RowCurfewStatement? = nil
    ) -> RowConductSummary? {
        session(
            muted: muted,
            inheritedMuted: false,
            limitRecovery: limitRecovery,
            inheritedLimitRecovery: inheritedLimitRecovery,
            curfew: curfew
        )
    }

    // MARK: - The Curfew Rule

    /// What one record's curfew is worth saying on its row, and where the sentence belongs.
    ///
    /// Pure, and separated from the resolution the way the rest of this file is separated from the
    /// store: whether a mark appears is the whole product decision here, and a rule that lit up
    /// every row would be worse than no rule at all.
    ///
    /// Four answers, in the order they are asked:
    ///
    /// - **Held** leads, whichever scope set the deadline. A held session looks idle and is not —
    ///   nothing is being sent to it — and that is the one curfew fact a reader is owed before
    ///   they go looking for a reason.
    /// - **Armed** speaks only for the record's *own* answer (`ownScope`). A standing quiet-hours
    ///   window that has not opened yet is inherited by every conversation on the machine, so
    ///   marking it would put the same sentence on every row and tell nobody anything.
    /// - **Exempt** speaks only where a window would otherwise have applied. "Exempt from quiet
    ///   hours" on a machine with no quiet hours names a rule nobody set.
    /// - Anything **matching what would have been inherited** says nothing, for the reason
    ///   `session(…)` compares rather than tests for non-nil.
    ///
    /// Compared by deadline rather than by whole value, because the two can never be equal: an
    /// inherited window carries `.quietHours` origin and a session's own answer carries
    /// `.session`. The deadline is the difference a reader would notice — the margins around it
    /// come from Settings either way.
    static func curfewStatement(
        hold: CurfewHold,
        answer: CurfewResolution.Answer,
        inherited: ResolvedCurfew?,
        ownScope: CurfewScope,
        now: Date,
        locale: Locale = .current
    ) -> RowCurfewStatement? {
        if case .held(_, let curfew, _) = hold {
            guard let text = CurfewReceiptWords.conductStatement(
                curfew: curfew,
                isExempt: false,
                now: now,
                locale: locale
            ) else { return nil }
            return RowCurfewStatement(text: text, leads: true)
        }

        guard answer.scope == ownScope else { return nil }

        if case .usageThreshold(let percent, _, _, let windowID)? = answer.condition {
            return RowCurfewStatement(
                text: CurfewReceiptWords.usageThreshold(percent: percent, windowID: windowID),
                leads: false
            )
        }

        guard let curfew = answer.curfew else {
            // The record exempted itself. `scope == ownScope` with no curfew is exactly that:
            // a checkout's exemption answers at `.project`, so a chat inheriting one is silent
            // here and the checkout's own row carries the sentence.
            guard inherited != nil else { return nil }
            guard let text = CurfewReceiptWords.conductStatement(
                curfew: nil,
                isExempt: true,
                now: now,
                locale: locale
            ) else { return nil }
            return RowCurfewStatement(text: text, leads: false)
        }

        guard curfew.deadline != inherited?.deadline else { return nil }
        guard let text = CurfewReceiptWords.conductStatement(
            curfew: curfew,
            isExempt: false,
            now: now,
            locale: locale
        ) else { return nil }
        return RowCurfewStatement(text: text, leads: false)
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
        in store: ProjectStore = .shared,
        now: Date = Date()
    ) -> RowConductSummary? {
        let project = store.project(forSessionID: session.id)
        let park = CustomLimitParkPolicy.hold(sessionID: session.id, at: now)

        return forSession(session, project: project, park: park, now: now)
    }

    /// The same rule with its already-resolved project and account hold. Whole-catalog
    /// projections use this form so one account's limit state is resolved once rather than once
    /// per session, while visible rows keep using the store convenience above.
    @MainActor
    static func forSession(
        _ session: AgentSession,
        project: Project?,
        park: CustomLimitHold,
        now: Date
    ) -> RowConductSummary? {
        // A park by one of the user's own limits belongs in this family and **not** on the
        // warning triangle. `ThemedWarningMark` means "the provider stopped this and you cannot
        // answer it"; a self-imposed line is conduct — the same kind of fact as a session that
        // mutes itself or recovers differently, which is what this mark already says. The
        // process really is idle and the provider really would accept a turn, so there is no new
        // `SessionActivity` case either.

        return self.session(
            muted: session.notificationsMuted,
            inheritedMuted: project?.notificationsMuted ?? false,
            limitRecovery: session.limitRecoveryPolicy,
            inheritedLimitRecovery: LimitRecoveryResolution.resolve(
                session: nil,
                project: project?.limitRecoveryPolicy,
                app: LimitRecoverySettings.policy
            ).policy,
            curfew: curfewStatement(for: session, project: project, now: now),
            parkedByOwnLimit: park.rule.map {
                RowConductStrings.parkedByOwnLimit(
                    CustomLimitReceipt.holdSummaryLine(park, rule: $0)
                )
            }
        )
    }

    /// The curfew half of a session row, resolved from the records the caller already holds.
    ///
    /// Both the answer and what it would have inherited are computed from `session.curfewRule` and
    /// `project?.curfewRule` rather than through `CurfewResolution.answer(forSessionID:)` and
    /// `inherited(beyondSessionID:)`, which is the same economy `forSession` already documents:
    /// those two conveniences would each go back to the store for a record this call is holding,
    /// turning one project lookup per visible row into four. The chain they run is the same one,
    /// entered a level lower.
    ///
    /// The hold likewise comes from `CurfewHoldPolicy`'s pure overload, so the row cannot disagree
    /// with the seam that refuses a send about whether this session is held.
    @MainActor
    private static func curfewStatement(
        for session: AgentSession,
        project: Project?,
        now: Date
    ) -> RowCurfewStatement? {
        let preferences = CurfewSettings.shared.preferences
        let answer = CurfewResolution.resolve(
            session: session.curfewRule,
            project: project?.curfewRule,
            preferences: preferences,
            state: session.curfewState,
            now: now
        )

        return curfewStatement(
            hold: CurfewHoldPolicy.hold(answer: answer, state: session.curfewState, at: now),
            answer: answer,
            inherited: CurfewResolution.inherited(
                beyond: .session,
                project: project?.curfewRule,
                preferences: preferences,
                now: now
            ),
            ownScope: .session,
            now: now
        )
    }

    /// The same by identifier, for surfaces that hold one — the hover card builds itself from a
    /// session id after the row has gone.
    @MainActor
    static func forSession(
        _ sessionID: SessionID,
        in store: ProjectStore = .shared,
        now: Date = Date()
    ) -> RowConductSummary? {
        guard let session = store.session(withID: sessionID) else { return nil }
        return forSession(session, in: store, now: now)
    }

    /// Takes the record rather than an id, so a row summarises the checkout it was handed.
    @MainActor
    static func forProject(_ project: Project, now: Date = Date()) -> RowConductSummary? {
        let preferences = CurfewSettings.shared.preferences

        return self.project(
            muted: project.notificationsMuted,
            limitRecovery: project.limitRecoveryPolicy,
            inheritedLimitRecovery: LimitRecoveryResolution.inherited(beyondProjectID: project.id),
            // A checkout is not a conversation, so nothing holds it: the hold is a fact about one
            // session's clock, and the chats inside carry it on their own rows. What a checkout
            // can say is that it exempted them — the only curfew answer `ProjectStore` lets it
            // store.
            curfew: curfewStatement(
                hold: .clear,
                answer: CurfewResolution.resolve(
                    session: nil,
                    project: project.curfewRule,
                    preferences: preferences,
                    state: nil,
                    now: now
                ),
                inherited: CurfewResolution.inherited(
                    beyond: .project,
                    project: nil,
                    preferences: preferences,
                    now: now
                ),
                ownScope: .project,
                now: now
            )
        )
    }
}

// MARK: - Curfew Statement

/// A row's curfew sentence and where it sits among the row's other conduct.
///
/// The two travel together rather than as a string and a separate flag, because they are one
/// decision: a hold is prepended and everything else appended, and a call site free to pair the
/// wrong half would put "Held by curfew since 04:00" last — after the two facts a reader only
/// needs once they know why nothing is being sent.
///
/// The words come from `CurfewReceiptWords`, so the row, the strip and a refusal cannot drift
/// into three descriptions of one fence.
struct RowCurfewStatement: Equatable, Sendable {

    let text: String

    /// Whether this statement leads the row. True only for a hold.
    let leads: Bool
}

// MARK: - Strings

/// What a differing row says about itself.
///
/// Each statement names the *behaviour*, not the setting: "Continues at reset" rather than
/// "Limit recovery on". A reader glancing at a hover card wants to know what will happen, and the
/// setting's name is only useful to somebody already looking for it.
enum RowConductStrings {

    /// What a parked row says it is doing. Named as *your* limit in the first two words, because
    /// the whole point of the mark is that this is not the provider.
    static func parkedByOwnLimit(_ line: String) -> String {
        L10n.format("Held at your limit · %@", line)
    }

    /// A pinned login is named by its **handle**, not by the person behind it, and that is a
    /// scaling decision rather than a wording one: `AccountName.display(for:)` needs an
    /// `AgentAccount`, which means `AgentAccountDiscovery` — a seven-second cache in front of a home
    /// directory scan — and this runs once per visible row on the configure path. The handle is
    /// already inside the stored identifier, costs nothing, and is the name the user gave the
    /// login's own directory. The surfaces that *do* hold an account list (the chat menu, the
    /// strip) name the person.
    static func limitRecovery(_ policy: LimitRecoveryPolicy) -> String {
        switch policy {
        case .waitForReset:
            return L10n.string("Continues at reset")
        case .flagOnly:
            return L10n.string("Stops at its limit")
        case .resumeOnBestAccount:
            return L10n.string("Moves to a login with room")
        case .resumeVia(let accountID):
            return L10n.format("Moves to %@", AccountPresentationLabels.name(for: accountID))
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
