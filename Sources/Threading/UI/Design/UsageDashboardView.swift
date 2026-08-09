import AppKit

// MARK: - Limit presentation input

/// The dashboard's provider-neutral view of one metered window. It carries observations and
/// separately-classified estimates/events; the chart decides how to ink them, never what they
/// mean.
struct UsageLimitDashboardSeries: Equatable, Sendable, Identifiable {
    let id: String
    let runtimeName: String
    let accountName: String
    let windowLabel: String
    let samples: [UsageSample]
    let resets: [UsageLimitResetEvent]
    let projection: UsageLimitProjection?
    let currentFraction: Double?
    let resetsAt: Date?
    let resetCreditCount: Int?
    let nextResetCreditExpiresAt: Date?

    var title: String { "\(runtimeName) · \(accountName) · \(windowLabel)" }
}

// MARK: - Dashboard

/// The retained Usage dashboard. It owns one chart per subject and updates their models in
/// place, so range/metric/provider changes morph fluidly instead of replacing the view tree.
/// All potentially long breakdowns live in a recycling table; provider and coverage rows are
/// bounded by the runtime/route set.
final class UsageDashboardView: NSView, ThemedComponent {
    enum DashboardTab: Int, CaseIterable {
        case overview
        case limitHistory

        var title: String {
            switch self {
            case .overview: return L10n.string("Overview")
            case .limitHistory: return L10n.string("Limit history")
            }
        }
    }

    enum Metric: Int, CaseIterable {
        case cost
        case tokens

        var title: String {
            switch self {
            case .cost: return L10n.string("Cost")
            case .tokens: return L10n.string("Tokens")
            }
        }
    }

    enum Breakdown: Int, CaseIterable {
        case models
        case projects
        case accounts
        case providers

        var title: String {
            switch self {
            case .models: return L10n.string("Models")
            case .projects: return L10n.string("Projects")
            case .accounts: return L10n.string("Accounts")
            case .providers: return L10n.string("Providers")
            }
        }
    }

    private var report: TranscriptUsageReport?
    private var limits: [UsageLimitDashboardSeries] = []
    private var isBuilding = false
    private var selectedDays = 30
    private var selectedMetric = Metric.cost
    private var selectedBreakdown = Breakdown.models
    private var selectedTab = DashboardTab.overview
    private var selectedLimitDays = 30
    private var selectedLimitID: String?
    private var hasPresentedUsage = false
    private var hasPresentedLimits = false
    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private let tabControl = ThemedSegmentedControl()
    private let rangeControl = ThemedSegmentedControl()
    private let metricControl = ThemedSegmentedControl()
    private let consumptionHero = UsageConsumptionHeroView()
    private let usageChart = ThemedStackedBandChartView(frame: .zero)
    private let metricCards = (0..<5).map { _ in UsageMetricCardView() }
    private let breakdownPopUp = ThemedPopUp()
    private let breakdownTable = UsageBreakdownTableView()
    private let coverageView = UsageCoverageListView()

    private let limitChooser = ThemedPopUp()
    private let limitRangeControl = ThemedSegmentedControl()
    private let limitChart = ThemedTimeSeriesChartView()
    private let limitCards = (0..<4).map { _ in UsageMetricCardView() }

    private let column = NSStackView()
    private let overviewColumn = NSStackView()
    private let limitColumn = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        report: TranscriptUsageReport?,
        limits: [UsageLimitDashboardSeries],
        isBuilding: Bool,
        animated: Bool
    ) {
        self.report = report
        self.limits = limits.sorted { $0.title < $1.title }
        self.isBuilding = isBuilding

        let validIDs = Set(self.limits.map(\.id))
        if selectedLimitID.map({ !validIDs.contains($0) }) ?? true {
            selectedLimitID = self.limits.first?.id
        }
        configureLimitChooser()
        refreshUsage(animated: animated && hasPresentedUsage)
        refreshLimits(animated: animated && hasPresentedLimits)
        hasPresentedUsage = report != nil
        hasPresentedLimits = !limits.isEmpty
    }

    var usageRenderedPointCountForTesting: Int { usageChart.renderedPointCount }
    var limitRenderedPointCountForTesting: Int { limitChart.renderedPointCount }
    var limitRenderedMarkerCountForTesting: Int { limitChart.renderedMarkerCount }
    var usageChartCompositionForTesting: ThemedChartComposition { usageChart.composition }
    var limitChartCompositionForTesting: ThemedChartComposition { limitChart.composition }
    var breakdownVisibleSubviewCountForTesting: Int { breakdownTable.visibleCellCount }
    var topToolCountForTesting: Int { consumptionHero.toolCount }
    var visibleTabForTesting: DashboardTab { selectedTab }

    func selectTabForTesting(_ tab: DashboardTab) {
        tabControl.selectedIndex = tab.rawValue
        select(tab: tab, animated: false)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.large
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Design.UsageDashboard.minimumContentWidth)
        ])

        [overviewColumn, limitColumn].forEach { content in
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = Design.Spacing.large
            content.detachesHiddenViews = true
        }

        tabControl.configure(titles: DashboardTab.allCases.map(\.title), selectedIndex: 0)
        tabControl.widthAnchor.constraint(
            equalToConstant: Design.UsageDashboard.tabControlWidth
        ).isActive = true
        tabControl.setAccessibilityLabel(L10n.string("Usage section"))
        tabControl.onSelect = { [weak self] index in
            guard let tab = DashboardTab(rawValue: index) else { return }
            self?.select(tab: tab, animated: true)
        }
        let tabSpacer = NSView()
        tabSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let tabRow = NSStackView(views: [tabControl, tabSpacer])
        tabRow.orientation = .horizontal
        tabRow.distribution = .fill
        column.addArrangedSubview(tabRow)

        rangeControl.configure(titles: ["7d", "30d", "90d"], selectedIndex: 1)
        rangeControl.widthAnchor.constraint(
            equalToConstant: Design.UsageDashboard.rangeControlWidth
        ).isActive = true
        rangeControl.setAccessibilityLabel(L10n.string("Usage date range"))
        rangeControl.onSelect = { [weak self] index in
            self?.selectedDays = [7, 30, 90][index]
            self?.refreshUsage(animated: true)
        }

        metricControl.configure(titles: Metric.allCases.map(\.title), selectedIndex: 0)
        metricControl.widthAnchor.constraint(
            equalToConstant: Design.UsageDashboard.metricControlWidth
        ).isActive = true
        metricControl.setAccessibilityLabel(L10n.string("Usage metric"))
        metricControl.onSelect = { [weak self] index in
            guard let metric = Metric(rawValue: index) else { return }
            self?.selectedMetric = metric
            self?.refreshUsage(animated: true)
        }

        let overviewControls = NSStackView(views: [rangeControl, metricControl])
        overviewControls.orientation = .horizontal
        overviewControls.spacing = Design.Spacing.medium
        overviewColumn.addArrangedSubview(sectionHeader(
            title: L10n.string("Consumption"),
            detail: L10n.string("Total measured usage and the tools driving it."),
            control: overviewControls
        ))

        consumptionHero.widthAnchor.constraint(
            equalToConstant: Design.UsageDashboard.consumptionSummaryWidth
        ).isActive = true
        usageChart.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heroRow = NSStackView(views: [consumptionHero, usageChart])
        heroRow.orientation = .horizontal
        heroRow.alignment = .top
        heroRow.distribution = .fill
        heroRow.spacing = Design.Spacing.large
        overviewColumn.addArrangedSubview(heroRow)
        consumptionHero.heightAnchor.constraint(equalTo: usageChart.heightAnchor).isActive = true

        let cards = NSStackView(views: metricCards)
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = Design.Spacing.medium
        overviewColumn.addArrangedSubview(cards)

        breakdownPopUp.target = self
        breakdownPopUp.action = #selector(breakdownChanged)
        Breakdown.allCases.forEach {
            breakdownPopUp.addItem(ThemedMenuItem(title: $0.title, representedValue: $0.rawValue))
        }
        overviewColumn.addArrangedSubview(sectionHeader(
            title: L10n.string("Breakdown"),
            detail: L10n.string("Models, projects, accounts, and billing routes."),
            control: breakdownPopUp
        ))
        overviewColumn.addArrangedSubview(breakdownTable)

        overviewColumn.addArrangedSubview(sectionHeader(
            title: L10n.string("Data coverage"),
            detail: L10n.string("What Threading could measure, including unsupported and partial sources."),
            control: nil
        ))
        overviewColumn.addArrangedSubview(coverageView)

        limitColumn.addArrangedSubview(sectionHeader(
            title: L10n.string("Limit history"),
            detail: L10n.string("Observed limits, resets, projections, and expiring banked resets."),
            control: limitControls()
        ))
        let limitCardStack = NSStackView(views: limitCards)
        limitCardStack.orientation = .horizontal
        limitCardStack.distribution = .fillEqually
        limitCardStack.spacing = Design.Spacing.medium
        limitColumn.addArrangedSubview(limitCardStack)
        limitColumn.addArrangedSubview(limitChart)

        column.addArrangedSubview(overviewColumn)
        column.addArrangedSubview(limitColumn)

        for view in column.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        [overviewColumn, limitColumn].forEach { content in
            for view in content.arrangedSubviews {
                view.translatesAutoresizingMaskIntoConstraints = false
                view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            }
        }
        breakdownTable.heightAnchor.constraint(
            equalToConstant: Design.UsageDashboard.breakdownHeight
        ).isActive = true
        applyTabVisibility()
    }

    private func select(tab: DashboardTab, animated: Bool) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        applyTabVisibility()

        let incoming = tab == .overview ? overviewColumn : limitColumn
        if animated, !Design.Motion.reducesMotion {
            incoming.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Design.Motion.standard
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                incoming.animator().alphaValue = 1
            }
        } else {
            incoming.alphaValue = 1
        }

        switch tab {
        case .overview: refreshUsage(animated: animated)
        case .limitHistory: refreshLimits(animated: animated)
        }
    }

    private func applyTabVisibility() {
        overviewColumn.isHidden = selectedTab != .overview
        limitColumn.isHidden = selectedTab != .limitHistory
        overviewColumn.alphaValue = selectedTab == .overview ? 1 : 0
        limitColumn.alphaValue = selectedTab == .limitHistory ? 1 : 0
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func limitControls() -> NSView {
        limitChooser.target = self
        limitChooser.action = #selector(limitChanged)
        limitChooser.setAccessibilityLabel(L10n.string("Limit window"))

        limitRangeControl.configure(titles: ["7d", "30d", "90d"], selectedIndex: 1)
        limitRangeControl.widthAnchor.constraint(
            equalToConstant: Design.UsageDashboard.rangeControlWidth
        ).isActive = true
        limitRangeControl.setAccessibilityLabel(L10n.string("Limit history date range"))
        limitRangeControl.onSelect = { [weak self] index in
            self?.selectedLimitDays = [7, 30, 90][index]
            self?.refreshLimits(animated: true)
        }

        let controls = NSStackView(views: [limitChooser, limitRangeControl])
        controls.orientation = .horizontal
        controls.spacing = Design.Spacing.medium
        return controls
    }

    private func sectionHeader(title: String, detail: String, control: NSView?) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.applyFont(.heading)
        titleField.textColor = Design.Text.label
        let detailField = NSTextField(labelWithString: detail)
        detailField.applyFont(.subheading)
        detailField.textColor = Design.Text.secondary
        detailField.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // A compound control is itself a stack view. Without an explicit outer spacer AppKit
        // may give that nested stack the spare width while leaving its arranged controls at the
        // leading edge, which makes a nominally trailing toolbar hover in the middle of a wide
        // dashboard. Let one inert view own all surplus width so every header action has a real,
        // stable trailing anchor across materials.
        let arrangedViews: [NSView]
        if let control {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            arrangedViews = [labels, spacer, control]
        } else {
            arrangedViews = [labels]
        }

        let row = NSStackView(views: arrangedViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        return row
    }

    @objc private func breakdownChanged() {
        guard let raw = breakdownPopUp.selectedItem?.representedValue as? Int,
              let value = Breakdown(rawValue: raw) else { return }
        selectedBreakdown = value
        refreshBreakdown()
    }

    @objc private func limitChanged() {
        selectedLimitID = limitChooser.selectedItem?.representedValue as? String
        refreshLimits(animated: true)
    }

    private func configureLimitChooser() {
        let oldID = selectedLimitID
        limitChooser.removeAllItems()
        for item in limits {
            limitChooser.addItem(ThemedMenuItem(title: item.title, representedValue: item.id))
        }
        if let oldID, let index = limits.firstIndex(where: { $0.id == oldID }) {
            limitChooser.selectItem(at: index)
        }
        limitChooser.isEnabled = !limits.isEmpty
    }

    private func refreshUsage(animated: Bool) {
        guard let report else {
            let status = isBuilding ? L10n.string("Reading usage sources…") : L10n.string("No usage recorded yet")
            consumptionHero.show(
                metric: selectedMetric == .cost ? L10n.string("Total cost") : L10n.string("Processed tokens"),
                value: "—",
                scope: status,
                quality: "",
                tools: [],
                remainingToolCount: 0
            )
            let titles = [
                L10n.string("Processed tokens"), L10n.string("Cached input"),
                L10n.string("Uncached input"), L10n.string("Output"),
                L10n.string("Cache saved")
            ]
            for (card, title) in zip(metricCards, titles) {
                card.show(title: title, value: "—", detail: status)
            }
            usageChart.setModel(.init(
                title: L10n.string("Daily usage"),
                accessibilitySummary: status,
                series: [],
                emptyMessage: status
            ), animated: false)
            breakdownTable.show([])
            coverageView.show(defaultCoverage())
            return
        }

        let selection = report.selection(days: selectedDays)
        let rankedProviders = rankedProviders(in: selection)
        let metricTotal = selectedMetric == .cost
            ? selection.cost.totalUSD
            : Double(selection.tokens.processed)
        let heroTools = rankedProviders.prefix(3).map { provider in
            let value = selectedMetric == .cost
                ? provider.costUSD
                : Double(provider.tokens.processed)
            let styleIndex = selection.providers.firstIndex { $0.origin == provider.origin } ?? 0
            return UsageToolSummary(
                title: provider.origin.seriesName,
                value: selectedMetric == .cost
                    ? currency(value)
                    : UsageFormat.tokens(Int64(value.rounded())),
                share: metricTotal > 0 ? value / metricTotal : 0,
                style: .categorical(styleIndex)
            )
        }
        consumptionHero.show(
            metric: selectedMetric == .cost ? L10n.string("Total cost") : L10n.string("Processed tokens"),
            value: selectedMetric == .cost
                ? currency(selection.cost.totalUSD)
                : UsageFormat.tokens(selection.tokens.processed),
            scope: L10n.format(
                "%lld days · %lld requests",
                Int64(selection.range),
                Int64(selection.records)
            ),
            quality: selection.cost.unpricedTokens > 0
                ? L10n.format("* %@ remain unpriced", UsageFormat.tokens(selection.cost.unpricedTokens))
                : L10n.string("Provider-reported + official catalog rates"),
            tools: heroTools,
            remainingToolCount: max(0, rankedProviders.count - heroTools.count)
        )

        metricCards[0].show(
            title: L10n.string("Processed tokens"),
            value: UsageFormat.tokens(selection.tokens.processed),
            detail: L10n.format("%lld active days", Int64(selection.days.count))
        )
        let observedInput = selection.tokens.uncachedInput
            + selection.tokens.cachedInput
            + selection.tokens.cacheWrite
        let cachedShare = observedInput > 0
            ? Double(selection.tokens.cachedInput) / Double(observedInput)
            : 0
        metricCards[1].show(
            title: L10n.string("Cached input"),
            value: UsageFormat.tokens(selection.tokens.cachedInput),
            detail: L10n.format("%@ of observed input", percent(cachedShare))
        )
        metricCards[2].show(
            title: L10n.string("Uncached input"),
            value: UsageFormat.tokens(selection.tokens.uncachedInput),
            detail: L10n.format("%@ cache writes", UsageFormat.tokens(selection.tokens.cacheWrite))
        )
        metricCards[3].show(
            title: L10n.string("Output"),
            value: UsageFormat.tokens(selection.tokens.output),
            detail: L10n.format("%@ reasoning", UsageFormat.tokens(selection.tokens.reasoning))
        )
        let savingsMultiple = selection.cost.totalUSD > 0
            ? selection.cost.cacheSavingsUSD / selection.cost.totalUSD
            : 0
        metricCards[4].show(
            title: L10n.string("Cache saved"),
            value: currency(selection.cost.cacheSavingsUSD),
            detail: L10n.format("%@× measured cost", savingsMultiple.formatted(.number.precision(.fractionLength(1))))
        )

        usageChart.setModel(chartModel(selection), animated: animated)
        refreshBreakdown()
        coverageView.show(report.coverage)
    }

    private func chartModel(_ selection: UsageReportSelection) -> ThemedChartModel {
        let ranked = rankedProviders(in: selection)
        let leaders = Array(ranked.prefix(3))
        let remaining = Array(ranked.dropFirst(leaders.count))
        let routes: [(id: String, title: String, origins: Set<UsageOrigin>, style: ThemedChartSeriesStyle)]
            = leaders.map { provider in
                (
                    id: provider.origin.seriesID,
                    title: provider.origin.seriesName,
                    origins: [provider.origin],
                    style: .categorical(
                        selection.providers.firstIndex { $0.origin == provider.origin } ?? 0
                    )
                )
            } + (remaining.isEmpty ? [] : [(
                id: "usage|other",
                title: L10n.string("Other"),
                origins: Set(remaining.map(\.origin)),
                style: .categorical(selection.providers.count)
            )])

        let dailyByOrigin = Dictionary(grouping: selection.daily, by: \.origin).mapValues { days in
            Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        }
        let calendar = Calendar.autoupdatingCurrent
        var days: [Date] = []
        days.reserveCapacity(selection.range)
        var day = selection.start
        while day < selection.end, days.count < selection.range {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? selection.end
        }

        let series = routes.map { route in
            let points = days.map { day in
                let value = route.origins.reduce(0.0) { total, origin in
                    guard let daily = dailyByOrigin[origin]?[day] else { return total }
                    return total + (selectedMetric == .cost
                        ? daily.costUSD
                        : Double(daily.tokens.processed))
                }
                return ThemedChartPoint(
                    at: day,
                    value: value,
                    label: selectedMetric == .cost
                        ? currency(value)
                        : UsageFormat.tokens(Int64(value.rounded())),
                    detail: route.title
                )
            }
            return ThemedChartSeries(
                id: route.id,
                title: route.title,
                points: points,
                style: route.style,
                fillsArea: true,
                curve: .smooth
            )
        }
        let summary = selectedMetric == .cost
            ? L10n.format("%@ total over %lld days", currency(selection.cost.totalUSD), Int64(selection.range))
            : L10n.format("%@ total over %lld days", UsageFormat.tokens(selection.tokens.processed), Int64(selection.range))
        return ThemedChartModel(
            title: selectedMetric == .cost ? L10n.string("Daily cost") : L10n.string("Daily tokens"),
            accessibilitySummary: summary,
            series: series,
            xRange: selection.start...selection.end,
            valueFormat: selectedMetric == .cost ? .currency : .tokens
        )
    }

    private func rankedProviders(
        in selection: UsageReportSelection
    ) -> [UsageReportSelection.Provider] {
        selection.providers.sorted { old, new in
            let oldValue = selectedMetric == .cost
                ? old.costUSD : Double(old.tokens.processed)
            let newValue = selectedMetric == .cost
                ? new.costUSD : Double(new.tokens.processed)
            if oldValue != newValue { return oldValue > newValue }
            return old.origin.seriesName < new.origin.seriesName
        }
    }

    private func refreshBreakdown() {
        guard let selection = report?.selection(days: selectedDays) else {
            breakdownTable.show([])
            return
        }
        let rows: [UsageBreakdownRow]
        switch selectedBreakdown {
        case .models:
            rows = selection.models.map { row(name: $0.name, tokens: $0.tokens.processed, cost: $0.costUSD, records: $0.records) }
        case .accounts:
            rows = selection.accounts.map { row(name: $0.name, tokens: $0.tokens.processed, cost: $0.costUSD, records: $0.records) }
        case .projects:
            rows = selection.checkouts.map { row(name: $0.label, tokens: $0.billedTokens, cost: $0.costUSD, records: $0.turns) }
        case .providers:
            rows = selection.providers.map {
                row(name: $0.origin.seriesName, tokens: $0.tokens.processed, cost: $0.costUSD, records: $0.records)
            }
        }
        breakdownTable.show(rows)
    }

    private func row(name: String, tokens: Int64, cost: Double, records: Int) -> UsageBreakdownRow {
        UsageBreakdownRow(
            title: name,
            detail: L10n.format("%@ · %lld requests", UsageFormat.tokens(tokens), Int64(records)),
            value: selectedMetric == .cost ? currency(cost) : UsageFormat.tokens(tokens)
        )
    }

    private func refreshLimits(animated: Bool) {
        guard let selected = limits.first(where: { $0.id == selectedLimitID }) else {
            for (index, card) in limitCards.enumerated() {
                let titles = [
                    L10n.string("Current"), L10n.string("Projected 100%"),
                    L10n.string("Recorded resets"), L10n.string("Banked reset")
                ]
                card.show(
                    title: titles[index],
                    value: "—",
                    detail: L10n.string("Claude and Codex publish authoritative windows")
                )
            }
            limitChart.setModel(.init(
                title: L10n.string("Limit history"),
                accessibilitySummary: L10n.string("No authoritative limit history yet"),
                series: [],
                valueFormat: .percent,
                emptyMessage: L10n.string("No authoritative limit history yet")
            ), animated: false)
            return
        }

        let now = Date()
        let start = now.addingTimeInterval(TimeInterval(-selectedLimitDays) * 86_400)
        let observed = UsageLimitHistoryAnalysis.downsample(
            selected.samples.filter { $0.at >= start && $0.at <= now }
        )
        let segmented = UsageLimitHistoryAnalysis.segmented(observed)
        var chartSeries = [ThemedChartSeries(
            id: selected.id,
            title: selected.windowLabel,
            points: segmented.map {
                ThemedChartPoint(
                    at: $0.sample.at,
                    value: $0.sample.fraction,
                    label: "\(Int(($0.sample.fraction * 100).rounded()))%",
                    detail: selected.accountName,
                    segment: $0.segment
                )
            },
            style: .primary,
            fillsArea: true
        )]

        if let projection = selected.projection {
            chartSeries.append(ThemedChartSeries(
                id: selected.id + "|projection",
                title: L10n.string("Projection"),
                points: [
                    ThemedChartPoint(at: projection.observedAt, value: projection.observedFraction),
                    ThemedChartPoint(at: projection.endpointAt, value: projection.endpointFraction)
                ],
                style: .projection,
                curve: .linear
            ))
        }

        let resets = selected.resets.filter { $0.detectedAt >= start }
        let chartResets = evenlySpaced(
            resets,
            maximumCount: Design.Chart.maximumRenderedMarkers - 2
        )
        var markers = chartResets.map {
            ThemedChartMarker(
                id: $0.id,
                at: $0.detectedAt,
                title: $0.cause == .bankedCredit ? L10n.string("Banked reset") : L10n.string("Reset"),
                detail: L10n.format("%@ restored", percent($0.restoredFraction)),
                kind: .reset
            )
        }
        if let expiry = selected.nextResetCreditExpiresAt, expiry >= start {
            markers.append(ThemedChartMarker(
                id: selected.id + "|expiry",
                at: expiry,
                title: L10n.string("Banked reset expires"),
                detail: nil,
                kind: .expiry
            ))
        }
        if let exhaustion = selected.projection?.projectedExhaustionAt {
            markers.append(ThemedChartMarker(
                id: selected.id + "|exhaustion",
                at: exhaustion,
                title: L10n.string("Projected 100%"),
                detail: nil,
                kind: .projection
            ))
        }

        let chartEnd = [
            now,
            selected.projection?.endpointAt,
            selected.resetsAt,
            selected.nextResetCreditExpiresAt
        ].compactMap { $0 }.max() ?? now
        limitChart.setModel(ThemedChartModel(
            title: selected.title,
            accessibilitySummary: L10n.format("%@ is at %@", selected.windowLabel, selected.currentFraction.map(percent) ?? "—"),
            series: chartSeries,
            markers: markers,
            xRange: start...chartEnd,
            yRange: 0...1,
            valueFormat: .percent
        ), animated: animated)

        let projected: String
        let projectedDetail: String
        if let exhaustion = selected.projection?.projectedExhaustionAt {
            projected = relative(exhaustion)
            projectedDetail = L10n.string("At the observed weekly pace")
        } else if let fraction = selected.projection?.projectedFractionAtReset {
            projected = percent(fraction)
            projectedDetail = L10n.string("Projected at the scheduled reset")
        } else {
            projected = "—"
            projectedDetail = L10n.string("More observations needed")
        }

        let pace = resets.reduce(0) { $0 + $1.paceGainFraction }
        limitCards[0].show(
            title: L10n.string("Current"),
            value: selected.currentFraction.map(percent) ?? "—",
            detail: selected.resetsAt.map { L10n.format("Resets %@", relative($0)) }
                ?? L10n.string("Reset time unavailable")
        )
        limitCards[1].show(title: L10n.string("Projected 100%"), value: projected, detail: projectedDetail)
        limitCards[2].show(
            title: L10n.string("Recorded resets"),
            value: resets.count.formatted(),
            detail: pace > 0 ? L10n.format("%@ pace restored", percent(pace)) : L10n.string("Observed reset boundaries")
        )
        limitCards[3].show(
            title: L10n.string("Banked reset"),
            value: selected.resetCreditCount.map(String.init) ?? "—",
            detail: selected.nextResetCreditExpiresAt.map {
                L10n.format("Next expires %@", relative($0))
            } ?? L10n.string("No expiry reported")
        )
    }

    private func defaultCoverage() -> [UsageSourceCoverage] {
        [
            .init(runtimeID: "claude", runtimeName: "Claude Code", state: .unavailable, sourceCount: 0, recordCount: 0, detail: "No transcript source was found."),
            .init(runtimeID: "codex", runtimeName: "Codex", state: .unavailable, sourceCount: 0, recordCount: 0, detail: "No rollout source was found."),
            .init(runtimeID: "grok", runtimeName: "Grok", state: .partial, sourceCount: 0, recordCount: 0, detail: GrokUsageAdapter.coverageDetail),
            .init(runtimeID: "opencode", runtimeName: "OpenCode", state: .unavailable, sourceCount: 0, recordCount: 0, detail: "No supported export was found."),
            .init(runtimeID: "openrouter", runtimeName: "OpenRouter via OpenCode", state: .unavailable, sourceCount: 0, recordCount: 0, detail: "Measured through supported OpenCode exports.")
        ]
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func relative(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func evenlySpaced<Element>(_ values: [Element], maximumCount: Int) -> [Element] {
        guard maximumCount > 0, values.count > maximumCount else { return values }
        guard maximumCount > 1 else { return [values[values.count / 2]] }

        let last = values.count - 1
        return (0..<maximumCount).map { position in
            let index = Int(
                (Double(position) * Double(last) / Double(maximumCount - 1)).rounded()
            )
            return values[index]
        }
    }
}

// MARK: - Metric cards

private final class UsageMetricCardView: NSView, ThemedComponent {
    private let titleField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)

        titleField.applyFont(.caption)
        titleField.textColor = Design.Text.secondary
        valueField.applyFont(.numericBody)
        valueField.textColor = Design.Text.label
        detailField.applyFont(.detail())
        detailField.textColor = Design.Text.tertiary
        detailField.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleField, valueField, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Design.UsageDashboard.metricCardHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(title: String, value: String, detail: String) {
        titleField.stringValue = title
        valueField.stringValue = value
        detailField.stringValue = detail
        setAccessibilityLabel(title)
        setAccessibilityValue("\(value), \(detail)")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
    }
}

// MARK: - Consumption hero

private struct UsageToolSummary {
    let title: String
    let value: String
    let share: Double
    let style: ThemedChartSeriesStyle
}

/// The page's visual anchor: one legible total and the leading tools that compose it. System
/// chrome deliberately leaves this open on the page like a native analytics sidebar; authored
/// chromes may state a panel and border around the same semantic content.
private final class UsageConsumptionHeroView: NSView, ThemedComponent {
    private let metricField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private let scopeField = NSTextField(labelWithString: "")
    private let qualityField = NSTextField(labelWithString: "")
    private let toolsField = NSTextField(labelWithString: "")
    private let toolsStack = NSStackView()
    private let remainderField = NSTextField(labelWithString: "")

    var toolCount: Int { toolsStack.arrangedSubviews.count }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        metricField.applyFont(.caption)
        metricField.textColor = Design.Text.secondary
        valueField.applyFont(.numericDisplay)
        valueField.textColor = Design.Text.label
        valueField.lineBreakMode = .byTruncatingTail
        scopeField.applyFont(.subheading)
        scopeField.textColor = Design.Text.secondary
        qualityField.applyFont(.detail())
        qualityField.textColor = Design.Text.tertiary
        qualityField.lineBreakMode = .byTruncatingTail
        toolsField.applyFont(.caption)
        toolsField.textColor = Design.Text.secondary
        toolsField.stringValue = L10n.string("Top tools")
        remainderField.applyFont(.detail())
        remainderField.textColor = Design.Text.tertiary

        let total = NSStackView(views: [metricField, valueField, scopeField, qualityField])
        total.orientation = .vertical
        total.alignment = .leading
        total.spacing = Design.Spacing.hairline
        toolsStack.orientation = .vertical
        toolsStack.alignment = .leading
        toolsStack.spacing = Design.Spacing.small
        let content = NSStackView(views: [total, toolsField, toolsStack, remainderField])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Design.Spacing.medium
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.inset),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Design.Spacing.inset),
            valueField.widthAnchor.constraint(equalTo: content.widthAnchor),
            qualityField.widthAnchor.constraint(equalTo: content.widthAnchor),
            toolsStack.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(
        metric: String,
        value: String,
        scope: String,
        quality: String,
        tools: [UsageToolSummary],
        remainingToolCount: Int
    ) {
        metricField.stringValue = metric
        valueField.stringValue = value
        scopeField.stringValue = scope
        qualityField.stringValue = quality
        toolsStack.arrangedSubviews.forEach {
            toolsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for tool in tools.prefix(3) {
            let row = UsageToolShareRowView(tool)
            toolsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: toolsStack.widthAnchor).isActive = true
        }
        remainderField.stringValue = remainingToolCount > 0
            ? L10n.format("+%lld more included in total", Int64(remainingToolCount))
            : ""
        remainderField.isHidden = remainingToolCount == 0
        setAccessibilityLabel(metric)
        setAccessibilityValue("\(value), \(scope), \(quality)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !AppThemePalette.current.isSystem else { return }
        _ = ThemedSurface.draw(
            bounds,
            fill: Design.Surface.panel,
            border: Design.Surface.border,
            radius: Design.Radius.panel,
            borderWidth: Design.Radius.border
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
    }
}

private final class UsageToolShareRowView: NSView, ThemedComponent {
    private let style: ThemedChartSeriesStyle
    private let share: Double

    init(_ item: UsageToolSummary) {
        style = item.style
        share = min(max(item.share, 0), 1)
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: item.title)
        title.applyFont(.detail(weight: .medium))
        title.textColor = Design.Text.label
        title.lineBreakMode = .byTruncatingTail
        let value = NSTextField(labelWithString: item.value)
        value.applyFont(.numericDetail(weight: .medium))
        value.textColor = Design.Text.secondary
        value.alignment = .right
        let labels = NSStackView(views: [title, value])
        labels.orientation = .horizontal
        labels.distribution = .fill
        labels.spacing = Design.Spacing.small
        let row = NSStackView(views: [labels, UsageToolShareBar(style: style, share: share)])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = Design.Spacing.hairline
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            labels.widthAnchor.constraint(equalTo: row.widthAnchor)
        ])
        setAccessibilityLabel(item.title)
        setAccessibilityValue(L10n.format(
            "%@, %lld%%",
            item.value,
            Int64((share * 100).rounded())
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class UsageToolShareBar: NSView, ThemedComponent {
    private let style: ThemedChartSeriesStyle
    private let share: Double

    init(style: ThemedChartSeriesStyle, share: Double) {
        self.style = style
        self.share = share
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Design.Spacing.tight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = AppThemePalette.current.isSystem ? bounds.height / 2 : Design.Radius.control
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        Design.Surface.controlResting.setFill()
        track.fill()

        var fillRect = bounds
        fillRect.size.width *= CGFloat(share)
        guard fillRect.width > 0 else { return }
        chartColor(style).withAlphaComponent(AppThemePalette.current.isSystem ? 0.72 : 1).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

@MainActor
private func chartColor(_ style: ThemedChartSeriesStyle) -> NSColor {
    Design.Chart.color(for: style)
}

// MARK: - Virtual breakdown table

private struct UsageBreakdownRow {
    let title: String
    let detail: String
    let value: String
}

private final class UsageBreakdownTableView: NSView, ThemedComponent, NSTableViewDataSource, NSTableViewDelegate {
    private static let columnID = NSUserInterfaceItemIdentifier("UsageBreakdownColumn")
    private static let cellID = NSUserInterfaceItemIdentifier("UsageBreakdownCell")
    private let scrollView = ThemedScrollView()
    private let table = ThemedTableView()
    private var rows: [UsageBreakdownRow] = []

    var visibleCellCount: Int { table.visibleRect.isEmpty ? 0 : table.rows(in: table.visibleRect).length }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)

        let column = NSTableColumn(identifier: Self.columnID)
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Design.UsageDashboard.breakdownRowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.tight),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.tight),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.tight)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ rows: [UsageBreakdownRow]) {
        self.rows = rows
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self)
            as? UsageBreakdownCellView ?? UsageBreakdownCellView()
        cell.identifier = Self.cellID
        cell.show(rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
    }
}

private final class UsageBreakdownCellView: NSTableCellView, ThemedComponent {
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.applyFont(.body)
        titleField.textColor = Design.Text.label
        titleField.lineBreakMode = .byTruncatingMiddle
        detailField.applyFont(.detail())
        detailField.textColor = Design.Text.tertiary
        valueField.applyFont(.numericBody)
        valueField.textColor = Design.Text.label
        valueField.alignment = .right

        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labels, valueField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ row: UsageBreakdownRow) {
        titleField.stringValue = row.title
        detailField.stringValue = row.detail
        valueField.stringValue = row.value
        setAccessibilityLabel(row.title)
        setAccessibilityValue("\(row.value), \(row.detail)")
    }
}

// MARK: - Coverage

private final class UsageCoverageListView: NSView, ThemedComponent {
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ coverage: [UsageSourceCoverage]) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for source in coverage.prefix(8) {
            let row = UsageCoverageRowView(source)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
    }
}

private final class UsageCoverageRowView: NSView, ThemedComponent {
    init(_ source: UsageSourceCoverage) {
        super.init(frame: .zero)
        let state: String
        let color: NSColor
        switch source.state {
        case .complete: state = L10n.string("Measured"); color = Design.Status.positive
        case .partial: state = L10n.string("Partial"); color = Design.Status.warning
        case .unavailable: state = L10n.string("Unavailable"); color = Design.Text.tertiary
        case .failed: state = L10n.string("Failed"); color = Design.Status.negative
        }

        let title = NSTextField(labelWithString: source.runtimeName)
        title.applyFont(.body)
        title.textColor = Design.Text.label
        let detail = NSTextField(labelWithString: source.detail.map { L10n.string($0) }
            ?? L10n.format("%lld records", Int64(source.recordCount)))
        detail.applyFont(.detail())
        detail.textColor = Design.Text.tertiary
        detail.lineBreakMode = .byTruncatingTail
        let status = NSTextField(labelWithString: state)
        status.applyFont(.control)
        status.textColor = color
        status.alignment = .right

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labels, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Design.UsageDashboard.coverageRowHeight),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityLabel(source.runtimeName)
        setAccessibilityValue("\(state), \(detail.stringValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
