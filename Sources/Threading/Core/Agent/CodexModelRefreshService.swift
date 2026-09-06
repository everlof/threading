import Foundation

struct CodexModelRefreshDidChange: AppEvent {
    static let name = Notification.Name("codexModelRefreshDidChange")
}

/// The one action behind Settings and the command palette. One job at a time, at most 32
/// accounts, one finite child at a time, and at most 512 value models per account. The UI
/// receives progress once per account; it never receives provider-sized wire data.
@MainActor
final class CodexModelRefreshService {
    struct Outcome: Equatable, Sendable {
        let accountName: String
        let modelCount: Int
        let failure: CodexModelRefreshError?
    }

    enum State: Equatable, Sendable {
        case idle
        case discovering
        case refreshing(accountName: String, completed: Int, total: Int)
        case finished([Outcome])
        case unavailable
        case tooManyAccounts

        var isRunning: Bool {
            switch self {
            case .discovering, .refreshing: return true
            default: return false
            }
        }

        var message: String {
            switch self {
            case .idle:
                return L10n.string("Reload available models for all enabled Codex accounts.")
            case .discovering:
                return L10n.string("Finding Codex accounts…")
            case .refreshing(let account, let completed, let total):
                return L10n.format("Refreshing %@… (%lld of %lld)", account, Int64(completed + 1), Int64(total))
            case .unavailable:
                return L10n.string("Connect a Codex account to refresh its models.")
            case .tooManyAccounts:
                return L10n.string("Enable at most 32 Codex accounts before refreshing models.")
            case .finished(let outcomes):
                let succeeded = outcomes.filter { $0.failure == nil }.count
                let summary = L10n.format("Accounts refreshed: %lld of %lld.", Int64(succeeded), Int64(outcomes.count))
                let failures = outcomes.compactMap { outcome in
                    outcome.failure.map { "\(outcome.accountName): \($0.message)" }
                }
                return ([summary] + failures).joined(separator: "\n")
            }
        }
    }

    typealias AccountsProvider = @MainActor () async -> [AgentAccount]
    typealias Refresh = @Sendable (AgentAccount, AgentLaunchPlan) async throws -> Int
    static let shared = CodexModelRefreshService()

    private let accountsProvider: AccountsProvider
    private let refresh: Refresh
    private(set) var state: State

    init(
        initialState: State = .idle,
        accountsProvider: @escaping AccountsProvider = { await AgentAccountDiscovery.codexAccountsForModelRefresh() },
        refresh: @escaping Refresh = { account, plan in
            let catalog = try CodexModelCatalogClient.fetch(plan: plan, expectedHome: account.configPath)
            let entry = CodexModelCatalogStore.Entry(
                catalog: catalog, refreshedAt: Date(),
                authentication: CodexModelCatalogStore.authenticationIdentity(for: account)
            )
            guard await CodexModelCatalogStore.shared.record(entry, for: account) else {
                throw CodexModelRefreshError.saveFailed
            }
            return catalog.options.count
        }
    ) {
        self.state = initialState
        self.accountsProvider = accountsProvider
        self.refresh = refresh
    }

    @discardableResult
    func start(completion: (@MainActor (State) -> Void)? = nil) -> Bool {
        guard !state.isRunning else { return false }
        setState(.discovering)
        Task {
            let accounts = await accountsProvider()
            guard !accounts.isEmpty else {
                setState(.unavailable)
                completion?(state)
                return
            }
            guard accounts.count <= CodexModelCatalogStore.maximumAccounts else {
                setState(.tooManyAccounts)
                completion?(state)
                return
            }
            var outcomes: [Outcome] = []
            for account in accounts {
                setState(.refreshing(
                    accountName: account.displayName, completed: outcomes.count, total: accounts.count
                ))
                let plan = AgentLauncher.codexAccountAppServerPlan(for: account)
                let refresh = self.refresh
                let outcome = await Task.detached(priority: .userInitiated) {
                    do {
                        let count = try await refresh(account, plan)
                        return Outcome(accountName: account.displayName, modelCount: count, failure: nil)
                    } catch {
                        return Outcome(
                            accountName: account.displayName, modelCount: 0,
                            failure: (error as? CodexModelRefreshError) ?? .unavailable
                        )
                    }
                }.value
                outcomes.append(outcome)
                if outcome.failure == nil {
                    NotificationCenter.default.post(AgentModelsDidChange())
                }
            }
            setState(.finished(outcomes))
            completion?(state)
        }
        return true
    }

    private func setState(_ state: State) {
        self.state = state
        NotificationCenter.default.post(CodexModelRefreshDidChange())
        NotificationCenter.default.post(CommandRegistryDidChange())
    }
}
