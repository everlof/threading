import Foundation

/// A one-start owner decision, deliberately outside the provider's permission policy and the
/// manager control plane. The plan is frozen before presentation, including a resolved `best`.
@MainActor
final class SubagentAccountApproval {
    static let maximumPendingPerSession = 4
    static let maximumReadingAge: TimeInterval = 120

    let id = UUID()
    let parentID: SessionID
    let plan: ScheduledSessionPlan
    let brief: String
    let accountName: String
    let account: AgentAccount?
    private(set) var reading: AccountUsageReading = .notFetched
    private(set) var isRefreshing = false
    private(set) var isResolved = false
    var onChange: (() -> Void)?
    var onResolution: (() -> Void)?

    private let read: () -> AccountUsageReading
    private let refreshReading: (@escaping @MainActor () -> Void) -> Void
    private let limits: () -> [CustomLimit]
    private let now: () -> Date
    private var completion: ((Bool) -> Void)?
    private var expiration: Task<Void, Never>?

    init(
        parentID: SessionID, plan: ScheduledSessionPlan, brief: String,
        accountName: String, account: AgentAccount?,
        read: @escaping () -> AccountUsageReading,
        refresh: @escaping (@escaping @MainActor () -> Void) -> Void,
        limits: @escaping () -> [CustomLimit],
        now: @escaping () -> Date = Date.init,
        completion: @escaping (Bool) -> Void
    ) {
        self.parentID = parentID
        self.plan = plan
        self.brief = brief
        self.accountName = accountName
        self.account = account
        self.read = read
        self.refreshReading = refresh
        self.limits = limits
        self.now = now
        self.completion = completion
        reading = read()
    }

    static func requiresApproval(plan: ScheduledSessionPlan, parent: AgentSession) -> Bool {
        plan.kind != parent.kind || plan.accountHandle != parent.accountHandle
    }

    var rules: [CustomLimit] { limits() }
    var observedNow: Date { now() }

    /// A lost client or closed tool call cannot leave an approval that starts work much later.
    func beginWaiting() {
        guard expiration == nil, !isResolved else { return }
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.deny()
        }
    }

    var canApprove: Bool {
        guard !isResolved, !isRefreshing else { return false }
        // Providers without usage reporting still require consent; say that data is unavailable.
        guard let account else { return !plan.kind.supportsAccounts }
        guard case .current(let usage) = reading,
              now().timeIntervalSince(usage.observedAt) <= Self.maximumReadingAge else { return false }
        return LimitEscapeRanking.hasHeadroom(
            .init(accountID: account.id, usage: usage, limits: rules), metering: plan.model, at: now()
        )
    }

    func refresh() {
        guard !isResolved, !isRefreshing, account != nil else { return }
        isRefreshing = true
        onChange?()
        refreshReading { [weak self] in
            guard let self, !self.isResolved else { return }
            self.reading = self.read()
            self.isRefreshing = false
            self.onChange?()
        }
    }

    /// Approval is rechecked at the press, not just when the button last drew. A stale card
    /// refreshes and needs another explicit press; a refresh can never supply an answer.
    func approve() {
        guard canApprove else { refresh(); return }
        settle(true)
    }

    func deny() { settle(false) }

    private func settle(_ approved: Bool) {
        guard !isResolved else { return }
        isResolved = true
        expiration?.cancel()
        expiration = nil
        let callback = completion
        completion = nil
        onChange = nil
        let remove = onResolution
        onResolution = nil
        remove?()
        callback?(approved)
    }
}
