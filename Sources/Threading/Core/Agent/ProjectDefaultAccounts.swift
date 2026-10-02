import Foundation

/// The live side of `ProjectAccountOrder`: a project's list, the logins it names as they are
/// discovered now, their cached readings and the user's own lines.
///
/// Every input is an in-memory value — discovery is cached, readings are the usage service's
/// cache, and limits are preferences — so a resolution is O(listed logins) and safe to run when a
/// draft opens or is sent. The only work that leaves the process is `warmReadings`, through the
/// usage service's own pacing.
@MainActor
enum ProjectDefaultAccounts {

    // MARK: - Types

    /// A send that moved off the login its draft showed, and why.
    struct Substitution: Equatable {
        let from: AccountID
        let to: AccountID
        /// What the login moved off looked like at the send: always `spent`.
        let fromState: ProjectAccountOrder.State

        /// When the login moved off comes back, when known.
        var fromResetsAt: Date? {
            guard case .spent(let until, _) = fromState else { return nil }
            return until
        }

        /// Whether the line it was at was the user's own rather than the provider's.
        var wasOwnLimit: Bool {
            guard case .spent(_, .ownLimit) = fromState else { return false }
            return true
        }
    }

    /// The draft's run choices as they cross to another login of the same runtime: each one is
    /// kept where the new login offers it and dropped to that login's own default where it does
    /// not. Never refused — a send that had already been accepted does not fail on a substitute.
    struct CarriedRunChoice: Equatable {
        let model: String?
        let reasoningEffort: String?
        let fastMode: Bool?
    }

    // MARK: - Public Methods

    /// The project's list, or nil when it has none.
    static func list(
        forProjectID projectID: ProjectID,
        in store: ProjectStore = .shared
    ) -> [AccountID]? {
        store.project(withID: projectID)?.defaultAccounts
    }

    /// Which of the project's listed logins a new chat starts on, considering only `runtime`'s
    /// when one is named. Nil when the project has no list, or none for that runtime.
    static func resolve(
        projectID: ProjectID,
        runtime: AgentKind? = nil,
        in store: ProjectStore = .shared,
        at now: Date = Date()
    ) -> ProjectAccountOrder.Resolution? {
        guard let list = list(forProjectID: projectID, in: store) else { return nil }
        let entries = ProjectAccountOrder.entries(list, for: runtime)
        guard !entries.isEmpty else { return nil }
        return ProjectAccountOrder.resolve(candidates(entries), at: now)
    }

    /// The login a send should move to, when the draft's came from the list and is now proven
    /// out. Same runtime only — see `ProjectAccountOrder.substitute`.
    ///
    /// `model` is the model the draft would launch on; every candidate is metered against it,
    /// since a send keeps its model wherever the substitute offers it.
    static func substitution(
        projectID: ProjectID,
        current: AccountID,
        model: String?,
        in store: ProjectStore = .shared,
        at now: Date = Date()
    ) -> Substitution? {
        guard let list = list(forProjectID: projectID, in: store) else { return nil }
        let sameRuntime = ProjectAccountOrder.entries(list, for: current.provider)
        guard !sameRuntime.isEmpty else { return nil }

        let metered: (AgentAccount?) -> String? = { _ in model }
        guard let currentCandidate = candidates([current], model: metered).first else { return nil }
        let fromState = ProjectAccountOrder.state(of: currentCandidate, at: now)
        guard let replacement = ProjectAccountOrder.substitute(
            for: currentCandidate,
            among: candidates(sameRuntime, model: metered),
            at: now
        ) else { return nil }
        return Substitution(from: current, to: replacement.accountID, fromState: fromState)
    }

    /// Which of the draft's run choices `account` can honour. See `CarriedRunChoice`.
    static func carriedRunChoice(
        model: String?,
        reasoningEffort: String?,
        fastMode: Bool?,
        to account: AgentAccount
    ) -> CarriedRunChoice {
        let kind = account.provider
        let options = AgentModels.options(for: kind, account: account)
        let keptModel = model.flatMap { model in
            options.contains { $0.identifier == model } ? model : nil
        }
        let keptEffort = reasoningEffort.flatMap { effort in
            AgentModels.supports(
                reasoningEffort: effort,
                kind: kind,
                model: keptModel,
                account: account,
                options: options
            ) ? effort : nil
        }
        let keptFastMode = fastMode.flatMap { fastMode in
            AgentModels.supportsFastMode(kind: kind, model: keptModel, account: account)
                ? fastMode
                : nil
        }
        return CarriedRunChoice(
            model: keptModel,
            reasoningEffort: keptEffort,
            fastMode: keptFastMode
        )
    }

    /// Whether a login is one this Mac has discovered, switched off or not. A list may only ever
    /// name those.
    static func isDiscovered(_ accountID: AccountID) -> Bool {
        guard accountID.provider.supportsAccounts else { return false }
        return AgentAccountDiscovery.allAccounts(for: accountID.provider)
            .contains { $0.handle == accountID.handle }
    }

    /// The logins a conversation could move to, narrowed to those its project lists and put in
    /// the list's order — or nil when the project lists no login of the session's runtime, so the
    /// caller keeps its own ranking. Empty means the list names this runtime but none of its
    /// logins is a destination.
    static func listedDestinations(
        _ destinations: [AgentAccount],
        forSessionID sessionID: SessionID,
        in store: ProjectStore = .shared
    ) -> [AgentAccount]? {
        guard let session = store.session(withID: sessionID),
              let project = store.project(forSessionID: sessionID),
              let list = project.defaultAccounts else { return nil }
        let sameRuntime = ProjectAccountOrder.entries(list, for: session.kind)
        guard !sameRuntime.isEmpty else { return nil }
        return sameRuntime.compactMap { accountID in
            destinations.first { $0.id == accountID }
        }
    }

    /// Asks for fresh readings of every enabled listed login, so the decision at the send is
    /// made on the newest numbers pacing allows. Never waited on.
    static func warmReadings(
        forProjectID projectID: ProjectID,
        in store: ProjectStore = .shared
    ) {
        guard let list = list(forProjectID: projectID, in: store) else { return }
        for account in discovered(list).values where account.isEnabled {
            AccountUsageService.shared.refresh(account, force: true)
        }
    }

    /// The model a chat on `account` would run if nothing in the draft pinned one: what this
    /// login last started on, else its own configured default.
    static func defaultModel(for account: AgentAccount?) -> String? {
        guard let account else { return nil }
        if let remembered = AccountPreferencesStore.shared.newSessionRunChoice(for: account.id)?.model {
            return remembered
        }
        return AgentModels.defaultModel(for: account.provider, account: account)
    }

    /// The live facts for each listed login, in list order.
    ///
    /// `accounts` stands in for discovery when the caller already holds the logins — an editor
    /// listing them, a test stating them.
    static func candidates(
        _ list: [AccountID],
        accounts known: [AccountID: AgentAccount]? = nil,
        model: (AgentAccount?) -> String? = { defaultModel(for: $0) }
    ) -> [ProjectAccountOrder.Candidate] {
        let accounts = known ?? discovered(list)
        return list.map { accountID in
            let account = accounts[accountID]
            let presence: ProjectAccountOrder.Presence
            if let account {
                presence = account.isEnabled ? .enabled : .disabled
            } else {
                presence = .missing
            }
            return ProjectAccountOrder.Candidate(
                accountID: accountID,
                presence: presence,
                reading: AccountUsageService.shared.reading(for: accountID),
                limits: CustomLimitSettings.shared.rules(for: accountID),
                model: model(account)
            )
        }
    }

    // MARK: - Private Methods

    /// The discovered logins a list names, switched off or not, read once per runtime.
    private static func discovered(_ list: [AccountID]) -> [AccountID: AgentAccount] {
        var result: [AccountID: AgentAccount] = [:]
        var runtimes: [AgentKind] = []
        for accountID in list where !runtimes.contains(accountID.provider) {
            runtimes.append(accountID.provider)
        }
        for runtime in runtimes where runtime.supportsAccounts {
            for account in AgentAccountDiscovery.allAccounts(for: runtime) {
                result[account.id] = account
            }
        }
        return result
    }
}
