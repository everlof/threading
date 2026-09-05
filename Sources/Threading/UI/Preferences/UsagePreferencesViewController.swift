import AppKit

/// Hosts the retained Usage page and coordinates its three independent data feeds: live account
/// capacity, provider-limit history, and transcript accounting. Neither filesystem scanning nor
/// the 180-day journal is read on the main actor while the page is opening.
final class UsagePreferencesViewController: NSViewController {
    typealias AccountsProvider = @MainActor () -> [AgentAccount]
    typealias ReadingProvider = @MainActor (AgentAccount) -> AccountUsageReading
    typealias RefreshProvider = @MainActor (AgentAccount, Bool) -> Void

    private let appEvents = AppEventObservations()
    private let liveCapacity = AccountUsageFleetView(scrollHost: .nestedPage)
    private let dashboard = UsageDashboardView()
    private let accountsProvider: AccountsProvider
    private let readingProvider: ReadingProvider
    private let refreshProvider: RefreshProvider
    private let bankedResetService: BankedUsageResetService
    private var accountsByID: [AccountID: AgentAccount] = [:]
    private var overviewProjection: UsageDashboardOverviewProjection?
    private var limitSeries: [UsageLimitDashboardSeries] = []
    /// `/usage` can arrive while the journal projection is still loading. Retain the stable
    /// account identity until a matching series exists instead of silently focusing the first.
    private var pendingUsageFocusAccountID: AccountID?
    private var overviewTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?

    init(
        accountsProvider: @escaping AccountsProvider = {
            AgentKind.allCases.flatMap { AgentAccountDiscovery.accounts(for: $0) }
        },
        readingProvider: @escaping ReadingProvider = {
            AccountUsageService.shared.reading(for: $0)
        },
        refreshProvider: @escaping RefreshProvider = {
            AccountUsageService.shared.refresh($0, force: $1)
        },
        bankedResetService: BankedUsageResetService = .shared
    ) {
        self.accountsProvider = accountsProvider
        self.readingProvider = readingProvider
        self.refreshProvider = refreshProvider
        self.bankedResetService = bankedResetService
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let rebuild = SettingsUI.button(
            UsageStrings.rebuild,
            target: self,
            action: #selector(rebuildClicked)
        )
        view = SettingsUI.page(
            title: UsageStrings.title,
            summary: UsageStrings.summary,
            actions: [rebuild],
            sections: [
                dashboard,
                SettingsUI.section(UsageStrings.currentCapacity, liveCapacity),
                SettingsUI.note(UsageStrings.footnote)
            ],
            hostPage: .usage
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dashboard.onUseBankedReset = { [weak self] series in
            self?.useBankedReset(for: series)
        }
        appEvents.observe(TranscriptUsageDidChange.self) { [weak self] _ in
            self?.prepareOverview(animated: true)
        }
        appEvents.observe(TranscriptUsageScanProgressDidChange.self) { [weak self] _ in
            self?.dashboard.updateScanProgress(
                TranscriptUsageService.shared.scanProgress,
                isBuilding: TranscriptUsageService.shared.isBuilding
            )
        }
        appEvents.observe(AccountUsageDidChange.self) { [weak self] event in
            self?.usageChanged(event)
        }
        appEvents.observe(AccountPreferencesDidChange.self) { [weak self] _ in
            self?.reloadLiveCapacity()
            self?.refreshAuthoritativeLimits(force: false)
        }
        appEvents.observe(UsageLimitHistoryDidChange.self) { [weak self] _ in
            self?.loadLimitHistory(animated: true)
        }
        appEvents.observe(BankedUsageResetStateDidChange.self) { [weak self] event in
            guard let self else { return }
            self.dashboard.setBankedResetState(
                accountID: event.accountID,
                isBusy: self.bankedResetService.isBusy(event.accountID)
            )
        }
        appEvents.observe(UsageFocusRequested.self) { [weak self] event in
            guard let self else { return }
            self.pendingUsageFocusAccountID = event.accountID
            self.dashboard.focusLimitHistory(accountID: event.accountID)
        }
        prepareOverview(animated: false)
        reloadLiveCapacity()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        prepareOverview(animated: false)
        reloadLiveCapacity()
        loadLimitHistory(animated: false)
        TranscriptUsageService.shared.refresh()
        refreshAuthoritativeLimits(force: false)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        overviewTask?.cancel()
        historyTask?.cancel()
    }

    private func present(animated: Bool) {
        dashboard.update(
            overview: overviewProjection,
            limits: limitSeries,
            isBuilding: TranscriptUsageService.shared.isBuilding,
            scanProgress: TranscriptUsageService.shared.scanProgress,
            animated: animated
        )
        if let accountID = pendingUsageFocusAccountID {
            dashboard.focusLimitHistory(accountID: accountID)
            if limitSeries.contains(where: { $0.accountID == accountID.rawValue }) {
                pendingUsageFocusAccountID = nil
            }
        }
    }

    private func prepareOverview(animated: Bool) {
        overviewTask?.cancel()
        guard let report = TranscriptUsageService.shared.report else {
            overviewProjection = nil
            present(animated: animated)
            return
        }
        overviewTask = Task { [weak self] in
            let preparation = Task.detached(priority: .utility) {
                UsageDashboardProjector.overview(report: report)
            }
            let prepared = await withTaskCancellationHandler {
                await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            guard !Task.isCancelled, let prepared, let self else { return }
            self.overviewProjection = prepared
            self.present(animated: animated)
        }
    }

    private func loadLimitHistory(animated: Bool) {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            let now = Date()
            let snapshot = await UsageHistoryStore.shared.loadSnapshot(
                since: now.addingTimeInterval(-90 * 86_400),
                now: now
            )
            let preparation = Task.detached(priority: .utility) {
                UsageDashboardProjector.limits(from: snapshot)
            }
            let prepared = await withTaskCancellationHandler {
                await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.limitSeries = prepared.series
            self.present(animated: animated)
        }
    }

    private func refreshAuthoritativeLimits(force: Bool) {
        // Account discovery itself is the capability boundary. Today Claude and Codex expose
        // routable accounts; Grok/OpenCode do not, so no provider-name switch lives here.
        accountsProvider().forEach { refreshProvider($0, force) }
    }

    private func reloadLiveCapacity() {
        let accounts = accountsProvider()
        accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        liveCapacity.show(accounts.map {
            AccountUsageFleetItem(
                account: $0,
                reading: readingProvider($0),
                isCurrent: false,
                allowsHandoff: false
            )
        })
    }

    private func usageChanged(_ event: AccountUsageDidChange) {
        guard let account = accountsByID[event.accountID] else { return }
        liveCapacity.update(reading: readingProvider(account), for: event.accountID)
    }

    @objc private func rebuildClicked() {
        TranscriptUsageService.shared.refresh(force: true)
        refreshAuthoritativeLimits(force: true)
        loadLimitHistory(animated: true)
    }

    private func useBankedReset(for series: UsageLimitDashboardSeries) {
        guard let rawAccountID = series.accountID,
              let accountID = AccountID(rawValue: rawAccountID),
              let account = accountsByID[accountID],
              account.provider.supports(.bankedUsageReset) else {
            return
        }

        dashboard.setBankedResetState(
            accountID: accountID,
            isBusy: true,
            status: L10n.string("Checking banked reset…")
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let offer = try await bankedResetService.prepare(account: account)
                dashboard.setBankedResetState(accountID: accountID, isBusy: true, status: "")
                guard await confirmBankedReset(offer) else {
                    dashboard.setBankedResetState(accountID: accountID, isBusy: false, status: "")
                    return
                }

                dashboard.setBankedResetState(
                    accountID: accountID,
                    isBusy: true,
                    status: L10n.string("Using banked reset…")
                )
                let result = try await bankedResetService.redeem(
                    account: account,
                    offer: offer
                )
                dashboard.setBankedResetState(
                    accountID: accountID,
                    isBusy: false,
                    status: BankedUsageResetConfirmation.resultMessage(result)
                )
                loadLimitHistory(animated: true)
            } catch {
                dashboard.setBankedResetState(
                    accountID: accountID,
                    isBusy: false,
                    status: error.localizedDescription
                )
            }
        }
    }

    private func confirmBankedReset(_ offer: BankedUsageResetOffer) async -> Bool {
        await withCheckedContinuation { continuation in
            ConfirmationAlert.ask(
                BankedUsageResetConfirmation.request(for: offer),
                in: view.window
            ) { continuation.resume(returning: $0) }
        }
    }

}

private enum UsageStrings {
    static var title: String { L10n.string("Usage") }
    static var summary: String {
        L10n.string("Live capacity, observed limit history, cost, tokens, and provider coverage.")
    }
    static var currentCapacity: String { L10n.string("Current capacity") }
    static var rebuild: String { L10n.string("Rebuild") }
    static var footnote: String {
        L10n.format(
            "Local transcripts are read incrementally and deduplicated across resumes, compactions, forks, and subagents. Runtime and billing route stay separate, so OpenCode through OpenRouter is reported honestly. Prices use exact official model identifiers from catalog %@; unmatched tokens remain visibly unpriced. Grok exposes context occupancy but no authoritative token or limit history source.",
            UsagePricingCatalog.version
        )
    }
}
