import Foundation
import ThreadingRemoteKit

/// A bounded capacity cache. Session/transcript cardinality never participates in this owner.
@MainActor
final class RemoteUsageCapacityService {
    typealias Discover = @MainActor () async throws -> (accounts: [AgentAccount], omitted: Int)
    private let reading: (AgentAccount) -> AccountUsageReading
    private let refresh: (AgentAccount) -> Void
    private let discover: Discover
    private let events = AppEventObservations()
    private var accounts: [AgentAccount] = []
    private var accountIndex: [AccountID: Int] = [:]
    private var readings: [AccountUsageReading] = []
    private var discovery: Task<Void, Error>?
    private var needsDiscovery = true
    private var discoveredAt: Date?
    private var generation: UInt64 = 0
    private var omittedAccounts = 0
    private var epoch = UUID().uuidString
    private var revision: UInt64 = 0
    var didChange: ((RemoteUsageCapacityChangedDTO) -> Void)?

    convenience init(usage: AccountUsageService, discover: @escaping Discover = {
        try await AgentAccountDiscovery.accountsForCapacity()
    }) {
        self.init(discover: discover, reading: { usage.reading(for: $0) }, refresh: { usage.refresh($0) })
    }

    init(discover: @escaping Discover, reading: @escaping (AgentAccount) -> AccountUsageReading,
         refresh: @escaping (AgentAccount) -> Void) {
        self.reading = reading
        self.refresh = refresh
        self.discover = discover
        events.observe(AccountUsageDidChange.self) { [weak self] event in
            self?.readingChanged(event.accountID)
        }
        events.observe(AccountPreferencesDidChange.self) { [weak self] _ in self?.invalidateAccounts() }
        events.observe(ProjectsDidChange.self) { [weak self] event in
            // Account setup announces admission through the existing structural event.
            if case .structure = event.sidebarImpact { self?.invalidateAccounts() }
        }
    }

    func snapshot() async throws -> RemoteUsageCapacityDTO {
        if let discoveredAt, Date().timeIntervalSince(discoveredAt) >= 300, !needsDiscovery {
            invalidateAccounts()
        }
        if needsDiscovery {
            if let discovery { try await discovery.value }
            else {
                let current = generation
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let result = try await discover()
                    guard current == generation else { throw CancellationError() }
                    install(result.accounts, omitted: result.omitted)
                    needsDiscovery = false
                    discoveredAt = Date()
                }
                discovery = task
                do { try await task.value; discovery = nil }
                catch { discovery = nil; throw error }
            }
        }
        guard !needsDiscovery else { throw CancellationError() }
        // Refresh is paced and single-flight at the existing owner; it returns cached data now
        // and the settled reading invalidates clients through didChange.
        for account in accounts { refresh(account) }
        var remaining = RemoteUsageCapacityLimits.windows
        var omittedWindows = 0
        let bounded = accounts.enumerated().map { index, account in
            let reading = readings[index]
            let projected = project(account, reading: reading, maximumWindows: remaining)
            remaining -= projected.windows.count
            omittedWindows += (reading.usage?.windows.count ?? 0)
                + (reading.usage?.modelWindows.count ?? 0) - projected.windows.count
            return projected
        }
        let value = RemoteUsageCapacityDTO(epoch: epoch, revision: revision, accounts: bounded,
            omittedAccountCount: omittedAccounts, omittedWindowCount: omittedWindows)
        try value.validate()
        return value
    }

    func invalidateAccounts() {
        generation &+= 1
        needsDiscovery = true
        discovery?.cancel()
        accounts = []
        accountIndex = [:]
        readings = []
        advance()
    }

    private func install(_ candidates: [AgentAccount], omitted: Int) {
        var seen = Set<AccountID>()
        accounts = candidates.prefix(RemoteUsageCapacityLimits.accounts).filter { seen.insert($0.id).inserted }
        accountIndex = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($0.element.id, $0.offset) })
        readings = accounts.map(reading)
        omittedAccounts = omitted + max(0, candidates.count - RemoteUsageCapacityLimits.accounts)
        advance()
    }

    private func readingChanged(_ id: AccountID) {
        guard let index = accountIndex[id] else { return }
        let updated = reading(accounts[index])
        // Provider arrays may grow independently of the widget contract. Compare only the
        // bounded projection and omission count rather than walking every cached source window.
        let previous = readings[index]
        let account = accounts[index]
        guard project(account, reading: updated, maximumWindows: RemoteUsageCapacityLimits.windows)
            != project(account, reading: previous, maximumWindows: RemoteUsageCapacityLimits.windows)
            || updated.usage?.windows.count != previous.usage?.windows.count
            || updated.usage?.modelWindows.count != previous.usage?.modelWindows.count else { return }
        readings[index] = updated
        advance()
    }

    private func advance() {
        if revision == .max { epoch = UUID().uuidString; revision = 0 }
        revision += 1
        didChange?(RemoteUsageCapacityChangedDTO(epoch: epoch, revision: revision))
    }

    private func project(_ account: AgentAccount, reading: AccountUsageReading,
                         maximumWindows: Int) -> RemoteUsageCapacityAccountDTO {
        let state: RemoteUsageCapacityReadingState
        switch reading {
        case .current: state = .current
        case .stale: state = .stale
        case .notFetched, .failed: state = .unavailable
        }
        let current = reading.usage
        let windows = (current?.windows ?? []).prefix(maximumWindows)
        let scoped = (current?.modelWindows ?? []).prefix(maximumWindows - windows.count)
        return RemoteUsageCapacityAccountDTO(
            runtimeID: account.provider.rawValue,
            runtimeName: RemoteUsageCapacityLimits.label(account.provider.displayName),
            accountID: account.handle.name,
            accountName: RemoteUsageCapacityLimits.label(account.displayName),
            observedAt: current?.observedAt.timeIntervalSince1970,
            state: state,
            windows: (Array(windows) + scoped).map {
                RemoteAccountUsageWindowDTO(id: $0.id, name: RemoteUsageCapacityLimits.label($0.compactName),
                    fraction: $0.fraction, resetsAt: $0.resetsAt?.timeIntervalSince1970,
                    windowDuration: $0.windowDuration)
            }
        )
    }
}
