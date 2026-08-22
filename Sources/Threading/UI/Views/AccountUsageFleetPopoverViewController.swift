import AppKit

/// The pinned all-account presentation behind Option-clicking the toolbar usage pill.
///
/// It shares the fleet view used by Usage settings, while this controller owns the transient
/// operational parts: discovery, refresh pacing, live usage events, and move-to-account actions.
final class AccountUsageFleetPopoverViewController: NSViewController {
    typealias AccountsProvider = @MainActor () -> [AgentAccount]
    typealias ReadingProvider = @MainActor (AgentAccount) -> AccountUsageReading
    typealias RefreshProvider = @MainActor (AgentAccount) -> Void
    typealias NowProvider = @MainActor () -> Date

    private let currentAccountID: AccountID?
    private let handoffAccountIDs: Set<AccountID>
    private let accountsProvider: AccountsProvider
    private let readingProvider: ReadingProvider
    private let refreshProvider: RefreshProvider
    private let nowProvider: NowProvider
    private let fleet = AccountUsageFleetView(
        maximumHeight: Design.AccountUsageFleet.popoverMaximumHeight
    )
    private let appEvents = AppEventObservations()

    var onHandoff: ((AgentAccount) -> Void)?

    init(
        currentAccountID: AccountID?,
        handoffAccountIDs: Set<AccountID>,
        accountsProvider: @escaping AccountsProvider = {
            AgentKind.allCases.flatMap { AgentAccountDiscovery.accounts(for: $0) }
        },
        readingProvider: @escaping ReadingProvider = {
            AccountUsageService.shared.reading(for: $0)
        },
        refreshProvider: @escaping RefreshProvider = {
            AccountUsageService.shared.refresh($0, force: true)
        },
        nowProvider: @escaping NowProvider = { Date() }
    ) {
        self.currentAccountID = currentAccountID
        self.handoffAccountIDs = handoffAccountIDs
        self.accountsProvider = accountsProvider
        self.readingProvider = readingProvider
        self.refreshProvider = refreshProvider
        self.nowProvider = nowProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = NSView()
        fleet.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fleet)
        NSLayoutConstraint.activate([
            fleet.topAnchor.constraint(equalTo: container.topAnchor, constant: Design.Spacing.inset),
            fleet.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Design.Spacing.inset),
            fleet.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Design.Spacing.inset),
            fleet.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Design.Spacing.inset),
            container.widthAnchor.constraint(equalToConstant: Design.AccountUsageFleet.popoverWidth)
        ])
        fleet.onHandoff = { [weak self] account in self?.onHandoff?(account) }
        view = container
        view.setAccessibilityIdentifier("toolbar.all-account-usage-popover")

        appEvents.observe(AccountUsageDidChange.self) { [weak self] _ in self?.render() }
        appEvents.observe(AccountPreferencesDidChange.self) { [weak self] _ in self?.reload() }
        reload()
    }

    private func reload() {
        let accounts = accountsProvider()
        render(accounts)
        accounts.forEach(refreshProvider)
    }

    private func render(_ accounts: [AgentAccount]? = nil) {
        let accounts = accounts ?? accountsProvider()
        fleet.show(accounts.map {
            AccountUsageFleetItem(
                account: $0,
                reading: readingProvider($0),
                isCurrent: $0.id == currentAccountID,
                allowsHandoff: handoffAccountIDs.contains($0.id)
            )
        }, at: nowProvider())
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }
}
