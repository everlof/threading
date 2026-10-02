import Foundation
import SwiftUI
import ThreadingRemoteKit

// MARK: - Session Draft Identity Source

/// Where a draft's runtime and login came from.
///
/// Only a login the project's list chose is ever decided again: by moving the draft to another
/// project here, and by the Mac at the send (`RemoteAccountSelection.projectDefault`). A login the
/// person picked is theirs, and the app-wide rule is today's behaviour, which the Mac never
/// second-guesses either.
enum SessionDraftIdentitySource: Equatable {
    /// The person picked the runtime or the login in this draft.
    case explicit
    /// The project's ordered list chose it.
    case projectDefault
    /// The app-wide rule: the standard login, else the first one.
    case appRule
}

/// A draft's *who*, and the project whose list (or lack of one) last decided it.
struct SessionDraftIdentity: Equatable {
    var agentID: String
    var accountID: String
    var source: SessionDraftIdentitySource
    /// The project this identity was resolved for. Nil until the draft has a project.
    var projectID: String?
}

/// When a draft's identity is decided, and when it is left alone.
///
/// The identity is decided once per project: when the draft first has one, and again when the
/// person moves the draft to another — but never while the draft stays put, because a chip that
/// changes under someone who is typing breaks the rule that usage readings do not silently switch
/// an unfinished draft. The Mac decides again at the send, which is the moment it matters.
enum SessionDraftIdentityResolution {
    /// The identity the draft should hold for `projectID`.
    ///
    /// - Parameters:
    ///   - current: what the draft holds now.
    ///   - projectID: the draft's project.
    ///   - pick: the project list's predicted login, or nil when the project has no list, the
    ///     Mac does not keep lists, or nothing listed is in the catalogue. Evaluated only when
    ///     the identity is actually being decided, so a catalogue refresh that leaves the draft
    ///     settled costs no prediction.
    ///   - appRuleAgentID: the runtime the app-wide rule starts a draft on.
    ///   - isCurrentOffered: whether the catalogue still offers `current`'s runtime and login.
    static func resolve(
        current: SessionDraftIdentity,
        projectID: String,
        pick: @autoclosure () -> RemoteAccountReferenceDTO?,
        appRuleAgentID: String,
        isCurrentOffered: Bool
    ) -> SessionDraftIdentity {
        guard current.source != .explicit, !projectID.isEmpty else { return current }
        // Settled for this project. A list's pick that the Mac has since withdrawn is the one
        // exception: keeping it would submit a login the catalogue no longer offers.
        if current.projectID == projectID,
           current.source == .appRule || isCurrentOffered {
            return current
        }
        if let pick = pick() {
            return SessionDraftIdentity(
                agentID: pick.agentID,
                accountID: pick.accountID,
                source: .projectDefault,
                projectID: projectID
            )
        }
        if current.source == .projectDefault {
            // The last project's list chose this, and this project has none: today's rule. An
            // empty login lets the draft's own default step choose it for the runtime.
            return SessionDraftIdentity(
                agentID: appRuleAgentID,
                accountID: "",
                source: .appRule,
                projectID: projectID
            )
        }
        var settled = current
        settled.projectID = projectID
        return settled
    }
}

// MARK: - Mobile Project Default Accounts

/// The phone's prediction of which listed login a new chat in a project starts on.
///
/// The Mac decides (`ProjectAccountOrder` there); the phone only predicts, for the draft it shows
/// before Send. It uses the same line and the same order, so the prediction is the Mac's answer
/// whenever the two see the same readings. They can differ: the phone does not see the owner's
/// own limits, and its readings are the capacity feed's — which is why a send carries
/// `RemoteAccountSelection.projectDefault` and lets the Mac move it.
///
/// **The person's order outranks how much is known about each login.** A login is skipped only
/// on evidence that it is out: an unexpired window metering the model at or over the line. A
/// login with no reading is pickable, and is shown as "Usage unknown", never as room.
enum MobileProjectDefaultAccounts {

    // MARK: - Types

    /// One listed login as the phone can see it now.
    enum State: Equatable {
        /// Every window metering the model has a live reading below the line.
        case usable
        /// Present, with nothing that proves it out: no reading, a window whose reset has passed,
        /// or a window with no number.
        case unverified
        /// A live window metering the model is at or over the line. `until` is when the last of
        /// those windows resets, nil when any of them does not say.
        case spent(until: Date?)
        /// The catalogue does not offer this login: it was removed, renamed or switched off on
        /// the Mac, or its runtime is gone.
        case unavailable

        /// Whether the order may stop here.
        var isPickable: Bool {
            switch self {
            case .usable, .unverified: return true
            case .spent, .unavailable: return false
            }
        }
    }

    /// One listed login and its state, in list order.
    struct Entry: Equatable {
        let reference: RemoteAccountReferenceDTO
        let state: State
    }

    /// The answer for one draft.
    struct Prediction: Equatable {
        /// Every listed login, in list order.
        let entries: [Entry]
        /// The login to start on; nil when nothing listed is in the catalogue.
        let chosen: RemoteAccountReferenceDTO?

        /// Every available listed login is out, so the choice is the one that comes back first.
        var isEverythingSpent: Bool {
            guard let chosen,
                  case .spent = entries.first(where: { $0.reference == chosen })?.state else {
                return false
            }
            return true
        }
    }

    // MARK: - Public Methods

    /// Whether the paired Mac keeps per-project lists. The editor, the draft's prediction and the
    /// create request's `accountSelection` all wait for it, so an older Mac is never sent a word it
    /// would ignore.
    static func isOffered(features: [String]?) -> Bool {
        features?.contains(RemoteRESTFeature.projectDefaultAccounts.rawValue) == true
    }

    /// What the create request says about where its login came from: `projectDefault` only for a
    /// list's pick on a Mac that keeps lists, and nothing otherwise — absent means explicit, which
    /// is what every request meant before the field existed.
    static func accountSelection(
        source: SessionDraftIdentitySource,
        features: [String]?
    ) -> RemoteAccountSelection? {
        guard source == .projectDefault, isOffered(features: features) else { return nil }
        return .projectDefault
    }

    /// What one listed login looks like for a chat on `model`. A nil `model` is the login's own
    /// default, as the usage disc reads it.
    static func state(
        of account: RemoteAccountChoiceDTO?,
        model: String?,
        now: Date = Date()
    ) -> State {
        guard let account else { return .unavailable }
        guard let windows = account.usageWindows else {
            // A host predating per-window usage sends only the binding fraction, with no reset.
            if let fraction = account.usageFraction,
               fraction >= RemoteProjectDefaultAccounts.spentFraction {
                return .spent(until: nil)
            }
            return .unverified
        }

        let metered = model ?? account.defaultModelID
        let metering = windows.filter { window in
            guard let meters = window.metersModelIDs else { return true }
            guard let metered else { return false }
            return meters.contains(metered)
        }

        var spentUntil: [Date?] = []
        for window in metering where isLive(window, now: now) {
            guard let fraction = window.fraction,
                  fraction >= RemoteProjectDefaultAccounts.spentFraction else { continue }
            spentUntil.append(window.resetsAt.map(Date.init(timeIntervalSince1970:)))
        }
        if !spentUntil.isEmpty { return .spent(until: latest(spentUntil)) }

        guard account.usageError == nil,
              !metering.isEmpty,
              metering.allSatisfy({ isLive($0, now: now) && $0.fraction != nil }) else {
            return .unverified
        }
        return .usable
    }

    /// The first pickable listed login; when every available one is out, the one that comes back
    /// soonest, ties going to the list; nil when nothing listed is in the catalogue.
    ///
    /// - Parameters:
    ///   - list: the project's logins, in the owner's order.
    ///   - agents: the catalogue's runtimes, with the freshest readings already laid over them.
    ///   - model: the model a chat on that login would run if the draft pinned none — what it
    ///     last started on here, else its default — which decides the scoped windows metering it.
    static func predict(
        list: [RemoteAccountReferenceDTO],
        agents: [RemoteAgentChoiceDTO],
        model: (RemoteAgentChoiceDTO, RemoteAccountChoiceDTO) -> String? = { agent, account in
            account.defaultModelID ?? agent.defaultModelID
        },
        now: Date = Date()
    ) -> Prediction {
        let entries = list.map { reference -> Entry in
            guard let agent = agents.first(where: { $0.id == reference.agentID }),
                  let account = agent.accounts?.first(where: { $0.id == reference.accountID }) else {
                return Entry(reference: reference, state: .unavailable)
            }
            return Entry(
                reference: reference,
                state: state(of: account, model: model(agent, account), now: now)
            )
        }

        if let first = entries.first(where: { $0.state.isPickable }) {
            return Prediction(entries: entries, chosen: first.reference)
        }

        var soonest: (reference: RemoteAccountReferenceDTO, until: Date)?
        for entry in entries {
            guard case .spent(let until) = entry.state else { continue }
            let comesBack = until ?? .distantFuture
            if let standing = soonest, standing.until <= comesBack { continue }
            soonest = (entry.reference, comesBack)
        }
        return Prediction(entries: entries, chosen: soonest?.reference)
    }

    /// The list's pick restricted to one runtime: the login a hand-picked runtime starts on, when
    /// the project lists any of that runtime's.
    static func predict(
        list: [RemoteAccountReferenceDTO],
        runtime agentID: String,
        agents: [RemoteAgentChoiceDTO],
        model: (RemoteAgentChoiceDTO, RemoteAccountChoiceDTO) -> String? = { agent, account in
            account.defaultModelID ?? agent.defaultModelID
        },
        now: Date = Date()
    ) -> RemoteAccountReferenceDTO? {
        predict(
            list: list.filter { $0.agentID == agentID },
            agents: agents,
            model: model,
            now: now
        ).chosen
    }

    // MARK: - Presentation

    /// The one-line state under a listed login's name in the editor.
    ///
    /// A login with a reading shows the reading rather than a verdict: the phone cannot tell a
    /// fresh reading from a stale one, and only a fresh one proves room.
    static func stateLine(
        _ state: State,
        account: RemoteAccountChoiceDTO?,
        reading: MobileAccountUsageReading?,
        now: Date = Date()
    ) -> String {
        switch state {
        case .unavailable:
            return MobileL10n.string("Unavailable login")
        case .spent(let until):
            guard let until else { return MobileL10n.string("Out of usage") }
            return MobileL10n.string("Out until %@", resetTime(until, now: now))
        case .usable:
            return reading?.summary ?? account?.usageSummary ?? MobileL10n.string("Usage unknown")
        case .unverified:
            return MobileL10n.string("Usage unknown")
        }
    }

    /// When a window comes back, as briefly as is unambiguous: the time today, else the weekday.
    static func resetTime(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if date.timeIntervalSince(now) < 6 * 24 * 60 * 60 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The receipt a send leaves when the Mac started it on another listed login than the draft
    /// named. Account names come from the catalogue; a login it no longer lists keeps its handle.
    static func receipt(
        for substitution: RemoteAccountSubstitutionDTO,
        agentID: String,
        agents: [RemoteAgentChoiceDTO],
        now: Date = Date()
    ) -> String {
        let accounts = agents.first { $0.id == agentID }?.accounts ?? []
        func name(_ accountID: String) -> String {
            accounts.first { $0.id == accountID }?.visibleName ?? accountID
        }
        let started = name(substitution.accountID)
        let requested = name(substitution.requestedAccountID)
        let resetsAt = substitution.resetsAt.map(Date.init(timeIntervalSince1970:))
        switch (substitution.reason, resetsAt) {
        case (.spent, let until?):
            return MobileL10n.string(
                "Started on %@ — %@ is out until %@", started, requested, resetTime(until, now: now)
            )
        case (.spent, nil):
            return MobileL10n.string("Started on %@ — %@ is out of usage", started, requested)
        case (.ownLimit, let until?):
            return MobileL10n.string(
                "Started on %@ — %@ is at your limit until %@",
                started,
                requested,
                resetTime(until, now: now)
            )
        case (.ownLimit, nil):
            return MobileL10n.string("Started on %@ — %@ reached your limit", started, requested)
        case (.unknown, _):
            return MobileL10n.string("Started on %@ instead of %@", started, requested)
        }
    }

    // MARK: - Private Methods

    /// The Mac's own rule: past its reset, a window's fraction describes the window before it.
    private static func isLive(_ window: RemoteAccountUsageWindowDTO, now: Date) -> Bool {
        guard let resetsAt = window.resetsAt else { return true }
        return resetsAt > now.timeIntervalSince1970
    }

    /// When a login whose spent windows each reset at their own time comes back: the latest of
    /// them, or unknown when any one does not say.
    private static func latest(_ dates: [Date?]) -> Date? {
        var latest: Date?
        for date in dates {
            guard let date else { return nil }
            latest = max(latest ?? date, date)
        }
        return latest
    }
}

// MARK: - Mobile Account Substitution Notice

/// A send the Mac moved to another listed login, as the opened chat's receipt holds it.
struct MobileAccountSubstitutionNotice: Equatable {
    /// Long enough to read twice, short enough not to become chrome.
    static let displayDuration: TimeInterval = 12

    let substitution: RemoteAccountSubstitutionDTO
    /// When the chat first showed it. A screen rebuilt after `expiresAt` does not show it again.
    let shownAt: Date

    var expiresAt: Date { shownAt.addingTimeInterval(Self.displayDuration) }
}

// MARK: - Mobile Project Default Accounts Editor

/// The editor page's working copy of one project's list: what the person has reordered, removed
/// and added since the page opened, and the request that saves it. Saving sends the whole list.
struct MobileProjectDefaultAccountsEditor: Equatable {
    /// The list as the page found it, normalized the way the Mac stores it.
    let original: [RemoteAccountReferenceDTO]
    private(set) var entries: [RemoteAccountReferenceDTO]

    init(list: [RemoteAccountReferenceDTO]?) {
        let normalized = Self.normalized(list ?? [])
        original = normalized
        entries = normalized
    }

    var hasChanges: Bool { entries != original }

    /// The list holds as many logins as discovery admits, and no more.
    var canAdd: Bool { entries.count < RemoteProjectDefaultAccounts.maximumEntries }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    mutating func remove(atOffsets offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
    }

    mutating func add(_ reference: RemoteAccountReferenceDTO) {
        guard canAdd, !entries.contains(reference) else { return }
        entries.append(reference)
    }

    /// The catalogue's logins the list does not name, in the catalogue's order: every runtime
    /// that routes logins, each login once.
    func available(in agents: [RemoteAgentChoiceDTO]) -> [RemoteAccountReferenceDTO] {
        let listed = Set(entries)
        return agents.flatMap { agent in
            (agent.accounts ?? []).map {
                RemoteAccountReferenceDTO(agentID: agent.id, accountID: $0.id)
            }
        }.filter { !listed.contains($0) }
    }

    func request(projectID: String) -> RemoteSetProjectDefaultAccountsRequestDTO {
        RemoteSetProjectDefaultAccountsRequestDTO(projectID: projectID, accounts: entries)
    }

    /// De-duplicated in order and capped, as the Mac stores it.
    private static func normalized(
        _ list: [RemoteAccountReferenceDTO]
    ) -> [RemoteAccountReferenceDTO] {
        var seen = Set<RemoteAccountReferenceDTO>()
        var result: [RemoteAccountReferenceDTO] = []
        for reference in list where seen.insert(reference).inserted {
            result.append(reference)
            if result.count == RemoteProjectDefaultAccounts.maximumEntries { break }
        }
        return result
    }
}
