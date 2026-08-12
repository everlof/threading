import Charts
import SwiftUI
import ThreadingRemoteKit

private enum MobileUsageTab: String, CaseIterable {
    case overview
    case limits

    var title: String {
        switch self {
        case .overview: return MobileL10n.string("Overview")
        case .limits: return MobileL10n.string("Limit History")
        }
    }
}

private enum MobileUsageMetric: String, CaseIterable {
    case cost
    case tokens

    var title: String {
        switch self {
        case .cost: return MobileL10n.string("Cost")
        case .tokens: return MobileL10n.string("Tokens")
        }
    }
}

@MainActor
final class RemoteUsageDashboardModel: ObservableObject {
    @Published private(set) var dashboard: RemoteUsageDashboardDTO?
    @Published private(set) var limitSeries: [RemoteUsageLimitSeriesSummaryDTO] = []
    @Published private(set) var nextLimitCursor: String?
    @Published private(set) var limit: RemoteUsageLimitDTO?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingLimit = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var limitErrorMessage: String?
    @Published var selectedLimitID: String?

    private let client: RemoteClient
    private let isDemo: Bool
    private var presentedLimitKey: String?

    init(link: RemoteConnectionLink, isDemo: Bool) {
        client = RemoteClient(link: link)
        self.isDemo = isDemo
    }

    func load() async {
        guard dashboard == nil else { return }
        await fetchDashboard(initial: true)

        var delay: UInt64 = 2_000_000_000
        while dashboard?.isBuilding == true, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await fetchDashboard(initial: false)
            delay = min(delay * 2, 12_000_000_000)
        }
    }

    func refresh(selectedDays: Int) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await fetchDashboard(initial: false)
        if let selectedLimitID {
            await loadLimit(seriesID: selectedLimitID, days: selectedDays, force: true)
        }
    }

    func loadMoreLimits() async {
        guard !isLoadingMore, let cursor = nextLimitCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = isDemo
                ? RemoteUsageDemo.dashboard(cursor: cursor)
                : try await client.fetchUsage(cursor: cursor)
            guard !Task.isCancelled else { return }
            let known = Set(limitSeries.map(\.id))
            limitSeries.append(contentsOf: page.limitSeries.filter { !known.contains($0.id) })
            nextLimitCursor = page.nextLimitCursor
        } catch is CancellationError {
            return
        } catch {
            limitErrorMessage = error.localizedDescription
        }
    }

    func loadLimit(seriesID: String, days: Int, force: Bool = false) async {
        let key = "\(seriesID)|\(days)"
        if !force, presentedLimitKey == key, limit != nil { return }
        isLoadingLimit = true
        limitErrorMessage = nil
        defer { isLoadingLimit = false }
        do {
            let value = isDemo
                ? try RemoteUsageDemo.limit(seriesID: seriesID, days: days)
                : try await client.fetchUsageLimit(seriesID: seriesID, days: days)
            guard !Task.isCancelled,
                  selectedLimitID == nil || selectedLimitID == seriesID else { return }
            limit = value
            presentedLimitKey = key
        } catch is CancellationError {
            return
        } catch {
            limitErrorMessage = error.localizedDescription
        }
    }

    private func fetchDashboard(initial: Bool) async {
        if initial { isLoading = true }
        defer { if initial { isLoading = false } }
        errorMessage = nil
        do {
            let value = isDemo ? RemoteUsageDemo.dashboard() : try await client.fetchUsage()
            guard !Task.isCancelled else { return }
            dashboard = value
            limitSeries = value.limitSeries
            nextLimitCursor = value.nextLimitCursor
            if selectedLimitID == nil
                || !limitSeries.contains(where: { $0.id == selectedLimitID }) {
                selectedLimitID = isDemo
                    ? RemoteUsageDemo.preferredSeriesID(in: limitSeries)
                    : limitSeries.first?.id
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RemoteUsageDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme
    @StateObject private var model: RemoteUsageDashboardModel
    private let isDemo: Bool
    private let demoShowsStaleSnapshot: Bool
    @State private var tab = MobileUsageTab.overview
    @State private var overviewDays = 30
    @State private var limitDays = 30
    @State private var metric = MobileUsageMetric.cost
    @State private var actionTask: Task<Void, Never>?

    init(link: RemoteConnectionLink, isDemo: Bool) {
        self.isDemo = isDemo
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        demoShowsStaleSnapshot = environment["THREADING_MOBILE_DEMO"] == "usage-stale"
            || environment["THREADING_MOBILE_UI_EVIDENCE_ID"]?.contains("usage-stale") == true
#else
        demoShowsStaleSnapshot = false
#endif
        _model = StateObject(
            wrappedValue: RemoteUsageDashboardModel(link: link, isDemo: isDemo)
        )
#if DEBUG
        if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
            .hasPrefix("usage-limit") == true {
            _tab = State(initialValue: .limits)
        }
#endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
                    Picker("Usage section", selection: $tab) {
                        ForEach(MobileUsageTab.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if tab == .overview {
                        overviewContent
                    } else {
                        limitContent
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, MobileDesign.Spacing.inset)
                .padding(.top, MobileDesign.Spacing.medium)
                .padding(.bottom, MobileDesign.Spacing.pane)
            }
            .refreshable { await model.refresh(selectedDays: limitDays) }
            .background(theme.ground)
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .task(id: selectedLimitTaskID) {
                guard tab == .limits, let id = model.selectedLimitID else { return }
                await model.loadLimit(seriesID: id, days: limitDays)
            }
            .onDisappear {
                actionTask?.cancel()
                actionTask = nil
            }
        }
        .presentationDetents([.large])
    }

    private var selectedLimitTaskID: String {
        "\(tab.rawValue)|\(model.selectedLimitID ?? "none")|\(limitDays)"
    }

    @ViewBuilder
    private var overviewContent: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            rangePicker(selection: $overviewDays)
            Picker("Metric", selection: $metric) {
                ForEach(MobileUsageMetric.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }

        if let range = model.dashboard?.ranges.first(where: { $0.days == overviewDays }) {
            overviewHero(range)
            providerList(range)
            totals(range)
            coverage
            UsageCard {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                    Text("About these numbers")
                        .font(.headline)
                    Text(overviewFootnote)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                    if let version = model.dashboard?.pricingCatalogVersion {
                        Text("Pricing catalog \(version)")
                            .font(.caption)
                            .foregroundStyle(theme.tertiaryLabel)
                    }
                }
            }
        } else if model.isLoading {
            loadingCard("Preparing Usage…")
        } else if let message = model.errorMessage {
            errorCard(message)
        } else {
            emptyCard(
                title: "Usage is being prepared",
                detail: model.dashboard?.isBuilding == true
                    ? "The Mac is indexing local usage. Pull to refresh in a moment."
                    : "No completed usage report is available yet."
            )
        }
    }

    private func overviewHero(_ range: RemoteUsageRangeDTO) -> some View {
        let projection = metricProjection(range)
        return UsageCard {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(MobileL10n.string(
                            metric == .cost ? "Measured token cost" : "Processed tokens"
                        ))
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryLabel)
                        Spacer()
                        snapshotFreshnessBadge
                    }
                    Text(metricValue(metric == .cost ? range.cost.totalUSD : Double(range.tokens.processed)))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(qualityLine(range))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                }

                Chart {
                    ForEach(projection.chartSeries, id: \.id) { series in
                        ForEach(series.points, id: \.at) { point in
                            BarMark(
                                x: .value("Day", Date(timeIntervalSince1970: point.at), unit: .day),
                                y: .value(metric.title, point.value)
                            )
                            .foregroundStyle(seriesColor(series.styleIndex, isOther: series.isOther))
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(theme.divider)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 210)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Daily \(metric.title.lowercased()) chart")
                .accessibilityValue(chartSummary(projection))

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 108), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(projection.chartSeries, id: \.id) { series in
                        Label {
                            Text(series.title ?? MobileL10n.string("Other"))
                                .lineLimit(1)
                        } icon: {
                            Circle()
                                .fill(seriesColor(series.styleIndex, isOther: series.isOther))
                                .frame(width: 7, height: 7)
                        }
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                    }
                }

                HStack {
                    Label("\(range.records) requests", systemImage: "arrow.trianglehead.2.clockwise")
                    Spacer()
                    Text("\(range.activeDayCount) active days")
                }
                .font(.caption)
                .foregroundStyle(theme.secondaryLabel)
            }
        }
    }

    private func providerList(_ range: RemoteUsageRangeDTO) -> some View {
        let projection = metricProjection(range)
        let total = metric == .cost ? range.cost.totalUSD : Double(range.tokens.processed)
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text("Providers")
                .font(.headline)
                .padding(.horizontal, MobileDesign.Spacing.small)
            UsageCard {
                LazyVStack(spacing: 0) {
                    ForEach(Array(projection.providers.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { Divider().overlay(theme.divider) }
                        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                            HStack {
                                Label {
                                    Text(provider.name).lineLimit(1)
                                } icon: {
                                    Circle()
                                        .fill(seriesColor(provider.styleIndex, isOther: false))
                                        .frame(width: 8, height: 8)
                                }
                                Spacer()
                                Text(metricValue(
                                    metric == .cost
                                        ? provider.costUSD
                                        : Double(provider.tokens.processed)
                                ))
                                .monospacedDigit()
                            }
                            ProgressView(value: providerShare(provider, total: total))
                                .tint(seriesColor(provider.styleIndex, isOther: false))
                            Text(providerDetail(provider, total: total))
                                .font(.caption)
                                .foregroundStyle(theme.secondaryLabel)
                        }
                        .padding(.vertical, MobileDesign.Spacing.medium)
                    }
                }
            }
        }
    }

    private func totals(_ range: RemoteUsageRangeDTO) -> some View {
        let values: [(String, String)] = [
            (MobileL10n.string("Processed tokens"), compact(Double(range.tokens.processed))),
            (MobileL10n.string("Cached input"), compact(Double(range.tokens.cachedInput))),
            (MobileL10n.string("Uncached input"), compact(Double(range.tokens.uncachedInput))),
            (MobileL10n.string("Cache writes"), compact(Double(range.tokens.cacheWrite))),
            (MobileL10n.string("Output"), compact(Double(range.tokens.output))),
            (MobileL10n.string("Reasoning"), compact(Double(range.tokens.reasoning))),
            (MobileL10n.string("Cache savings"), currency(range.cost.cacheSavingsUSD)),
            (MobileL10n.string("Unpriced tokens"), compact(Double(range.cost.unpricedTokens))),
        ]
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text("Totals")
                .font(.headline)
                .padding(.horizontal, MobileDesign.Spacing.small)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 142), spacing: MobileDesign.Spacing.small)],
                spacing: MobileDesign.Spacing.small
            ) {
                ForEach(values, id: \.0) { value in
                    UsageMetricCard(title: value.0, value: value.1, detail: nil)
                }
            }
        }
    }

    @ViewBuilder
    private var coverage: some View {
        if let coverage = model.dashboard?.coverage, !coverage.isEmpty {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                Text("Data coverage")
                    .font(.headline)
                    .padding(.horizontal, MobileDesign.Spacing.small)
                UsageCard {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(coverage.enumerated()), id: \.element.runtimeID) { index, source in
                            if index > 0 { Divider().overlay(theme.divider) }
                            HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
                                Image(systemName: coverageSymbol(source.state))
                                    .foregroundStyle(coverageColor(source.state))
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(source.runtimeName).font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(coverageTitle(source.state))
                                            .font(.caption)
                                            .foregroundStyle(coverageColor(source.state))
                                    }
                                    Text("\(source.recordCount) records from \(source.sourceCount) sources")
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryLabel)
                                    if let detail = source.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(theme.tertiaryLabel)
                                    }
                                }
                            }
                            .padding(.vertical, MobileDesign.Spacing.medium)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var limitContent: some View {
        if model.limitSeries.isEmpty {
            if model.isLoading {
                loadingCard("Loading limit history…")
            } else if let message = model.errorMessage {
                errorCard(message)
            } else {
                emptyCard(
                    title: "No limit history",
                    detail: "The Mac has not recorded a provider limit window yet."
                )
            }
        } else {
            UsageCard {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                    Menu {
                        ForEach(model.limitSeries) { series in
                            Button {
                                model.selectedLimitID = series.id
                            } label: {
                                if series.id == model.selectedLimitID {
                                    Label(series.title, systemImage: "checkmark")
                                } else {
                                    Text(series.title)
                                }
                            }
                        }
                    } label: {
                        if let selected = model.limitSeries.first(where: {
                            $0.id == model.selectedLimitID
                        }) {
                            UsageSeriesSelectionLabel(series: selected)
                        } else {
                            Label("Choose account", systemImage: "person.crop.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .tint(theme.accent)
                    rangePicker(selection: $limitDays)
                }
            }

            if model.isLoadingLimit, model.limit == nil {
                loadingCard("Preparing selected history…")
            } else if let detail = selectedLimit {
                limitSummary(detail)
                limitChart(detail)
            } else if let message = model.limitErrorMessage {
                errorCard(message)
            }

            if model.nextLimitCursor != nil {
                Button {
                    actionTask?.cancel()
                    actionTask = Task { await model.loadMoreLimits() }
                } label: {
                    if model.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Load more accounts", systemImage: "chevron.down")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(theme.accent)
                .frame(minHeight: MobileDesign.Size.minimumTapTarget)
            }
        }
    }

    private var selectedLimit: RemoteUsageLimitDTO? {
        guard model.limit?.series.id == model.selectedLimitID,
              model.limit?.days == limitDays else { return nil }
        return model.limit
    }

    @ViewBuilder
    private var snapshotFreshnessBadge: some View {
        if let dashboard = model.dashboard {
            let isFresh = snapshotIsFresh(dashboard) && model.errorMessage == nil
                && !dashboard.isBuilding && !model.isRefreshing
            if isFresh {
                Circle()
                    .fill(theme.positive)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(snapshotStatusText(dashboard))
            } else {
                HStack(spacing: MobileDesign.Spacing.tight) {
                if model.isRefreshing || dashboard.isBuilding {
                    ProgressView().controlSize(.small).tint(theme.accent)
                } else {
                    Circle()
                        .fill(snapshotIsFresh(dashboard) && model.errorMessage == nil
                            ? theme.positive
                            : theme.tertiaryLabel)
                        .frame(width: 7, height: 7)
                }
                    Text(snapshotStatusText(dashboard))
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryLabel)
                }
                .padding(.horizontal, MobileDesign.Spacing.small)
                .padding(.vertical, MobileDesign.Spacing.tight)
                .background(theme.surface.opacity(0.92), in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(snapshotStatusText(dashboard))
            }
        }
    }

    private func snapshotIsFresh(_ dashboard: RemoteUsageDashboardDTO) -> Bool {
        if demoShowsStaleSnapshot {
            return false
        }
        return isDemo || Date().timeIntervalSince1970 - dashboard.preparedAt < 5 * 60
    }

    private func snapshotStatusText(_ dashboard: RemoteUsageDashboardDTO) -> String {
        if isDemo, !demoShowsStaleSnapshot {
            return MobileL10n.string("Updated now")
        }
        if demoShowsStaleSnapshot {
            return MobileL10n.string("Updated 3h ago")
        }
        let observed = wallRelativeDate(dashboard.preparedAt)
        if model.errorMessage != nil {
            return MobileL10n.string("Offline · Showing snapshot from %@", observed)
        }
        if dashboard.isBuilding || model.isRefreshing {
            return MobileL10n.string("Updating · Showing snapshot from %@", observed)
        }
        return MobileL10n.string("Updated %@", observed)
    }

    private func limitSummary(_ detail: RemoteUsageLimitDTO) -> some View {
        let banked = bankedResetPresentation(detail.series)
        let projection = projectionPresentation(detail)
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text("Current window")
                .font(.headline)
                .padding(.horizontal, MobileDesign.Spacing.small)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: MobileDesign.Spacing.small),
                    GridItem(.flexible(), spacing: MobileDesign.Spacing.small),
                ],
                spacing: MobileDesign.Spacing.small
            ) {
                UsageMetricCard(
                    title: MobileL10n.string("Banked resets"),
                    value: banked.value,
                    detail: banked.detail
                )
                UsageMetricCard(
                    title: MobileL10n.string("Used"),
                    value: detail.series.currentFraction.map(percent) ?? MobileL10n.string("Unavailable"),
                    detail: detail.series.resetsAt.map {
                        MobileL10n.string(
                            "Resets %@\n%@",
                            relativeDate($0),
                            exactDateTime($0)
                        )
                    }
                )
                UsageMetricCard(
                    title: projection.title,
                    value: projection.value,
                    detail: projection.detail
                )
                UsageMetricCard(
                    title: MobileL10n.string("Recorded resets"),
                    value: String(detail.recordedResetCount),
                    detail: MobileL10n.string(
                        "%@ restored pace",
                        percent(detail.restoredPaceFraction)
                    )
                )
            }
        }
    }

    private func limitChart(_ detail: RemoteUsageLimitDTO) -> some View {
        UsageCard {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                Text("Limit history")
                    .font(.headline)
                Chart {
                    ForEach(detail.observed, id: \.at) { point in
                        LineMark(
                            x: .value("Observed at", Date(timeIntervalSince1970: point.at)),
                            y: .value("Used", point.fraction),
                            series: .value("Observed segment", point.segment)
                        )
                        .foregroundStyle(theme.accent)
                        .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }

                    if let projection = detail.projection {
                        LineMark(
                            x: .value("Projected from", Date(timeIntervalSince1970: projection.observedAt)),
                            y: .value("Projected use", projection.observedFraction),
                            series: .value("Projection", "projection")
                        )
                        .foregroundStyle(theme.warning)
                        .lineStyle(.init(
                            lineWidth: 2,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [5, 4]
                        ))
                        LineMark(
                            x: .value(
                                "Projected to",
                                Date(timeIntervalSince1970: projection.projectedExhaustionAt ?? projection.resetsAt)
                            ),
                            y: .value(
                                "Projected use",
                                projection.projectedExhaustionAt == nil
                                    ? projection.projectedFractionAtReset
                                    : 1
                            ),
                            series: .value("Projection", "projection")
                        )
                        .foregroundStyle(theme.warning)
                        .lineStyle(.init(
                            lineWidth: 2,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [5, 4]
                        ))
                    }

                    ForEach(detail.resets) { reset in
                        RuleMark(x: .value("Reset", Date(timeIntervalSince1970: reset.detectedAt)))
                            .foregroundStyle(reset.cause == "bankedCredit" ? theme.positive : theme.secondaryLabel)
                            .lineStyle(.init(lineWidth: reset.cause == "bankedCredit" ? 2 : 1, dash: [3, 3]))
                    }

                    if let expiry = detail.series.nextBankedResetExpiresAt {
                        RuleMark(x: .value("Banked reset expiry", Date(timeIntervalSince1970: expiry)))
                            .foregroundStyle(theme.negative)
                            .lineStyle(.init(lineWidth: 2, dash: [2, 3]))
                    }
                }
                .chartYScale(domain: 0...1)
                .chartYAxis {
                    AxisMarks(values: [0, 0.5, 1]) { value in
                        AxisGridLine().foregroundStyle(theme.divider)
                        AxisValueLabel {
                            if let fraction = value.as(Double.self) {
                                Text(fraction, format: .percent.precision(.fractionLength(0)))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(theme.divider)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 250)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Limit history chart")
                .accessibilityValue(limitChartSummary(detail))

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 128), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    chartLegend("Observed", color: theme.accent, symbol: "circle.fill")
                    chartLegend("Projection", color: theme.warning, symbol: "line.diagonal")
                    chartLegend("Reset", color: theme.secondaryLabel, symbol: "arrow.counterclockwise")
                    chartLegend("Banked reset", color: theme.positive, symbol: "bolt.fill")
                    chartLegend("Expiry", color: theme.negative, symbol: "hourglass")
                }
            }
        }
    }

    private func rangePicker(selection: Binding<Int>) -> some View {
        Picker("Range", selection: selection) {
            Text("7d").tag(7)
            Text("30d").tag(30)
            Text("90d").tag(90)
        }
        .pickerStyle(.segmented)
    }

    private func loadingCard(_ text: LocalizedStringKey) -> some View {
        UsageCard {
            HStack(spacing: MobileDesign.Spacing.medium) {
                ProgressView().tint(theme.accent)
                Text(text).foregroundStyle(theme.secondaryLabel)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
        }
    }

    private func errorCard(_ message: String) -> some View {
        UsageCard {
            ContentUnavailableView(
                "Usage unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(minHeight: 150)
        }
    }

    private func emptyCard(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        UsageCard {
            ContentUnavailableView(title, systemImage: "chart.bar", description: Text(detail))
                .frame(minHeight: 150)
        }
    }

    private func metricProjection(_ range: RemoteUsageRangeDTO) -> RemoteUsageMetricProjectionDTO {
        metric == .cost ? range.costMetric : range.tokenMetric
    }

    private func metricValue(_ value: Double) -> String {
        metric == .cost ? currency(value) : compact(value)
    }

    private func qualityLine(_ range: RemoteUsageRangeDTO) -> String {
        if metric == .tokens {
            return MobileL10n.string("Reasoning is included in output · %lld requests", range.records)
        }
        if range.cost.unpricedTokens > 0 {
            return MobileL10n.string(
                "%@ tokens could not be priced · Local estimate",
                compact(Double(range.cost.unpricedTokens))
            )
        }
        if range.cost.catalogPricedUSD > 0, range.cost.providerReportedUSD > 0 {
            return MobileL10n.string("Provider totals plus local list-price estimates")
        }
        return range.cost.providerReportedUSD > 0
            ? MobileL10n.string("Measured from provider-reported cost")
            : MobileL10n.string("Estimated at public API list prices")
    }

    private var overviewFootnote: String {
        MobileL10n.string(
            "Local transcript measurements and list-price estimates are not an invoice. Coverage below shows what the Mac could measure."
        )
    }

    private func providerShare(_ provider: RemoteUsageProviderDTO, total: Double) -> Double {
        guard total > 0 else { return 0 }
        let value = metric == .cost ? provider.costUSD : Double(provider.tokens.processed)
        return min(max(value / total, 0), 1)
    }

    private func providerDetail(_ provider: RemoteUsageProviderDTO, total: Double) -> String {
        let share = providerShare(provider, total: total)
            .formatted(.percent.precision(.fractionLength(1)))
        return metric == .cost
            ? MobileL10n.string("%@ of cost · %@ tokens", share, compact(Double(provider.tokens.processed)))
            : MobileL10n.string("%@ of tokens · %lld requests", share, provider.records)
    }

    private func chartSummary(_ projection: RemoteUsageMetricProjectionDTO) -> String {
        let total = projection.chartSeries.flatMap(\.points).reduce(0) { $0 + $1.value }
        return MobileL10n.string(
            "%@ across %lld provider series",
            metricValue(total),
            projection.chartSeries.count
        )
    }

    private func limitChartSummary(_ detail: RemoteUsageLimitDTO) -> String {
        MobileL10n.string(
            "%lld observations, %lld recorded resets, %@ currently used",
            detail.observed.count,
            detail.recordedResetCount,
            detail.series.currentFraction.map(percent) ?? MobileL10n.string("unknown")
        )
    }

    private func bankedResetPresentation(
        _ series: RemoteUsageLimitSeriesSummaryDTO
    ) -> (value: String, detail: String) {
        guard let count = series.bankedResetCount else {
            return (
                MobileL10n.string("Unavailable"),
                MobileL10n.string("Reset-credit count was not reported")
            )
        }
        guard count > 0 else {
            return ("0", MobileL10n.string("None available"))
        }
        if let expiry = series.nextBankedResetExpiresAt {
            return (String(count), MobileL10n.string("Next expiry %@", relativeDate(expiry)))
        }
        return (String(count), MobileL10n.string("No expiry reported"))
    }

    private func projectionPresentation(
        _ detail: RemoteUsageLimitDTO
    ) -> (title: String, value: String, detail: String?) {
        guard let projection = detail.projection else {
            return (
                MobileL10n.string("Projection"),
                MobileL10n.string("Unavailable"),
                MobileL10n.string("More history is needed")
            )
        }
        if let exhaustion = projection.projectedExhaustionAt {
            return (
                MobileL10n.string("Projected exhaustion"),
                relativeDate(exhaustion),
                MobileL10n.string("Estimate from recent burn")
            )
        }
        return (
            MobileL10n.string("Projected at reset"),
            percent(projection.projectedFractionAtReset),
            MobileL10n.string("Estimate from recent burn")
        )
    }

    private func chartLegend(_ title: LocalizedStringKey, color: Color, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.caption)
        .foregroundStyle(theme.secondaryLabel)
    }

    private func seriesColor(_ index: Int, isOther: Bool) -> Color {
        if isOther { return theme.tertiaryLabel }
        return theme.categorical(index)
    }

    private func coverageSymbol(_ state: String) -> String {
        switch state {
        case "complete": return "checkmark.circle.fill"
        case "partial": return "circle.lefthalf.filled"
        case "failed": return "xmark.octagon.fill"
        default: return "questionmark.circle"
        }
    }

    private func coverageTitle(_ state: String) -> String {
        switch state {
        case "complete": return MobileL10n.string("Complete")
        case "partial": return MobileL10n.string("Partial")
        case "failed": return MobileL10n.string("Failed")
        default: return MobileL10n.string("Unavailable")
        }
    }

    private func coverageColor(_ state: String) -> Color {
        switch state {
        case "complete": return theme.positive
        case "partial": return theme.warning
        case "failed": return theme.negative
        default: return theme.secondaryLabel
        }
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 1_000 ? 0 : 2)))
    }

    private func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private func relativeDate(_ timestamp: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let reference = model.dashboard?.preparedAt ?? Date().timeIntervalSince1970
        return formatter.localizedString(fromTimeInterval: timestamp - reference)
    }

    private func exactDateTime(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(
            .dateTime.month(.abbreviated).day().hour().minute()
        )
    }

    private func wallRelativeDate(_ timestamp: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(
            fromTimeInterval: timestamp - Date().timeIntervalSince1970
        )
    }
}

private struct UsageCard<Content: View>: View {
    @Environment(\.remoteTheme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(MobileDesign.Spacing.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: theme.panelRadius)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            }
            .remoteThemeGlow(theme)
    }
}

private struct UsageMetricCard: View {
    @Environment(\.remoteTheme) private var theme
    let title: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.secondaryLabel)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(2)
            }
        }
        .padding(MobileDesign.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.controlRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        }
    }
}

private struct UsageSeriesSelectionLabel: View {
    let series: RemoteUsageLimitSeriesSummaryDTO
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Label(series.runtimeName, systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: MobileDesign.Spacing.small)
            Text(series.accountName)
                .font(.caption.weight(.medium))
                .padding(.horizontal, MobileDesign.Spacing.small)
                .padding(.vertical, MobileDesign.Spacing.tight)
                .background(theme.controlResting, in: Capsule())
            Text(series.windowLabel)
                .font(.caption.weight(.medium))
                .padding(.horizontal, MobileDesign.Spacing.small)
                .padding(.vertical, MobileDesign.Spacing.tight)
                .background(theme.controlResting, in: Capsule())
        }
        .foregroundStyle(theme.label)
        .accessibilityElement(children: .combine)
    }
}

enum RemoteUsageDemo {
    private static let now = Date(timeIntervalSince1970: 1_900_000_000).timeIntervalSince1970

    static func dashboard(cursor: String? = nil) -> RemoteUsageDashboardDTO {
        let allSeries = limitSummaries
        let offset = Int(cursor ?? "0") ?? 0
        let page = Array(allSeries.dropFirst(offset).prefix(3))
        let end = min(allSeries.count, offset + page.count)
        return RemoteUsageDashboardDTO(
            isBuilding: false,
            builtAt: now - 180,
            pricingCatalogVersion: "2026-08",
            ranges: [7, 30, 90].map(range),
            coverage: [
                .init(
                    runtimeID: "codex",
                    runtimeName: "Codex",
                    state: "complete",
                    sourceCount: 2,
                    recordCount: 2_814,
                    detail: nil
                ),
                .init(
                    runtimeID: "claude",
                    runtimeName: "Claude Code",
                    state: "complete",
                    sourceCount: 1,
                    recordCount: 1_492,
                    detail: nil
                ),
                .init(
                    runtimeID: "openCode",
                    runtimeName: "OpenCode",
                    state: "partial",
                    sourceCount: 1,
                    recordCount: 186,
                    detail: "Only resumable sessions known to Threading were measured."
                ),
            ],
            limitSeries: page,
            nextLimitCursor: end < allSeries.count ? String(end) : nil,
            omittedLimitSeriesCount: 0,
            preparedAt: now
        )
    }

    static func preferredSeriesID(
        in series: [RemoteUsageLimitSeriesSummaryDTO]
    ) -> String? {
#if DEBUG
        let value = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] ?? ""
        if value == "usage-limit-zero" {
            return series.first(where: { $0.bankedResetCount == 0 })?.id ?? series.first?.id
        }
        if value == "usage-limit-unavailable" {
            return series.first(where: { $0.bankedResetCount == nil })?.id ?? series.first?.id
        }
#endif
        return series.first?.id
    }

    static func limit(seriesID: String, days: Int) throws -> RemoteUsageLimitDTO {
        guard let summary = limitSummaries.first(where: { $0.id == seriesID }) else {
            throw RemoteClientError.invalidResponse
        }
        let start = now - Double(days) * 86_400
        let pointCount = min(days * 2, 120)
        let bankedResetAt = now - 12 * 86_400
        let hasBankedResetInRange = summary.bankedResetCount == 2 && bankedResetAt >= start
        let observed = (0..<pointCount).map { index in
            let progress = Double(index) / Double(max(1, pointCount - 1))
            let at = start + progress * Double(days) * 86_400
            let segment: Int
            let fraction: Double
            if hasBankedResetInRange, at >= bankedResetAt {
                let postResetProgress = (at - bankedResetAt) / max(1, now - bankedResetAt)
                segment = 1
                fraction = 0.05
                    + postResetProgress * ((summary.currentFraction ?? 0.65) - 0.05)
            } else if hasBankedResetInRange {
                let preResetProgress = (at - start) / max(1, bankedResetAt - start)
                segment = 0
                fraction = 0.08 + preResetProgress * 0.72
            } else {
                segment = 0
                fraction = 0.08
                    + progress * ((summary.currentFraction ?? 0.65) - 0.08)
            }
            return RemoteUsageLimitPointDTO(
                at: at,
                fraction: index == pointCount - 1
                    ? (summary.currentFraction ?? fraction)
                    : fraction,
                segment: segment
            )
        }
        let resets: [RemoteUsageLimitResetDTO] = hasBankedResetInRange
            ? [
                .init(
                    id: "demo-banked-reset",
                    detectedAt: bankedResetAt,
                    previousObservedAt: bankedResetAt - 3_600,
                    cause: "bankedCredit",
                    restoredFraction: 0.72,
                    elapsedFraction: 0.18,
                    paceGainFraction: 0.54
                )
            ]
            : []
        return RemoteUsageLimitDTO(
            series: summary,
            days: days,
            start: start,
            end: now,
            observed: observed,
            resets: resets,
            recordedResetCount: resets.count,
            restoredPaceFraction: resets.reduce(0) { $0 + $1.paceGainFraction },
            projection: .init(
                observedAt: now,
                observedFraction: summary.currentFraction ?? 0.5,
                resetsAt: summary.resetsAt ?? now + 4 * 86_400,
                projectedFractionAtReset: 0.84,
                projectedExhaustionAt: nil,
                bankedResetExpiresAt: summary.nextBankedResetExpiresAt
            ),
            preparedAt: now
        )
    }

    private static func range(days: Int) -> RemoteUsageRangeDTO {
        let tokens = RemoteUsageTokenCountsDTO(
            uncachedInput: Int64(days) * 720_000,
            cachedInput: Int64(days) * 1_080_000,
            cacheWrite: Int64(days) * 90_000,
            output: Int64(days) * 210_000,
            reasoning: Int64(days) * 72_000
        )
        let codexTokens = RemoteUsageTokenCountsDTO(
            uncachedInput: Int64(Double(tokens.uncachedInput) * 0.64),
            cachedInput: Int64(Double(tokens.cachedInput) * 0.64),
            cacheWrite: Int64(Double(tokens.cacheWrite) * 0.64),
            output: Int64(Double(tokens.output) * 0.64),
            reasoning: Int64(Double(tokens.reasoning) * 0.64)
        )
        let claudeTokens = RemoteUsageTokenCountsDTO(
            uncachedInput: tokens.uncachedInput - codexTokens.uncachedInput,
            cachedInput: tokens.cachedInput - codexTokens.cachedInput,
            cacheWrite: tokens.cacheWrite - codexTokens.cacheWrite,
            output: tokens.output - codexTokens.output,
            reasoning: tokens.reasoning - codexTokens.reasoning
        )
        let totalCost = Double(days) * 86.42
        let providers = [
            RemoteUsageProviderDTO(
                id: "direct|codex",
                name: "Codex",
                tokens: codexTokens,
                costUSD: totalCost * 0.64,
                records: days * 61,
                styleIndex: 0
            ),
            RemoteUsageProviderDTO(
                id: "direct|claude",
                name: "Claude Code",
                tokens: claudeTokens,
                costUSD: totalCost * 0.36,
                records: days * 37,
                styleIndex: 1
            ),
        ]
        let costMetric = metric(days: days, providers: providers, cost: true)
        let tokenMetric = metric(days: days, providers: providers, cost: false)
        return RemoteUsageRangeDTO(
            days: days,
            start: now - Double(days) * 86_400,
            end: now,
            tokens: tokens,
            records: providers.reduce(0) { $0 + $1.records },
            cost: .init(
                providerReportedUSD: totalCost * 0.72,
                catalogPricedUSD: totalCost * 0.28,
                unpricedTokens: 0,
                cacheSavingsUSD: totalCost * 1.91
            ),
            activeDayCount: days,
            costMetric: costMetric,
            tokenMetric: tokenMetric,
            breakdowns: []
        )
    }

    private static func metric(
        days: Int,
        providers: [RemoteUsageProviderDTO],
        cost: Bool
    ) -> RemoteUsageMetricProjectionDTO {
        RemoteUsageMetricProjectionDTO(
            providers: providers.sorted {
                let lhs = cost ? $0.costUSD : Double($0.tokens.processed)
                let rhs = cost ? $1.costUSD : Double($1.tokens.processed)
                return lhs > rhs
            },
            chartSeries: providers.map { provider in
                let total = cost ? provider.costUSD : Double(provider.tokens.processed)
                return RemoteUsageChartSeriesDTO(
                    id: provider.id,
                    title: provider.name,
                    isOther: false,
                    styleIndex: provider.styleIndex,
                    points: (0..<days).map { index in
                        RemoteUsageChartPointDTO(
                            at: now - Double(days - index) * 86_400,
                            value: total / Double(days) * (0.45 + Double((index * 7) % 11) / 10)
                        )
                    }
                )
            }
        )
    }

    private static let limitSummaries: [RemoteUsageLimitSeriesSummaryDTO] = [
        .init(
            id: "codex|personal|weekly",
            runtimeName: "Codex",
            accountName: "Personal",
            windowLabel: "Weekly",
            currentFraction: 0.63,
            resetsAt: now + 3 * 86_400,
            bankedResetCount: 2,
            nextBankedResetExpiresAt: now + 8 * 86_400
        ),
        .init(
            id: "codex|work|weekly",
            runtimeName: "Codex",
            accountName: "Work",
            windowLabel: "Weekly",
            currentFraction: 0.28,
            resetsAt: now + 5 * 86_400,
            bankedResetCount: 0,
            nextBankedResetExpiresAt: nil
        ),
        .init(
            id: "claude|personal|session",
            runtimeName: "Claude Code",
            accountName: "Personal",
            windowLabel: "Session",
            currentFraction: 0.31,
            resetsAt: now + 2 * 3_600,
            bankedResetCount: nil,
            nextBankedResetExpiresAt: nil
        ),
    ]
}
