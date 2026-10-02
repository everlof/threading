import Foundation

/// The numbers behind a project's ordered logins.
enum ProjectAccountDefaults {

    /// Where a listed login counts as out of usage, as a share of its effective bound.
    ///
    /// The same point at which the toolbar turns critical, rather than the provider's 100%:
    /// starting a chat on a login at 97% buys one turn, and the chat then has to be moved.
    static let spentFraction = UsageDefaults.criticalFraction

    /// A list may name at most as many logins as discovery admits.
    static let maximumEntries = 32
}

/// Chooses which of a project's listed logins a new chat starts on: the first one that is not
/// out of usage.
///
/// Pure, so the rule can be read and tested without a home directory, a usage service or a
/// store. `ProjectDefaultAccounts` gathers the live inputs.
///
/// **The user's order outranks how much is known about each login.** A login is skipped only on
/// positive evidence that it is out, which is deliberately the opposite of `LimitEscapeRanking`:
///
/// - **A stale reading can prove exhaustion, never headroom.** Usage only grows inside a window,
///   so an old 95% is still at least 95%, while an old 40% may be anything now. Stale-and-high
///   is therefore `spent`, and stale-and-low is `unverified`.
/// - **Unknown is pickable, but never shown as room.** A new chat moves no transcript and is on
///   screen before it is sent; if the provider does refuse it, the project's limit recovery takes
///   over. Skipping the user's first choice because nothing had fetched its reading yet would be
///   the commoner failure, since nothing polls a login that is not on screen.
///
/// The move of a conversation that already exists stays fail-closed, in `LimitEscapeRanking`.
enum ProjectAccountOrder {

    // MARK: - Types

    /// Whether a listed login is there to be chosen at all.
    enum Presence: Equatable, Sendable {
        case enabled
        /// Switched off in Settings ▸ Accounts: withdrawn from new work.
        case disabled
        /// No longer discovered — its folder was removed or renamed.
        case missing
    }

    /// Why a listed login counts as out.
    enum SpentCause: Equatable, Sendable {
        /// The provider's own window is at the line.
        case provider
        /// A line the user drew is, while the provider's window still has room.
        case ownLimit
    }

    /// What one listed login looks like right now.
    enum State: Equatable, Sendable {
        /// A current reading shows room on every window that meters the model.
        case usable
        /// Present and enabled, with nothing that proves it out: no reading, a failed or stale
        /// one below the line, a window whose reset has passed, or a hold that cannot see.
        case unverified
        /// Proven out. `until` is when the last of its spent windows resets, when known.
        case spent(until: Date?, cause: SpentCause)
        /// Not a login a new chat can start on.
        case unavailable(Presence)

        /// Whether the order may stop here.
        var isPickable: Bool {
            switch self {
            case .usable, .unverified: true
            case .spent, .unavailable: false
            }
        }
    }

    /// One listed login and the facts its state is decided from.
    struct Candidate: Equatable {
        let accountID: AccountID
        let presence: Presence
        let reading: AccountUsageReading
        /// The rules in force on this login (`CustomLimitSettings.rules(for:)`).
        let limits: [CustomLimit]
        /// The model a chat started on this login would run on, which decides which scoped
        /// windows meter it.
        let model: String?

        init(
            accountID: AccountID,
            presence: Presence,
            reading: AccountUsageReading,
            limits: [CustomLimit] = [],
            model: String? = nil
        ) {
            self.accountID = accountID
            self.presence = presence
            self.reading = reading
            self.limits = limits
            self.model = model
        }
    }

    /// A listed login with its state, in list order.
    struct Entry: Equatable {
        let accountID: AccountID
        let state: State
    }

    /// The answer for one draft.
    struct Resolution: Equatable {
        /// Every candidate considered, in list order.
        let entries: [Entry]
        /// The login to start on, or nil when nothing listed is available at all.
        let chosen: AccountID?

        /// The chosen login's state.
        var chosenState: State? {
            guard let chosen else { return nil }
            return entries.first { $0.accountID == chosen }?.state
        }

        /// True when every available listed login is out, so the choice is the one that comes
        /// back soonest rather than one that has room.
        var isEverythingSpent: Bool {
            guard case .spent = chosenState else { return false }
            return true
        }

        /// The listed logins that were passed over to reach the chosen one, for the sentence that
        /// says why the first choice was not taken.
        var skipped: [Entry] {
            guard let chosen,
                  let index = entries.firstIndex(where: { $0.accountID == chosen }) else {
                return entries
            }
            return Array(entries[..<index])
        }
    }

    // MARK: - Public Methods

    /// The stored form of a list: de-duplicated in order, capped, and nil rather than empty.
    static func normalized(_ accounts: [AccountID]?) -> [AccountID]? {
        guard let accounts else { return nil }
        var seen = Set<AccountID>()
        var result: [AccountID] = []
        for account in accounts where seen.insert(account).inserted {
            result.append(account)
            if result.count == ProjectAccountDefaults.maximumEntries { break }
        }
        return result.isEmpty ? nil : result
    }

    /// The listed logins of one runtime, in list order — or all of them when `runtime` is nil.
    static func entries(_ list: [AccountID], for runtime: AgentKind?) -> [AccountID] {
        guard let runtime else { return list }
        return list.filter { $0.provider == runtime }
    }

    /// What one login looks like right now. See the type's notes for the asymmetry.
    static func state(of candidate: Candidate, at now: Date = Date()) -> State {
        guard candidate.accountID.provider.supportsAccounts else {
            return .unavailable(.missing)
        }
        guard candidate.presence == .enabled else {
            return .unavailable(candidate.presence)
        }

        let usage = candidate.reading.usage
        let hold = CustomLimitBounds.hold(on: usage, in: candidate.limits, at: now)

        var spentUntil: [Date?] = []
        var cause = SpentCause.provider
        let windows = usage?.windows(metering: candidate.model) ?? []
        for window in windows {
            guard !window.isExpired(at: now), let fraction = window.fraction else { continue }
            let bound = CustomLimitBounds.effectiveBound(
                on: window.id,
                in: candidate.limits,
                window: window,
                at: now
            )
            let consumed = CustomLimitBounds.consumedOfBound(fraction: fraction, bound: bound)
            guard consumed >= ProjectAccountDefaults.spentFraction else { continue }
            spentUntil.append(window.resetsAt)
            if fraction < ProjectAccountDefaults.spentFraction { cause = .ownLimit }
        }

        if case .overLine(let rule, _) = hold {
            let window = usage?.allWindows.first { $0.id == rule.windowID }
            spentUntil.append(window?.resetsAt)
            if spentUntil.count == 1 { cause = .ownLimit }
        }

        if !spentUntil.isEmpty {
            return .spent(until: latest(spentUntil), cause: cause)
        }

        guard case .current = candidate.reading,
              hold == .clear,
              !windows.isEmpty,
              windows.allSatisfy({ !$0.isExpired(at: now) && $0.fraction != nil }) else {
            return .unverified
        }
        return .usable
    }

    /// The first pickable login in list order; when every available one is out, the one that
    /// comes back soonest, ties going to the list; nil when nothing listed is available.
    static func resolve(_ candidates: [Candidate], at now: Date = Date()) -> Resolution {
        let entries = candidates.map { Entry(accountID: $0.accountID, state: state(of: $0, at: now)) }

        if let first = entries.first(where: { $0.state.isPickable }) {
            return Resolution(entries: entries, chosen: first.accountID)
        }

        var soonest: (accountID: AccountID, until: Date)?
        for entry in entries {
            guard case .spent(let until, _) = entry.state else { continue }
            let comesBack = until ?? .distantFuture
            if let standing = soonest, standing.until <= comesBack { continue }
            soonest = (entry.accountID, comesBack)
        }
        return Resolution(entries: entries, chosen: soonest?.accountID)
    }

    /// The login a send should move to instead of `current`, or nil to keep it.
    ///
    /// Only positive evidence moves a send: `current` must be `spent`, and the replacement must
    /// be pickable. The candidates are expected to be one runtime's, because a send that changed
    /// runtime would carry a model, an effort and a surface chosen for another agent.
    static func substitute(
        for current: Candidate,
        among candidates: [Candidate],
        at now: Date = Date()
    ) -> Entry? {
        guard case .spent = state(of: current, at: now) else { return nil }
        for candidate in candidates
        where candidate.accountID != current.accountID
            && candidate.accountID.provider == current.accountID.provider {
            let state = state(of: candidate, at: now)
            if state.isPickable { return Entry(accountID: candidate.accountID, state: state) }
        }
        return nil
    }

    // MARK: - Private Methods

    /// When a login whose spent windows each reset at their own time comes back: the latest of
    /// them, or unknown when any one of them does not say.
    private static func latest(_ dates: [Date?]) -> Date? {
        var latest: Date?
        for date in dates {
            guard let date else { return nil }
            latest = max(latest ?? date, date)
        }
        return latest
    }
}
