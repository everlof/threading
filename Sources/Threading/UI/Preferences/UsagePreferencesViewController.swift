import AppKit

/// Hosts the retained Usage dashboard and coordinates its two independent data feeds:
/// transcript accounting and provider limit observations. Neither filesystem scanning nor the
/// 180-day journal is read on the main actor while the page is opening.
final class UsagePreferencesViewController: NSViewController {
    private let appEvents = AppEventObservations()
    private let dashboard = UsageDashboardView()
    private var limitSeries: [UsageLimitDashboardSeries] = []
    private var historyTask: Task<Void, Never>?

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
            sections: [dashboard, SettingsUI.note(UsageStrings.footnote)],
            hostPage: .usage
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        appEvents.observe(TranscriptUsageDidChange.self) { [weak self] _ in
            self?.present(animated: true)
        }
        appEvents.observe(AccountUsageDidChange.self) { [weak self] _ in
            self?.loadLimitHistory(animated: true)
        }
        appEvents.observe(UsageLimitHistoryDidChange.self) { [weak self] _ in
            self?.loadLimitHistory(animated: true)
        }
        present(animated: false)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        present(animated: false)
        loadLimitHistory(animated: false)
        TranscriptUsageService.shared.refresh()
        refreshAuthoritativeLimits(force: false)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        historyTask?.cancel()
    }

    private func present(animated: Bool) {
        dashboard.update(
            report: TranscriptUsageService.shared.report,
            limits: limitSeries,
            isBuilding: TranscriptUsageService.shared.isBuilding,
            animated: animated
        )
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
                Self.limitSeries(from: snapshot)
            }
            let prepared = await withTaskCancellationHandler {
                await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.limitSeries = prepared
            self.present(animated: animated)
        }
    }

    private func refreshAuthoritativeLimits(force: Bool) {
        // Account discovery itself is the capability boundary. Today Claude and Codex expose
        // routable accounts; Grok/OpenCode do not, so no provider-name switch lives here.
        let accounts = AgentKind.allCases.flatMap { AgentAccountDiscovery.accounts(for: $0) }
        accounts.forEach { AccountUsageService.shared.refresh($0, force: force) }
    }

    @objc private func rebuildClicked() {
        TranscriptUsageService.shared.refresh(force: true)
        refreshAuthoritativeLimits(force: true)
        loadLimitHistory(animated: true)
    }

    nonisolated static func limitSeries(
        from snapshot: UsageLimitHistorySnapshot
    ) -> [UsageLimitDashboardSeries] {
        var samplesBySeries: [String: [UsageSample]] = [:]
        var resetsBySeries: [String: [UsageLimitResetEvent]] = [:]
        for (index, sample) in snapshot.samples.enumerated() {
            if index.isMultiple(of: 4_096), Task.isCancelled { return [] }
            guard let id = sample.limitSeriesID else { continue }
            samplesBySeries[id, default: []].append(sample)
        }
        for (index, event) in snapshot.resets.enumerated() {
            if index.isMultiple(of: 4_096), Task.isCancelled { return [] }
            resetsBySeries[event.seriesID, default: []].append(event)
        }

        return samplesBySeries.compactMap { id, raw -> UsageLimitDashboardSeries? in
                let samples = raw.sorted { $0.at < $1.at }
                guard let latest = samples.last,
                      let runtimeID = latest.runtimeID,
                      let accountID = latest.accountID,
                      let windowID = latest.windowID else { return nil }
                let runtimeName = AgentKind(rawValue: runtimeID)?.displayName ?? runtimeID
                let events = resetsBySeries[id] ?? []
                return UsageLimitDashboardSeries(
                    id: id,
                    runtimeName: runtimeName,
                    accountName: latest.accountName ?? accountID,
                    windowLabel: latest.windowLabel ?? windowID,
                    samples: samples,
                    resets: events,
                    projection: UsageLimitHistoryAnalysis.weeklyProjection(for: samples),
                    currentFraction: latest.fraction,
                    resetsAt: latest.resetsAt,
                    resetCreditCount: latest.resetCreditCount,
                    nextResetCreditExpiresAt: latest.nextResetCreditExpiresAt
                )
            }
    }
}

private enum UsageStrings {
    static var title: String { L10n.string("Usage") }
    static var summary: String {
        L10n.string("Cost, tokens, provider coverage, and 180 days of observed limit history.")
    }
    static var rebuild: String { L10n.string("Rebuild") }
    static var footnote: String {
        L10n.format(
            "Local transcripts are read incrementally and deduplicated across resumes, compactions, forks, and subagents. Runtime and billing route stay separate, so OpenCode through OpenRouter is reported honestly. Prices use exact official model identifiers from catalog %@; unmatched tokens remain visibly unpriced. Grok exposes context occupancy but no authoritative token or limit history source.",
            UsagePricingCatalog.version
        )
    }
}
