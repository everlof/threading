import Foundation

/// A one-start owner decision, outside provider permission policy and manager authority.
/// Only the owner can replace the proposed login; the provider/model and task stay fixed.
@MainActor
final class SubagentAccountApproval {
    static let maximumPendingPerSession = 4
    static let maximumReadingAge: TimeInterval = 120

    enum Funding: Equatable {
        case includedUsage
        case credits
    }

    struct Approval {
        let plan: ScheduledSessionPlan
        let accountName: String
        let funding: Funding
    }

    let id = UUID()
    let parentID: SessionID
    private(set) var plan: ScheduledSessionPlan
    let brief: String
    private(set) var accountName: String
    private(set) var account: AgentAccount?
    let accounts: [AgentAccount]
    private(set) var reading: AccountUsageReading = .notFetched
    private(set) var isRefreshing = false
    private(set) var isResolved = false
    var onChange: (() -> Void)?
    var onResolution: (() -> Void)?

    private let read: (AgentAccount) -> AccountUsageReading
    private let refreshReading: (AgentAccount, @escaping @MainActor () -> Void) -> Void
    private let limits: (AccountID) -> [CustomLimit]
    private let now: () -> Date
    private var completion: ((Approval?) -> Void)?
    private var expiration: Task<Void, Never>?
    private var selectionRevision = 0

    init(
        parentID: SessionID, plan: ScheduledSessionPlan, brief: String,
        accountName: String, account: AgentAccount?, accounts: [AgentAccount] = [],
        read: @escaping (AgentAccount) -> AccountUsageReading,
        refresh: @escaping (AgentAccount, @escaping @MainActor () -> Void) -> Void,
        limits: @escaping (AccountID) -> [CustomLimit],
        now: @escaping () -> Date = Date.init,
        completion: @escaping (Approval?) -> Void
    ) {
        self.parentID = parentID
        self.plan = plan
        self.brief = brief
        self.accountName = accountName
        self.account = account
        self.accounts = accounts.filter { $0.isEnabled && $0.provider == plan.kind }
        self.read = read
        self.refreshReading = refresh
        self.limits = limits
        self.now = now
        self.completion = completion
        reading = account.map(read) ?? .notFetched
    }

    static func requiresApproval(plan: ScheduledSessionPlan, parent: AgentSession) -> Bool {
        plan.kind != parent.kind || plan.accountHandle != parent.accountHandle
    }

    var rules: [CustomLimit] { account.map { limits($0.id) } ?? [] }
    var observedNow: Date { now() }

    /// Cached values only. Building the chooser never fetches every account.
    func reading(for account: AgentAccount) -> AccountUsageReading { read(account) }
    func rules(for account: AgentAccount) -> [CustomLimit] { limits(account.id) }

    func selectAccount(_ id: AccountID) {
        guard !isResolved, id != account?.id,
              let selected = accounts.first(where: { $0.id == id }) else { return }
        selectionRevision += 1
        isRefreshing = false
        account = selected
        accountName = selected.displayName
        plan = ScheduledSessionPlan(
            reservedSessionID: plan.reservedSessionID, projectID: plan.projectID,
            kind: plan.kind, accountHandle: selected.handle, model: plan.model,
            reasoningEffort: plan.reasoningEffort, fastMode: plan.fastMode, branch: plan.branch,
            usesNativeUI: plan.usesNativeUI, permissionMode: plan.permissionMode,
            managedWorkspacePlan: plan.managedWorkspacePlan, automationWorkspace: plan.automationWorkspace,
            role: plan.role ?? .chat, curfew: plan.curfew)
        reading = read(selected)
        refresh()
    }

    /// A lost client or closed tool call cannot leave an approval that starts work much later.
    func beginWaiting() {
        guard expiration == nil, !isResolved else { return }
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.deny()
        }
    }

    var funding: Funding? {
        guard !isResolved, !isRefreshing else { return nil }
        // Providers without usage reporting still require consent and disclose missing data.
        guard let account else { return plan.kind.supportsAccounts ? nil : .includedUsage }
        return Self.funding(for: account, reading: reading, rules: rules, model: plan.model, at: now())
    }

    var canApprove: Bool { funding != nil }

    /// Shared by the card and final admission. Purchased credits are an explicit, one-start
    /// choice, never capacity for automatic account ranking or a bypass of the owner's limits.
    static func funding(
        for account: AgentAccount, reading: AccountUsageReading, rules: [CustomLimit],
        model: String?, at now: Date
    ) -> Funding? {
        guard account.isEnabled, case .current(let usage) = reading,
              now.timeIntervalSince(usage.observedAt) <= maximumReadingAge else { return nil }
        guard !CustomLimitBounds.hold(on: usage, in: rules, at: now).isHolding else { return nil }
        let windows = usage.windows(metering: model)
        guard !windows.isEmpty else { return nil }
        var includedUsageAvailable = true
        for window in windows {
            guard !window.isExpired(at: now), let fraction = window.fraction,
                  fraction.isFinite, fraction >= 0 else { return nil }
            let bound = CustomLimitBounds.effectiveBound(on: window.id, in: rules, window: window, at: now)
            if bound < 1 && fraction >= bound { return nil }
            if fraction >= 1 { includedUsageAvailable = false }
        }
        if includedUsageAvailable { return .includedUsage }
        guard let balance = usage.creditBalance.flatMap(Double.init), balance.isFinite, balance > 0 else { return nil }
        return .credits
    }

    func refresh() {
        guard !isResolved, !isRefreshing, let account else { return }
        let revision = selectionRevision
        isRefreshing = true
        onChange?()
        refreshReading(account) { [weak self] in
            guard let self, !self.isResolved, self.selectionRevision == revision else { return }
            self.reading = self.read(account)
            self.isRefreshing = false
            self.onChange?()
        }
    }

    /// The visible button supplies its funding choice. A changed reading must never turn an
    /// ordinary approval into consent to paid credits between drawing and pressing the button.
    func approve(funding offeredFunding: Funding = .includedUsage) {
        guard let currentFunding = funding else { refresh(); return }
        guard currentFunding == offeredFunding else { onChange?(); return }
        settle(Approval(plan: plan, accountName: accountName, funding: offeredFunding))
    }

    func deny() { settle(nil) }

    private func settle(_ approval: Approval?) {
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
        callback?(approval)
    }
}
