import AppKit
import ThreadingRemoteKit

private extension UsageDashboardMetric {
    var title: String {
        switch self {
        case .cost: return L10n.string("Cost")
        case .tokens: return L10n.string("Tokens")
        }
    }
}

private extension UsageDashboardBreakdownKind {
    var title: String {
        switch self {
        case .models: return L10n.string("Models")
        case .projects: return L10n.string("Projects")
        case .accounts: return L10n.string("Accounts")
        case .providers: return L10n.string("Providers")
        }
    }

    /// What one row is. The chooser names the set, the column names the row — a column headed
    /// "Models" over a single model reads as a count of them.
    var rowTitle: String {
        switch self {
        case .models: return L10n.string("Model")
        case .projects: return L10n.string("Project")
        case .accounts: return L10n.string("Account")
        case .providers: return L10n.string("Provider")
        }
    }
}

// MARK: - Dashboard

/// The retained analysis half of the Usage surface. Its two-state control shows Consumption by
/// default or Limit history on demand; both charts keep their models and selection state in place,
/// so switching sections does not rebuild either tree. All potentially long breakdowns live in a
/// recycling table; provider and coverage rows are bounded by the runtime/route set.
final class UsageDashboardView: NSView, ThemedComponent {
    private typealias Metric = UsageDashboardMetric
    private typealias Breakdown = UsageDashboardBreakdownKind

    enum DashboardSection: Int, CaseIterable {
        case consumption
        case limitHistory

        var title: String {
            switch self {
            case .consumption: return L10n.string("Consumption")
            case .limitHistory: return L10n.string("Limit history")
            }
        }
    }

    private var overview: UsageDashboardOverviewProjection?
    private var limits: [UsageLimitDashboardSeries] = []
    private var isBuilding = false
    private var scanProgress: UsageScanProgress?
    private var selectedDays = 30
    private var selectedMetric = Metric.cost
    private var selectedBreakdown = Breakdown.models
    private var selectedLimitDays = 30
    private var selectedLimitID: String?
    private var selectedDashboardSection = DashboardSection.consumption
    private var hasPresentedUsage = false
    private var hasPresentedLimits = false
    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private let scanStatusLabel = NSTextField(labelWithString: "")
    private let scanProgressBar = ThemedProgressBar()
    private let scanStatus = NSStackView()
    private let dashboardSectionControl = ThemedSegmentedControl()
    private let rangeControl = ThemedSegmentedControl()
    private let metricControl = ThemedSegmentedControl()
    private let consumptionHero = UsageConsumptionHeroView()
    private let usageChart = ThemedStackedBandChartView(frame: .zero)
    private let statBand = UsageStatBandView()
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
        overview: UsageDashboardOverviewProjection?,
        limits: [UsageLimitDashboardSeries],
        isBuilding: Bool,
        scanProgress: UsageScanProgress? = nil,
        animated: Bool
    ) {
        self.overview = overview
        self.limits = limits.sorted { $0.title < $1.title }
        self.isBuilding = isBuilding
        self.scanProgress = scanProgress

        let validIDs = Set(self.limits.map(\.id))
        if selectedLimitID.map({ !validIDs.contains($0) }) ?? true {
            selectedLimitID = self.limits.first?.id
        }
        configureLimitChooser()
        applyScanStatus()
        refreshUsage(animated: animated && hasPresentedUsage)
        refreshLimits(animated: animated && hasPresentedLimits)
        hasPresentedUsage = overview != nil
        hasPresentedLimits = !limits.isEmpty
    }

    /// A scan tick, which arrives many times for one report and changes one line of text and one
    /// bar. It deliberately does not run `update`: rebuilding the hero, five cards, the breakdown
    /// table and the coverage list ten times a second would be a whole-page rebuild per tick, and
    /// none of those surfaces are what the progress is about.
    func updateScanProgress(_ progress: UsageScanProgress?, isBuilding: Bool) {
        scanProgress = progress
        self.isBuilding = isBuilding
        applyScanStatus()
        // With a report on screen the strip above is the whole answer: the chart is showing real
        // numbers, and a status over them would cover the very thing being refreshed.
        guard overview == nil else { return }
        usageChart.setModel(placeholderChartModel(), animated: false)
        showPlaceholderHero()
    }

    /// Whether a rescan is announced beside the consumption controls, and how far it has got.
    private func applyScanStatus() {
        let announces = isBuilding && overview != nil
        scanStatus.isHidden = !announces
        guard announces else { return }
        if let fraction = scanProgress?.fraction {
            scanProgressBar.isHidden = false
            scanProgressBar.progress = fraction
        } else {
            // Still counting the sources. The sentence says the work is happening; a bar at zero
            // would only say how little of an unknown total is done.
            scanProgressBar.isHidden = true
        }
    }

    /// Deterministic fixture compatibility. Production prepares the projection on a utility task
    /// before calling the overload above.
    func update(
        report: TranscriptUsageReport?,
        limits: [UsageLimitDashboardSeries],
        isBuilding: Bool,
        scanProgress: UsageScanProgress? = nil,
        animated: Bool
    ) {
        update(
            overview: report.flatMap { UsageDashboardProjector.overview(report: $0) },
            limits: limits,
            isBuilding: isBuilding,
            scanProgress: scanProgress,
            animated: animated
        )
    }

    var usageRenderedPointCountForTesting: Int { usageChart.renderedPointCount }
    var limitRenderedPointCountForTesting: Int { limitChart.renderedPointCount }
    var limitRenderedMarkerCountForTesting: Int { limitChart.renderedMarkerCount }
    var limitChartXRangeForTesting: ClosedRange<Date>? { limitChart.resolvedXRangeForTesting }
    var usageChartCompositionForTesting: ThemedChartComposition { usageChart.composition }
    var limitChartCompositionForTesting: ThemedChartComposition { limitChart.composition }
    var limitChartModelForTesting: ThemedChartModel { limitChart.model }
    var breakdownVisibleSubviewCountForTesting: Int { breakdownTable.visibleCellCount }
    /// What the Overview chart is saying instead of series, or `nil` when it has some.
    var usagePlaceholderForTesting: ThemedChartPlaceholder? {
        usageChart.showsPlaceholder ? usageChart.model.placeholder : nil
    }
    var usagePlaceholderTitleForTesting: String? {
        usageChart.showsPlaceholder ? usageChart.model.emptyMessage : nil
    }
    var usagePlaceholderDetailForTesting: String? {
        usageChart.showsPlaceholder ? usageChart.model.emptyDetail : nil
    }
    var statBandDetailsForTesting: [String] { statBand.detailsForTesting }
    /// Whether every stat detail line has room for all of its own text.
    ///
    /// The band's details are the page's most truncation-prone slot — a fifth of the width,
    /// holding a sentence — and truncation is invisible to every other assertion here, which is
    /// how `260.2M cache…` shipped.
    var statBandDetailsFitForTesting: Bool { statBand.detailsFitForTesting }
    /// The breakdown's visible column headings, leading to trailing.
    var breakdownColumnTitlesForTesting: [String] { breakdownTable.columnTitlesForTesting }
    /// What the breakdown's columns occupy, and the width they have to fit in.
    var breakdownColumnFitForTesting: (occupied: CGFloat, available: CGFloat) {
        breakdownTable.columnFitForTesting
    }
    var breakdownDebugGeometryForTesting: String { breakdownTable.debugGeometryForTesting }
    /// How many breakdown rows are wearing a provider mark.
    var breakdownProviderMarkCountForTesting: Int { breakdownTable.providerMarkCountForTesting }
    /// The rescan strip beside the consumption controls: whether it is up, and its fraction.
    var scanStripForTesting: (isVisible: Bool, progress: Double?) {
        (!scanStatus.isHidden, scanProgressBar.isHidden ? nil : scanProgressBar.progress)
    }
    var topToolCountForTesting: Int { consumptionHero.toolCount }
    var selectedDashboardSectionForTesting: DashboardSection { selectedDashboardSection }
    var dashboardSectionTitlesForTesting: [String] { dashboardSectionControl.titles }
    var visibleDashboardSectionCountForTesting: Int {
        [overviewColumn, limitColumn].filter { !$0.isHidden }.count
    }
    func selectDashboardSectionForTesting(_ section: DashboardSection) {
        selectDashboardSection(section)
    }
    func selectLimitRangeForTesting(days: Int) {
        guard let index = UsageDashboardProjectionDefaults.overviewRanges.firstIndex(of: days) else {
            return
        }
        limitRangeControl.selectedIndex = index
        selectedLimitDays = days
        refreshLimits(animated: false)
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

        dashboardSectionControl.configure(
            titles: DashboardSection.allCases.map(\.title),
            selectedIndex: selectedDashboardSection.rawValue
        )
        dashboardSectionControl.widthAnchor.constraint(
            equalToConstant: Design.UsageDashboard.sectionControlWidth
        ).isActive = true
        dashboardSectionControl.setAccessibilityLabel(L10n.string("Usage section"))
        dashboardSectionControl.setAccessibilityIdentifier("usage.dashboard.section-picker")
        dashboardSectionControl.onSelect = { [weak self] index in
            guard let section = DashboardSection(rawValue: index) else { return }
            self?.selectDashboardSection(section)
        }
        let sectionControlSpacer = NSView()
        sectionControlSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sectionControlRow = NSStackView(views: [dashboardSectionControl, sectionControlSpacer])
        sectionControlRow.orientation = .horizontal
        sectionControlRow.alignment = .centerY
        sectionControlRow.spacing = Design.Spacing.medium

        // The rescan strip. A page that already has its last complete report on screen says a new
        // scan is running beside the consumption controls rather than in the chart: the chart is
        // showing real numbers and a status over them would cover the thing being refreshed.
        scanStatusLabel.applyFont(.detail())
        scanStatusLabel.textColor = Design.Text.secondary
        scanStatusLabel.stringValue = L10n.string("Reading usage sources…")
        scanProgressBar.setAccessibilityLabel(L10n.string("Reading usage sources…"))
        scanProgressBar.widthAnchor.constraint(
            equalToConstant: Design.UsageDashboard.scanProgressWidth
        ).isActive = true
        scanStatus.orientation = .horizontal
        scanStatus.alignment = .centerY
        scanStatus.spacing = Design.Spacing.small
        scanStatus.addArrangedSubview(scanStatusLabel)
        scanStatus.addArrangedSubview(scanProgressBar)
        scanStatus.isHidden = true

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

        let overviewControls = NSStackView(views: [scanStatus, rangeControl, metricControl])
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
        // The hero is the only fixed column on this row; everything the page's width gains goes
        // to the chart, which is the content. Hugging it below the hero's is what keeps the
        // stack from splitting the surplus between them.
        usageChart.setContentHuggingPriority(.defaultLow, for: .horizontal)
        consumptionHero.setContentHuggingPriority(.required, for: .horizontal)
        let heroRow = NSStackView(views: [consumptionHero, usageChart])
        heroRow.orientation = .horizontal
        heroRow.alignment = .top
        heroRow.distribution = .fill
        heroRow.spacing = Design.Spacing.pane
        overviewColumn.addArrangedSubview(heroRow)
        usageChart.heightAnchor.constraint(
            equalToConstant: Design.UsageDashboard.chartHeight
        ).isActive = true
        consumptionHero.heightAnchor.constraint(equalTo: usageChart.heightAnchor).isActive = true

        overviewColumn.addArrangedSubview(statBand)

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

        column.addArrangedSubview(sectionControlRow)
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
        selectDashboardSection(selectedDashboardSection)
    }

    private func selectDashboardSection(_ section: DashboardSection) {
        selectedDashboardSection = section
        dashboardSectionControl.selectedIndex = section.rawValue
        overviewColumn.isHidden = section != .consumption
        limitColumn.isHidden = section != .limitHistory
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
        guard let range = overview?.range(days: selectedDays) else {
            showPlaceholderHero()
            // The status is said once, in the chart. Repeating it under five dashes made a
            // page whose whole content was one sentence printed six times.
            statBand.show(Self.statTitles.map { .init(title: $0, value: "—", detail: "") })
            usageChart.setModel(placeholderChartModel(), animated: false)
            breakdownTable.show([], subject: selectedBreakdown.rowTitle)
            coverageView.show(defaultCoverage())
            return
        }

        let metric = range.metric(selectedMetric)
        let rankedProviders = metric.providers
        let metricTotal = selectedMetric == .cost
            ? range.cost.totalUSD
            : Double(range.tokens.processed)
        var heroTools = rankedProviders.prefix(3).map { provider in
            let value = selectedMetric == .cost
                ? provider.costUSD
                : Double(provider.tokens.processed)
            return UsageToolSummary(
                title: provider.origin.seriesName,
                value: selectedMetric == .cost
                    ? UsageFormat.currency(value)
                    : UsageFormat.tokens(Int64(value.rounded())),
                share: metricTotal > 0 ? value / metricTotal : 0,
                style: .categorical(provider.styleIndex)
            )
        }
        let remainingProviders = rankedProviders.dropFirst(heroTools.count)
        if !remainingProviders.isEmpty {
            let value = remainingProviders.reduce(0.0) { total, provider in
                total + (selectedMetric == .cost
                    ? provider.costUSD
                    : Double(provider.tokens.processed))
            }
            let styleIndex = metric.chartSeries.first(where: { $0.isOther })?.styleIndex
                ?? rankedProviders.count
            heroTools.append(UsageToolSummary(
                title: L10n.string("Other"),
                value: selectedMetric == .cost
                    ? UsageFormat.currency(value)
                    : UsageFormat.tokens(Int64(value.rounded())),
                share: metricTotal > 0 ? value / metricTotal : 0,
                style: .categorical(styleIndex)
            ))
        }
        consumptionHero.show(
            metric: selectedMetric == .cost ? L10n.string("Total cost") : L10n.string("Processed tokens"),
            value: selectedMetric == .cost
                ? UsageFormat.currency(range.cost.totalUSD)
                : UsageFormat.tokens(range.tokens.processed),
            scope: L10n.format(
                "%lld days · %lld requests",
                Int64(range.days),
                Int64(range.records)
            ),
            quality: range.cost.unpricedTokens > 0
                ? L10n.format("* %@ remain unpriced", UsageFormat.tokens(range.cost.unpricedTokens))
                : L10n.string("Provider-reported + official catalog rates"),
            tools: heroTools,
            remainingToolCount: 0
        )

        let observedInput = range.tokens.uncachedInput
            + range.tokens.cachedInput
            + range.tokens.cacheWrite
        let cachedShare = observedInput > 0
            ? Double(range.tokens.cachedInput) / Double(observedInput)
            : 0
        let savingsMultiple = range.cost.totalUSD > 0
            ? range.cost.cacheSavingsUSD / range.cost.totalUSD
            : 0
        statBand.show([
            .init(
                title: Self.statTitles[0],
                value: UsageFormat.tokens(range.tokens.processed),
                detail: L10n.format("%lld active days", Int64(range.activeDayCount))
            ),
            .init(
                title: Self.statTitles[1],
                value: UsageFormat.tokens(range.tokens.cachedInput),
                detail: L10n.format("%@ of observed input", UsageFormat.share(cachedShare))
            ),
            .init(
                title: Self.statTitles[2],
                value: UsageFormat.tokens(range.tokens.uncachedInput),
                detail: L10n.format("%@ cache writes", UsageFormat.tokens(range.tokens.cacheWrite))
            ),
            .init(
                title: Self.statTitles[3],
                value: UsageFormat.tokens(range.tokens.output),
                detail: L10n.format("%@ reasoning", UsageFormat.tokens(range.tokens.reasoning))
            ),
            // A fifth of a fixed-width band is not a slot for `$3,503,525.25`, and the exact
            // figure is not what this one is for: it is read against the total beside it.
            .init(
                title: Self.statTitles[4],
                value: UsageFormat.compactCurrency(range.cost.cacheSavingsUSD),
                detail: L10n.format(
                    "%@× measured cost",
                    savingsMultiple.formatted(.number.precision(.fractionLength(1)))
                )
            )
        ])

        usageChart.setModel(chartModel(range), animated: animated)
        refreshBreakdown()
        coverageView.show(overview?.coverage ?? [])
    }

    // MARK: - Nothing to plot yet

    /// What the page says before it has numbers, in the two states that are not the same thing:
    /// a scan in flight, and a scan that found nothing.
    ///
    /// The second one used to say "No usage recorded yet" and stop, which answers none of the
    /// questions somebody looking at an empty dashboard actually has.
    private var usagePlaceholder: (state: ThemedChartPlaceholder, title: String, detail: String?) {
        guard isBuilding else {
            return (
                .empty,
                L10n.string("No usage recorded yet"),
                L10n.string("Cost and tokens appear here once an agent session has run.")
            )
        }
        let title = L10n.string("Reading usage sources…")
        guard let progress = scanProgress, progress.totalSources > 0 else {
            // Enumeration is the one phase with no denominator to report: the transcripts are
            // still being counted.
            return (.loading(progress: nil), title, L10n.string("Looking for local transcripts."))
        }
        let read = L10n.format("%lld sources read", Int64(progress.completedSources))
        return (
            .loading(progress: progress.fraction),
            title,
            progress.sourceName.map { L10n.format("%@ · %@", $0, read) } ?? read
        )
    }

    /// The hero with no total to lead on: its metric name, a dash, and nothing else.
    ///
    /// The status is said once, in the chart immediately to its right. The two sit on the same
    /// row, so a hero repeating the sentence beside it printed the page's only content twice
    /// within an inch of itself.
    private func showPlaceholderHero() {
        consumptionHero.show(
            metric: selectedMetric == .cost
                ? L10n.string("Total cost")
                : L10n.string("Processed tokens"),
            value: "—",
            scope: "",
            quality: "",
            tools: [],
            remainingToolCount: 0
        )
    }

    private func placeholderChartModel() -> ThemedChartModel {
        let placeholder = usagePlaceholder
        return ThemedChartModel(
            title: L10n.string("Daily usage"),
            accessibilitySummary: [placeholder.title, placeholder.detail]
                .compactMap { $0 }
                .joined(separator: ". "),
            series: [],
            valueGridLineCount: Design.UsageDashboard.chartGridLineCount,
            emptyMessage: placeholder.title,
            emptyDetail: placeholder.detail,
            placeholder: placeholder.state
        )
    }

    private func chartModel(_ range: UsageDashboardRangeProjection) -> ThemedChartModel {
        let series = range.metric(selectedMetric).chartSeries.map { projected in
            let title = projected.isOther ? L10n.string("Other") : (projected.title ?? "")
            return ThemedChartSeries(
                id: projected.id,
                title: title,
                points: projected.points.map { point in
                    ThemedChartPoint(
                    at: point.at,
                    value: point.value,
                    label: selectedMetric == .cost
                        ? UsageFormat.currency(point.value)
                        : UsageFormat.tokens(Int64(point.value.rounded())),
                    detail: title
                )
                },
                style: .categorical(projected.styleIndex),
                fillsArea: true,
                curve: .smooth
            )
        }
        let summary = selectedMetric == .cost
            ? L10n.format(
                "%@ total over %lld days",
                UsageFormat.currency(range.cost.totalUSD),
                Int64(range.days)
            )
            : L10n.format("%@ total over %lld days", UsageFormat.tokens(range.tokens.processed), Int64(range.days))
        return ThemedChartModel(
            title: selectedMetric == .cost ? L10n.string("Daily cost") : L10n.string("Daily tokens"),
            accessibilitySummary: summary,
            series: series,
            markers: overview.map { snapshot in
                [ThemedChartMarker(
                    id: "usage|now",
                    at: min(max(snapshot.builtAt, range.start), range.end),
                    title: L10n.string("Now"),
                    detail: L10n.string("Current day is incomplete"),
                    kind: .now
                )]
            } ?? [],
            xRange: range.start...range.end,
            valueFormat: selectedMetric == .cost ? .currency : .tokens,
            valueGridLineCount: Design.UsageDashboard.chartGridLineCount,
            showsLegend: true
        )
    }

    private func refreshBreakdown() {
        let subject = selectedBreakdown.rowTitle
        guard let range = overview?.range(days: selectedDays) else {
            breakdownTable.show([], subject: subject)
            return
        }
        let breakdown = range.breakdown(selectedBreakdown)
        // Share is of whichever metric the page is currently reading, so the column answers the
        // question the rest of the page is answering rather than a second, silent one.
        let total = selectedMetric == .cost
            ? range.cost.totalUSD
            : Double(range.tokens.processed)
        var rows = breakdown.rows.map {
            row(
                name: $0.title,
                runtimeID: $0.runtimeID,
                tokens: $0.tokens,
                cost: $0.costUSD,
                records: $0.records,
                total: total
            )
        }
        if breakdown.omittedRowCount > 0 {
            rows.append(row(
                name: L10n.format(
                    "+%lld more included in total",
                    Int64(breakdown.omittedRowCount)
                ),
                runtimeID: nil,
                tokens: breakdown.omittedTokens,
                cost: breakdown.omittedCostUSD,
                records: breakdown.omittedRecords,
                total: total
            ))
        }
        breakdownTable.show(rows, subject: subject)
    }

    private func row(
        name: String,
        runtimeID: String?,
        tokens: Int64,
        cost: Double,
        records: Int,
        total: Double
    ) -> UsageBreakdownRow {
        let value = selectedMetric == .cost ? cost : Double(tokens)
        return UsageBreakdownRow(
            title: name,
            runtimeID: runtimeID,
            cost: UsageFormat.currency(cost),
            share: UsageFormat.share(total > 0 ? value / total : 0),
            tokens: UsageFormat.tokens(tokens),
            requests: records.formatted()
        )
    }

    private func refreshLimits(animated: Bool) {
        guard let selected = limits.first(where: { $0.id == selectedLimitID }) else {
            for (index, card) in limitCards.enumerated() {
                let titles = [
                    L10n.string("Current"), L10n.string("Projected 100%"),
                    L10n.string("Recorded resets"), L10n.string("Banked resets")
                ]
                card.show(title: titles[index], value: "—", detail: "")
            }
            let detail = L10n.string("Claude and Codex publish authoritative windows")
            let title = L10n.string("No authoritative limit history yet")
            limitChart.setModel(.init(
                title: L10n.string("Limit history"),
                accessibilitySummary: [title, detail].joined(separator: ". "),
                series: [],
                valueFormat: .percent,
                emptyMessage: title,
                emptyDetail: detail
            ), animated: false)
            return
        }

        guard let range = selected.range(days: selectedLimitDays) else { return }
        let now = range.end
        let start = range.start
        // The same decision the phone makes over the same observations: a line while the window
        // cycles seldom enough to be read as one, columns of the highest reading per bucket once
        // it does not. A five-hour window over a month was a block of near-vertical strokes
        // under forty-eight dashed reset rules.
        let form = UsageLimitChartForm.resolve(
            span: now.timeIntervalSince(start),
            windowDuration: selected.windowDuration,
            observedCycles: max((range.observed.last?.segment ?? 0) + 1, range.resetCount + 1)
        )
        var chartSeries: [ThemedChartSeries] = []
        var ruledResets = range.resetMarkers
        switch form {
        case .line:
            chartSeries.append(ThemedChartSeries(
                id: selected.id,
                title: selected.windowLabel,
                points: range.observed.map {
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
            ))
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
        case .peaks(let bucket):
            chartSeries = peakSeries(for: selected, range: range, bucket: bucket)
            // A window that resets every five hours resets every five hours: only the rarer
            // banked-credit reset stays ruled, and the count stands in the card below.
            ruledResets = range.resetMarkers.filter { $0.cause == .bankedCredit }
        }

        var markers = ruledResets.map {
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

        // The user's own line on this window, drawn as a level the series is read against.
        // Resolved from the series key rather than carried on the row: the key is the one place
        // that already knows which account and window a series belongs to.
        var valueRules: [ThemedChartValueRule] = []
        if let parts = UsageHistoryStore.seriesKeyParts(selected.id),
           let accountID = AccountID(rawValue: parts.accountID),
           let rule = CustomLimitBounds.tightest(
               on: parts.windowID,
               in: CustomLimitSettings.shared.rules(for: accountID)
           ),
           let bound = CustomLimitBounds.resolvedBound(of: rule, window: nil, at: now) {
            // A fixed cap only: a pace share's line moves with the clock, so drawing it as one
            // horizontal rule across a week of history would be a line that was never there.
            valueRules.append(ThemedChartValueRule(
                id: selected.id + "|cap",
                value: bound,
                title: L10n.format("Your limit · %@", percent(bound)),
                kind: .cap
            ))
        }

        // A future projection or the scheduled reset is part of the active window and may extend
        // the plot. Banked-reset inventory is not: its next expiry can be weeks later than the
        // selected history and already has a complete answer in the summary card below. Letting
        // that date set the domain compresses the observed week into an unreadable sliver.
        let chartEnd = [
            now,
            selected.projection?.endpointAt,
            selected.resetsAt
        ].compactMap { $0 }.max() ?? now
        limitChart.setModel(ThemedChartModel(
            title: selected.title,
            accessibilitySummary: L10n.format("%@ is at %@", selected.windowLabel, selected.currentFraction.map(percent) ?? "—"),
            series: chartSeries,
            markers: markers,
            valueRules: valueRules,
            xRange: start...chartEnd,
            yRange: 0...1,
            valueFormat: .percent,
            showsLegend: true
        ), animated: animated)

        let projectedTitle: String
        let projected: String
        let projectedDetail: String
        if let exhaustion = selected.projection?.projectedExhaustionAt {
            projectedTitle = L10n.string("Projected 100%")
            projected = relative(exhaustion)
            projectedDetail = L10n.string("At the observed weekly pace")
        } else if let fraction = selected.projection?.projectedFractionAtReset {
            projectedTitle = L10n.string("Projected at reset")
            projected = percent(fraction)
            projectedDetail = L10n.string("Projected at the scheduled reset")
        } else {
            // Only a measured weekly window is projected; a five-hour window has no weekly pace
            // to extrapolate, and asking its reader to wait for more observations would be
            // promising a figure that never comes.
            let isWeekly = selected.windowDuration.map { $0 >= UsageLimitHistoryDefaults.weeklyDurationRange.lowerBound } ?? true
            projectedTitle = L10n.string("Projection")
            projected = "—"
            projectedDetail = isWeekly
                ? L10n.string("More observations needed")
                : L10n.string("Projected for weekly windows only")
        }

        // A reading whose scheduled reset has passed is not a current one: the window ended,
        // and "Resets 2 days ago" was that date read after the window it belonged to was gone.
        if let reset = selected.resetsAt, reset <= now {
            limitCards[0].show(
                title: L10n.string("Current"),
                value: "—",
                detail: L10n.format("Window ended %@ · %@", relative(reset), exactDateTime(reset))
            )
        } else {
            limitCards[0].show(
                title: L10n.string("Current"),
                value: selected.currentFraction.map(percent) ?? "—",
                detail: selected.resetsAt.map {
                    L10n.format("Resets %@ · %@", relative($0), exactDateTime($0))
                }
                    ?? L10n.string("Reset time unavailable")
            )
        }
        limitCards[1].show(title: projectedTitle, value: projected, detail: projectedDetail)
        limitCards[2].show(
            title: L10n.string("Recorded resets"),
            value: range.resetCount.formatted(),
            detail: range.restoredPaceFraction > 0
                ? L10n.format("%@ pace restored", percent(range.restoredPaceFraction))
                : L10n.string("Observed reset boundaries")
        )
        let banked: (value: String, detail: String)
        switch selected.resetCreditCount {
        case nil:
            banked = (L10n.string("Unavailable"), L10n.string("Reset-credit count was not reported"))
        case 0:
            banked = ("0", L10n.string("None available"))
        case let count?:
            let detail = selected.nextResetCreditExpiresAt.map {
                L10n.format("Next expires %@", relative($0))
            } ?? (count == 1
                ? L10n.string("1 reset available · No expiry reported")
                : L10n.format("%lld resets available · No expiry reported", Int64(count)))
            banked = (count.formatted(), detail)
        }
        limitCards[3].show(
            title: L10n.string("Banked resets"),
            value: banked.value,
            detail: banked.detail
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

    /// The five supporting measures, in the order they read: what was processed, what it was
    /// made of, and what caching saved. Stated once so the empty page and the measured one
    /// cannot drift into two different bands.
    private static var statTitles: [String] {
        [
            L10n.string("Processed tokens"),
            L10n.string("Cached input"),
            L10n.string("Uncached input"),
            L10n.string("Output"),
            L10n.string("Cache saved")
        ]
    }

    /// The dense form: one column per bucket at its highest reading, and a second series in
    /// the negative role for the buckets that reached the limit, so the legend keys both. A
    /// series with no columns is left out rather than keyed for nothing.
    private func peakSeries(
        for selected: UsageLimitDashboardSeries,
        range: UsageLimitDashboardRangeProjection,
        bucket: TimeInterval
    ) -> [ThemedChartSeries] {
        let peaks = UsageLimitChartForm.peaks(
            range.observed.map {
                UsageLimitChartObservation(
                    at: $0.sample.at.timeIntervalSince1970,
                    fraction: $0.sample.fraction
                )
            },
            start: range.start.timeIntervalSince1970,
            end: range.end.timeIntervalSince1970,
            bucket: bucket
        )
        func points(_ peaks: [UsageLimitChartForm.Peak]) -> [ThemedChartPoint] {
            peaks.map { peak in
                ThemedChartPoint(
                    at: Date(timeIntervalSince1970: (peak.start + peak.end) / 2),
                    value: peak.fraction,
                    label: percent(peak.fraction),
                    detail: L10n.format("Highest of %lld readings", Int64(peak.observations))
                )
            }
        }
        let ordinary = peaks.filter { !$0.reachedLimit }
        let limited = peaks.filter(\.reachedLimit)
        var series: [ThemedChartSeries] = []
        if !ordinary.isEmpty {
            series.append(ThemedChartSeries(
                id: selected.id + "|peaks",
                title: peakTitle(bucket: bucket),
                points: points(ordinary),
                style: .primary,
                mark: .bar,
                barSpan: bucket
            ))
        }
        if !limited.isEmpty {
            series.append(ThemedChartSeries(
                id: selected.id + "|limit",
                title: L10n.string("Limit reached"),
                points: points(limited),
                style: .negative,
                mark: .bar,
                barSpan: bucket
            ))
        }
        return series
    }

    /// What a column stands for, by the bucket it spans: the window itself, a day, or a span of
    /// days.
    private func peakTitle(bucket: TimeInterval) -> String {
        guard let days = UsageLimitChartForm.bucketDays(bucket) else {
            return L10n.string("Peak per window")
        }
        return days <= 1
            ? L10n.string("Peak per day")
            : L10n.format("Peak per %lld days", Int64(days))
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func relative(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func exactDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

}

// MARK: - Stats band

/// The five supporting measures as one band rather than five bordered tiles.
///
/// The tiles were five plates in a row directly under a chart that is itself a plate, each
/// drawing a border around numbers that are already a group — and each one a fifth of the page
/// wide *inside* its own insets, which is where `260.2M cache…` came from. One container, five
/// columns and a hairline between them says the same thing with a quarter of the ink: the rule
/// separates the measures, and the air around them is what separates the band from the chart.
///
/// System draws no plate here for that reason. An authored chrome states its own surface, the
/// way the hero beside it does — a theme whose identity is heavy borders should not have this
/// one row quietly opt out of them.
private final class UsageStatBandView: NSView, ThemedComponent {
    struct Item {
        let title: String
        let value: String
        let detail: String
    }

    private let columns = (0..<UsageStatBandView.columnCount).map { _ in UsageStatColumnView() }

    /// Five, and it is the band's own fact rather than the caller's: the dividers, the equal
    /// widths and the empty state are all built from it.
    static let columnCount = 5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        var arranged: [NSView] = []
        var dividers: [SeparatorView] = []
        for (index, column) in columns.enumerated() {
            if index > 0 {
                let divider = SeparatorView(.vertical)
                // A hairline keeps its own width, always. Without this the stack has two kinds
                // of view willing to absorb the band's surplus, and it gave all of it to a
                // *rule* — 450 points of divider ink standing where a column should be.
                divider.setContentHuggingPriority(.required, for: .horizontal)
                divider.setContentCompressionResistancePriority(.required, for: .horizontal)
                dividers.append(divider)
                arranged.append(divider)
            }
            arranged.append(column)
        }
        let row = NSStackView(views: arranged)
        row.orientation = .horizontal
        // `.fill` with the columns held equal by constraint, never `.fillEqually`: the latter
        // would hand a hairline the same width as a column.
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Design.UsageDashboard.statBandHeight),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        for column in columns.dropFirst() {
            constraints.append(column.widthAnchor.constraint(equalTo: columns[0].widthAnchor))
        }
        // A horizontal stack aligns its arranged views; it does not stretch them. The columns
        // state their own height against the band; the rules between them stop short of both
        // edges, because a rule run out to the edge stops separating the measures and starts
        // dividing the band itself — and under an authored chrome it collides with the plate's
        // own border.
        for column in columns {
            constraints.append(column.heightAnchor.constraint(equalTo: heightAnchor))
        }
        for divider in dividers {
            constraints.append(divider.heightAnchor.constraint(
                equalTo: heightAnchor,
                constant: -Design.Spacing.inset * 2
            ))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Consumption"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ items: [Item]) {
        for (column, item) in zip(columns, items) { column.show(item) }
    }

    var detailsForTesting: [String] { columns.map(\.detailForTesting) }

    var detailsFitForTesting: Bool { columns.allSatisfy(\.detailFitsForTesting) }

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

private final class UsageStatColumnView: NSView, ThemedComponent {
    private let titleField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleField.applyFont(.caption)
        titleField.textColor = Design.Text.secondary
        valueField.applyFont(.numericBody)
        valueField.textColor = Design.Text.label
        detailField.applyFont(.detail())
        detailField.textColor = Design.Text.tertiary
        // The wide page gives every detail line its whole sentence; the floor cannot, and a
        // tail ellipsis is the honest way to say so.
        detailField.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleField, valueField, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ item: UsageStatBandView.Item) {
        titleField.stringValue = item.title
        valueField.stringValue = item.value
        // Emptied rather than hidden: the three lines keep their places, so the empty page and
        // the measured one are the same band with the same rhythm.
        detailField.stringValue = item.detail
        setAccessibilityLabel(item.title)
        setAccessibilityValue(item.detail.isEmpty ? item.value : "\(item.value), \(item.detail)")
    }

    var detailForTesting: String { detailField.stringValue }

    /// Whether the detail line's own text fits the width it was given. Measured from the string
    /// the label is holding rather than from the constraints that were meant to fit it.
    var detailFitsForTesting: Bool {
        guard !detailField.stringValue.isEmpty else { return true }
        return detailField.attributedStringValue.size().width <= detailField.bounds.width + 0.5
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
        let sideMargins = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset)
        ]
        NSLayoutConstraint.activate(sideMargins + [
            heightAnchor.constraint(equalToConstant: Design.UsageDashboard.metricCardHeight),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        holdAtContentInset(sideMargins)
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
        scopeField.isHidden = scope.isEmpty
        qualityField.stringValue = quality
        qualityField.isHidden = quality.isEmpty
        // A heading over nothing reads as a list that failed to load. With no split to name, the
        // caption goes with it.
        toolsField.isHidden = tools.isEmpty
        toolsStack.arrangedSubviews.forEach {
            toolsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for tool in tools.prefix(4) {
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
    /// The runtime this row can honestly be attributed to, or nil. See
    /// `UsageDashboardBreakdownRowProjection.runtimeID`.
    let runtimeID: String?
    let cost: String
    let share: String
    let tokens: String
    let requests: String
}

/// The ranked breakdown: a named row and four numbers, in columns.
///
/// It was a list of two-line rows with one right-hand figure, which is why a page about how much
/// each model cost could not be read down any of its numbers — the second line carried tokens and
/// requests as prose, and the figure on the right silently changed meaning with the metric
/// control. Columns state each measure once, in a heading, and let the eye run down it.
///
/// Still an `NSTableView`, and still for the reason it always was: a breakdown is externally
/// sized (up to `UsageDashboardProjectionDefaults.maximumBreakdownRows`), so only the visible
/// rows may become views. What is new is that the section stops growing the page after
/// `Design.UsageDashboard.breakdownVisibleRows` and scrolls instead — and hands the rest of a
/// flick back to the page when it reaches its own end, so a pointer crossing the table does not
/// stop the settings page dead.
private final class UsageBreakdownTableView: NSView, ThemedComponent, NSTableViewDataSource, NSTableViewDelegate {

    /// The columns, in reading order. A name reads from the leading edge; a measured quantity
    /// reads from the trailing one, in tabular figures, so the digits line up down the column.
    private enum Column: String, CaseIterable {
        case name
        case cost
        case share
        case tokens
        case requests

        var identifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("UsageBreakdown.\(rawValue)")
        }

        /// Nil for the name column, whose heading is the breakdown's own subject.
        var title: String? {
            switch self {
            case .name: return nil
            case .cost: return L10n.string("Cost")
            case .share: return L10n.string("Share")
            case .tokens: return L10n.string("Tokens")
            case .requests: return L10n.string("Requests")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return Design.UsageDashboard.breakdownNameMinimumWidth
            case .cost: return Design.UsageDashboard.breakdownCostColumnWidth
            case .share: return Design.UsageDashboard.breakdownShareColumnWidth
            case .tokens: return Design.UsageDashboard.breakdownTokensColumnWidth
            case .requests: return Design.UsageDashboard.breakdownRequestsColumnWidth
            }
        }
    }

    private let scrollView = ThemedScrollView()
    private let table = ThemedTableView()
    private var rows: [UsageBreakdownRow] = []
    private var columns: [Column: NSTableColumn] = [:]
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    var visibleCellCount: Int { table.visibleRect.isEmpty ? 0 : table.rows(in: table.visibleRect).length }

    var columnTitlesForTesting: [String] {
        table.tableColumns.filter { !$0.isHidden }.map(\.title)
    }

    var debugGeometryForTesting: String {
        "container=\(bounds.width) scroll=\(scrollView.frame.width)"
            + " clip=\(scrollView.contentView.bounds.width)"
            + " contentSize=\(scrollView.contentSize.width)"
            + " name=\(columns[.name]?.width ?? -1)"
            + " style=\(scrollView.scrollerStyle.rawValue)"
    }

    /// What the columns occupy against what the table can show. The last column hanging outside
    /// the clip is invisible to every other assertion — the heading is simply cut in half.
    ///
    /// Occupied is the greater of the widths' sum and the last heading's drawn trailing edge:
    /// the sum alone passed while `.inset` style laid the same columns out shifted, with the
    /// request column's tail past the clip and nothing left to measure it.
    var columnFitForTesting: (occupied: CGFloat, available: CGFloat) {
        let visible = table.tableColumns.enumerated().filter { !$0.element.isHidden }
        let widths = visible.reduce(0) { $0 + $1.element.width }
        let drawn = visible.last.flatMap { index, _ in
            table.headerView?.headerRect(ofColumn: index).maxX
        } ?? widths
        return (max(widths, drawn), scrollView.contentView.bounds.width)
    }

    var providerMarkCountForTesting: Int {
        rows.filter { $0.runtimeID.flatMap(AgentKind.init(rawValue:)) != nil }.count
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)

        for kind in Column.allCases {
            let column = NSTableColumn(identifier: kind.identifier)
            column.title = kind.title ?? ""
            column.width = kind.width
            column.minWidth = kind.width
            if kind == .name {
                column.maxWidth = .greatestFiniteMagnitude
            } else {
                column.maxWidth = kind.width
                column.headerCell.alignment = .right
            }
            table.addTableColumn(column)
            columns[kind] = column
        }
        table.headerView = ThemedTableHeaderView(frame: NSRect(
            x: 0,
            y: 0,
            width: frameRect.width,
            height: Design.UsageDashboard.breakdownHeaderHeight
        ))
        table.rowHeight = Design.UsageDashboard.breakdownRowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        // Flush, not inset: the automatic style resolves to `.inset` inside a scroll view and
        // lays the header and every row `ThemedTableRowDefaults.systemInsetStylePadding` in
        // from each side — *after* `applyColumnWidths` has fit the columns to the clip, which
        // pushed the last column's tail that far past the table's edge. This table meets the
        // clip exactly, so the columns it fits must be the columns it draws.
        table.style = .plain
        table.dataSource = self
        table.delegate = self

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // The table cannot grow to fit its rows — it is virtualized on purpose — so a gesture
        // that has run it to an end belongs to the page under it. See `VerticalScrollHandoff`.
        scrollView.verticalScrollHandoff = .atContentEnds
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            heightConstraint,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.tight),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.tight),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.tight)
        ])
        applyHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ rows: [UsageBreakdownRow], subject: String) {
        self.rows = rows
        columns[.name]?.title = subject
        table.headerView?.needsDisplay = true
        table.reloadData()
        applyHeight()
    }

    /// As tall as its rows need, up to the page's share of them, and no taller. Below that the
    /// section used to keep a fixed 300 points whether it had three rows or three hundred.
    private func applyHeight() {
        let visible = min(
            max(rows.count, 1),
            Design.UsageDashboard.breakdownVisibleRows
        )
        heightConstraint.constant = Design.UsageDashboard.breakdownHeaderHeight
            + CGFloat(visible) * Design.UsageDashboard.breakdownRowHeight
            + Design.Spacing.tight * 2
    }

    override func layout() {
        super.layout()
        applyColumnWidths()
    }

    /// Again at draw time, which is the pattern `ThemedTableView.fitSoleColumnToWidth` already
    /// uses and for the same reason: a scroll view settles its clip — the width a column may
    /// actually occupy — inside its own tile, which is not finished when the container's
    /// `layout()` runs. Fitting the columns to a width that was one tile out of date is what put
    /// the last column's heading half outside the table.
    override func viewWillDraw() {
        super.viewWillDraw()
        applyColumnWidths()
    }

    /// The name column takes whatever the numbers do not need.
    ///
    /// When even that leaves it under its floor — the pane squeezed to
    /// `Design.UsageDashboard.minimumContentWidth` — the request count stands down rather than
    /// the table growing a horizontal scroller across a page that already scrolls vertically. It
    /// is the least load-bearing of the four (the row's own accessibility value still states it),
    /// and dropping a whole column keeps every remaining number in its own labelled place.
    private func applyColumnWidths() {
        // The clip's own bounds, not `contentSize`: that is the scroll view's *answer* for a
        // frame size, computed from the scroller policy it has not necessarily applied yet.
        let available = scrollView.contentView.bounds.width
        guard available > 0 else { return }
        let measured: [Column] = [.cost, .share, .tokens]
        let fixed = measured.reduce(0) { $0 + $1.width }
        let showsRequests = available - fixed - Column.requests.width
            >= Column.name.width
        if let requests = columns[.requests], requests.isHidden == showsRequests {
            requests.isHidden = !showsRequests
        }
        let occupied = fixed + (showsRequests ? Column.requests.width : 0)
        let name = max(available - occupied, Column.name.width)
        guard let nameColumn = columns[.name], abs(nameColumn.width - name) > 0.5 else { return }
        nameColumn.width = name
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier,
              let kind = Column.allCases.first(where: { $0.identifier == identifier }) else {
            return nil
        }
        let value = rows[row]
        if kind == .name {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self)
                as? UsageBreakdownNameCellView ?? UsageBreakdownNameCellView()
            cell.identifier = identifier
            cell.show(value)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? UsageBreakdownValueCellView ?? UsageBreakdownValueCellView()
        cell.identifier = identifier
        switch kind {
        case .cost: cell.show(value.cost, label: kind.title)
        case .share: cell.show(value.share, label: kind.title)
        case .tokens: cell.show(value.tokens, label: kind.title)
        case .requests, .name: cell.show(value.requests, label: kind.title)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
    }
}

/// The row's subject: the agent's own mark, then the name.
///
/// The mark's slot is fixed whether or not the row has one, so a column holding models from two
/// runtimes and one that cannot be attributed still starts every name on the same line.
private final class UsageBreakdownNameCellView: NSTableCellView, ThemedComponent {
    private let mark = NSImageView()
    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        mark.imageScaling = .scaleProportionallyDown
        mark.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        mark.contentTintColor = Design.Text.secondary
        mark.setAccessibilityElement(false)
        titleField.applyFont(.body)
        titleField.textColor = Design.Text.label
        // Middle rather than tail: a dated model identifier differs from its neighbours at both
        // ends, and a tail ellipsis takes the half that says which one it is.
        titleField.lineBreakMode = .byTruncatingMiddle

        let row = NSStackView(views: [mark, titleField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: Design.UsageDashboard.breakdownIconSlot),
            mark.heightAnchor.constraint(equalToConstant: Design.UsageDashboard.breakdownIconSlot),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ row: UsageBreakdownRow) {
        let kind = row.runtimeID.flatMap(AgentKind.init(rawValue:))
        mark.image = kind?.icon
        titleField.stringValue = row.title
        setAccessibilityLabel(kind.map { "\(row.title), \($0.displayName)" } ?? row.title)
        setAccessibilityValue(L10n.format(
            "%@ · %@ · %@ · %@ requests",
            row.cost,
            row.share,
            row.tokens,
            row.requests
        ))
    }
}

/// One measured quantity, set against the trailing edge in tabular figures.
private final class UsageBreakdownValueCellView: NSTableCellView, ThemedComponent {
    private let valueField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueField.applyFont(.numericBody)
        valueField.textColor = Design.Text.label
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingTail
        valueField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueField)
        NSLayoutConstraint.activate([
            valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ value: String, label: String?) {
        valueField.stringValue = value
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
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
        // Full-bleed inside `UsageCoverageListView`'s card, so the card's corner decides where
        // this row's column starts — the settings rows are inset for the same reason.
        let sideMargins = [
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset)
        ]
        NSLayoutConstraint.activate(sideMargins + [
            heightAnchor.constraint(equalToConstant: Design.UsageDashboard.coverageRowHeight),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        holdAtContentInset(sideMargins)
        setAccessibilityLabel(source.runtimeName)
        setAccessibilityValue("\(state), \(detail.stringValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
