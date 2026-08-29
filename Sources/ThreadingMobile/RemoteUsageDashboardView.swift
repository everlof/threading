import Charts
import SwiftUI
import ThreadingRemoteKit

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

private enum MobileUsageSection: Hashable {
    case currentCapacity
    case limitHistory
    case consumption
}

/// The two things the screen can be about, and never both at once: one login, or all of them.
/// The flat page that preceded it stacked an all-accounts card, every login's windows, one
/// login's history and the fleet's consumption in one scroll, with nothing to say which
/// numbers were whose.
private enum MobileUsageScope: Hashable, CaseIterable {
    case accounts
    case totals

    var title: String {
        switch self {
        case .accounts: return MobileL10n.string("Accounts")
        case .totals: return MobileL10n.string("Totals")
        }
    }
}

/// The login a caller wants the screen opened on — the chat's, when the screen is reached from
/// a chat. Matched against the limit series' own runtime and account names.
struct MobileUsageAccountFocus: Equatable {
    let runtimeName: String
    let accountName: String
}

enum MobileUsageFleetProjection {
    struct Account: Equatable, Identifiable {
        let runtimeName: String
        let accountName: String
        let windows: [RemoteUsageLimitSeriesSummaryDTO]

        var id: String { "\(runtimeName)|\(accountName)" }
    }

    struct Summary: Equatable {
        let accountCount: Int
        let readyCount: Int
        let constrainedCount: Int
        let unknownCount: Int
        let nextReset: Double?
    }

    /// The login the rail starts on: the focused one where it exists (by runtime and account,
    /// then by account name alone, since a runtime's display name can differ between the
    /// catalogue and the usage index), otherwise the first.
    static func startingAccountID(
        in accounts: [Account],
        focus: MobileUsageAccountFocus?
    ) -> String? {
        if let focus {
            if let exact = accounts.first(where: {
                $0.runtimeName == focus.runtimeName && $0.accountName == focus.accountName
            }) {
                return exact.id
            }
            if let byName = accounts.first(where: { $0.accountName == focus.accountName }) {
                return byName.id
            }
        }
        return accounts.first?.id
    }

    static func accounts(
        from series: [RemoteUsageLimitSeriesSummaryDTO]
    ) -> [Account] {
        Dictionary(grouping: series) { "\($0.runtimeName)|\($0.accountName)" }
            .values
            .map {
                Account(
                    runtimeName: $0[0].runtimeName,
                    accountName: $0[0].accountName,
                    windows: $0.sorted {
                        if $0.windowLabel != $1.windowLabel {
                            return $0.windowLabel.localizedStandardCompare($1.windowLabel)
                                == .orderedAscending
                        }
                        return $0.id < $1.id
                    }
                )
            }
            .sorted {
                let runtime = $0.runtimeName.localizedStandardCompare($1.runtimeName)
                if runtime != .orderedSame { return runtime == .orderedAscending }
                return $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending
            }
    }

    static func summary(
        for accounts: [Account],
        referenceTime: Double
    ) -> Summary {
        var ready = 0
        var constrained = 0
        var unknown = 0
        var resets: [Double] = []

        for account in accounts {
            let active = account.windows.filter { ($0.resetsAt ?? .greatestFiniteMagnitude) > referenceTime }
            resets.append(contentsOf: active.compactMap(\.resetsAt))
            let known = active.compactMap(\.currentFraction)
            guard !known.isEmpty else {
                unknown += 1
                continue
            }
            if known.contains(where: { $0 >= 0.75 }) {
                constrained += 1
            } else {
                ready += 1
            }
        }

        return Summary(
            accountCount: accounts.count,
            readyCount: ready,
            constrainedCount: constrained,
            unknownCount: unknown,
            nextReset: resets.min()
        )
    }
}

enum MobileUsageLimitChartDomain {
    static func range(for detail: RemoteUsageLimitDTO) -> ClosedRange<Date> {
        let projectionEnd = detail.projection.map {
            $0.projectedExhaustionAt ?? $0.resetsAt
        }
        let end = [
            detail.end,
            projectionEnd,
            detail.series.resetsAt
        ].compactMap { $0 }.max() ?? detail.end
        let start = Date(timeIntervalSince1970: detail.start)
        return start...Date(timeIntervalSince1970: max(detail.start, end))
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
    private let demoStartsAtLimitHistory: Bool
    private let focus: MobileUsageAccountFocus?
    @State private var overviewDays = 30
    @State private var limitDays = 30
    @State private var metric = MobileUsageMetric.cost
    @State private var actionTask: Task<Void, Never>?
    @State private var scope = MobileUsageScope.accounts
    @State private var breakdownKind = RemoteUsageBreakdownKindDTO.models
    @State private var selectedAccountID: String?

    init(link: RemoteConnectionLink, isDemo: Bool, focus: MobileUsageAccountFocus? = nil) {
        self.isDemo = isDemo
        self.focus = focus
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        demoShowsStaleSnapshot = environment[MobileDemoScene.environmentKey] == "usage-stale"
            || environment["THREADING_MOBILE_UI_EVIDENCE_ID"]?.contains("usage-stale") == true
        demoStartsAtLimitHistory = environment[MobileDemoScene.environmentKey]?
            .hasPrefix("usage-limit") == true
#else
        demoShowsStaleSnapshot = false
        demoStartsAtLimitHistory = false
#endif
        _model = StateObject(
            wrappedValue: RemoteUsageDashboardModel(link: link, isDemo: isDemo)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
                        scopeHeader
                        if scope == .accounts {
                            accountsScope
                                .id(MobileUsageSection.currentCapacity)
                            limitContent
                                .id(MobileUsageSection.limitHistory)
                        } else {
                            overviewContent
                                .id(MobileUsageSection.consumption)
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, MobileDesign.Spacing.inset)
                    .padding(.top, MobileDesign.Spacing.medium)
                    .padding(.bottom, MobileDesign.Spacing.pane)
                }
                .refreshable { await model.refresh(selectedDays: limitDays) }
                .task(id: model.dashboard?.preparedAt) {
                    guard demoStartsAtLimitHistory, model.dashboard != nil else { return }
                    await Task.yield()
                    scrollProxy.scrollTo(MobileUsageSection.limitHistory, anchor: .top)
                }
            }
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
            .onChange(of: model.limitSeries) { _, _ in syncAccountSelection() }
            .task(id: selectedLimitTaskID) {
                guard let id = model.selectedLimitID else { return }
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
        "\(model.selectedLimitID ?? "none")|\(limitDays)"
    }

    private var fleetAccounts: [MobileUsageFleetProjection.Account] {
        MobileUsageFleetProjection.accounts(from: model.limitSeries)
    }

    private var selectedAccount: MobileUsageFleetProjection.Account? {
        let accounts = fleetAccounts
        let id = selectedAccountID
            ?? MobileUsageFleetProjection.startingAccountID(in: accounts, focus: focus)
        return accounts.first { $0.id == id }
    }

    /// Keeps the rail's selection and the history's series pointing at one login: the focused
    /// login when the series first arrive, the first login when the selected one disappears,
    /// and the selected login's first live window whenever the history points elsewhere.
    private func syncAccountSelection() {
        let accounts = fleetAccounts
        if selectedAccountID == nil || !accounts.contains(where: { $0.id == selectedAccountID }) {
            selectedAccountID = MobileUsageFleetProjection.startingAccountID(
                in: accounts,
                focus: focus
            )
        }
        guard let account = accounts.first(where: { $0.id == selectedAccountID }) else { return }
        if !account.windows.contains(where: { $0.id == model.selectedLimitID }) {
            model.selectedLimitID = preferredWindow(of: account)?.id
        }
    }

    private func preferredWindow(
        of account: MobileUsageFleetProjection.Account
    ) -> RemoteUsageLimitSeriesSummaryDTO? {
        let reference = model.dashboard?.preparedAt ?? Date().timeIntervalSince1970
        return account.windows.first { ($0.resetsAt ?? .greatestFiniteMagnitude) > reference }
            ?? account.windows.first
    }

    private func select(_ account: MobileUsageFleetProjection.Account) {
        selectedAccountID = account.id
        model.selectedLimitID = preferredWindow(of: account)?.id
    }

    private var scopeHeader: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Picker("Scope", selection: $scope) {
                ForEach(MobileUsageScope.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline) {
                Text(scopeCaption)
                    .font(.caption)
                    .foregroundStyle(theme.tertiaryLabel)
                Spacer(minLength: MobileDesign.Spacing.small)
                snapshotFreshnessBadge
            }
        }
    }

    /// Names the scope every time, because the same words — a percentage, a reset — mean one
    /// login on one page and all of them on the other.
    private var scopeCaption: String {
        switch scope {
        case .accounts:
            return MobileL10n.string("Per login — its windows and history")
        case .totals:
            return MobileL10n.string("Across all %lld logins", Int64(fleetAccounts.count))
        }
    }

    @ViewBuilder
    private var accountsScope: some View {
        let accounts = fleetAccounts
        if accounts.isEmpty {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                if model.isLoading {
                    loadingCard("Loading current capacity…")
                } else if let message = model.errorMessage {
                    errorCard(message)
                } else {
                    emptyCard(
                        title: "No current capacity",
                        detail: "The Mac has not observed a provider limit window yet."
                    )
                }
            }
        } else {
            let reference = model.dashboard?.preparedAt ?? Date().timeIntervalSince1970
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                accountRail(accounts)
                if let account = selectedAccount {
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                        sectionTitle("Current capacity")
                        capacityCard(account, referenceTime: reference)
                    }
                }
            }
            .onAppear(perform: syncAccountSelection)
        }
    }

    /// One chip per login, the selected one in the accent and scrolled into view. A login is an
    /// account on one runtime, so the same name can appear twice with different runtimes under
    /// it, which is exactly what the rail has to make legible.
    private func accountRail(_ accounts: [MobileUsageFleetProjection.Account]) -> some View {
        let selectedID = selectedAccount?.id
        return ScrollViewReader { proxy in
            // The rail runs edge to edge with the page inset as scroll-content margins: a chip
            // at either end then keeps air around its stroke instead of meeting the clip edge,
            // which shaved the selected chip's accent border and its corner.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    ForEach(accounts) { account in
                        accountChip(account, isSelected: account.id == selectedID)
                            .id(account.id)
                    }
                }
                .padding(.vertical, MobileDesign.Spacing.hairline)
            }
            .contentMargins(.horizontal, MobileDesign.Spacing.inset, for: .scrollContent)
            .padding(.horizontal, -MobileDesign.Spacing.inset)
            .onAppear {
                if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: MobileDesign.Motion.controlResponse)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func accountChip(
        _ account: MobileUsageFleetProjection.Account,
        isSelected: Bool
    ) -> some View {
        Button {
            select(account)
        } label: {
            HStack(spacing: MobileDesign.Spacing.small) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryLabel)
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline / 2) {
                    Text(account.accountName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? theme.label : theme.secondaryLabel)
                    Text(account.runtimeName)
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryLabel)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, MobileDesign.Spacing.medium)
            .frame(height: MobileDesign.Size.minimumTapTarget)
            .background(
                isSelected ? theme.controlHover : theme.panel,
                in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .stroke(
                        isSelected ? theme.accent : theme.border,
                        lineWidth: isSelected ? max(theme.borderWidth, 1) : theme.borderWidth
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(account.accountName), \(account.runtimeName)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func capacityCard(
        _ account: MobileUsageFleetProjection.Account,
        referenceTime: Double
    ) -> some View {
        let activeWindows = account.windows.filter {
            ($0.resetsAt ?? .greatestFiniteMagnitude) > referenceTime
        }
        return UsageCard {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                HStack {
                    Label(account.runtimeName, systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Text(account.accountName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.secondaryLabel)
                }

                ForEach(activeWindows) { window in
                    Button {
                        model.selectedLimitID = window.id
                    } label: {
                        VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                            HStack {
                                Text(window.windowLabel)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(livePercent(window, referenceTime: referenceTime))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }
                            ProgressView(value: liveFraction(window, referenceTime: referenceTime))
                                .tint(capacityColor(window, referenceTime: referenceTime))
                            if let reset = window.resetsAt, reset > referenceTime {
                                Text(MobileL10n.string(
                                    "Resets %@ · %@",
                                    relativeDate(reset),
                                    exactDateTime(reset)
                                ))
                                .font(.caption2)
                                .foregroundStyle(theme.tertiaryLabel)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(MobileL10n.string("Shows this window's history below"))
                }
                if activeWindows.isEmpty {
                    Text("No active windows")
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryLabel)
                }
            }
        }
    }

    private func fleetTitle(_ summary: MobileUsageFleetProjection.Summary) -> String {
        if model.nextLimitCursor != nil {
            return MobileL10n.string("Accounts · %lld loaded", summary.accountCount)
        }
        return MobileL10n.string("All Accounts · %lld", summary.accountCount)
    }

    private func fleetStatus(_ summary: MobileUsageFleetProjection.Summary) -> String {
        var values: [String] = []
        if summary.readyCount > 0 {
            values.append(MobileL10n.string("%lld ready", summary.readyCount))
        }
        if summary.constrainedCount > 0 {
            values.append(MobileL10n.string("%lld constrained", summary.constrainedCount))
        }
        if summary.unknownCount > 0 {
            values.append(MobileL10n.string("%lld unknown", summary.unknownCount))
        }
        return values.joined(separator: " · ")
    }

    private func liveFraction(
        _ window: RemoteUsageLimitSeriesSummaryDTO,
        referenceTime: Double
    ) -> Double {
        guard (window.resetsAt ?? .greatestFiniteMagnitude) > referenceTime else { return 0 }
        return min(max(window.currentFraction ?? 0, 0), 1)
    }

    private func livePercent(
        _ window: RemoteUsageLimitSeriesSummaryDTO,
        referenceTime: Double
    ) -> String {
        guard (window.resetsAt ?? .greatestFiniteMagnitude) > referenceTime,
              let fraction = window.currentFraction else { return MobileL10n.string("Unavailable") }
        return percent(fraction)
    }

    private func capacityColor(
        _ window: RemoteUsageLimitSeriesSummaryDTO,
        referenceTime: Double
    ) -> Color {
        let fraction = liveFraction(window, referenceTime: referenceTime)
        if fraction >= 0.92 { return theme.negative }
        if fraction >= 0.75 { return theme.warning }
        return theme.positive
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, MobileDesign.Spacing.small)
    }

    @ViewBuilder
    private var overviewContent: some View {
        if let range = model.dashboard?.ranges.first(where: { $0.days == overviewDays }) {
            totalsHero(range)
            dailyChart(range)
            statsStrip(range)
            breakdown(range)
            costQuality(range)
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
            coverage
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

    /// One figure, what it stands for, and the providers behind it — each with its share of
    /// the figure as a bar in its own colour. The range sits beside the eyebrow, the way a
    /// period belongs to a total rather than to a chart.
    private func totalsHero(_ range: RemoteUsageRangeDTO) -> some View {
        let projection = metricProjection(range)
        let total = metric == .cost ? range.cost.totalUSD : Double(range.tokens.processed)
        return UsageCard {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                HStack(alignment: .firstTextBaseline) {
                    Text(MobileL10n.string(metric == .cost ? "Raw token cost" : "Processed tokens"))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .kerning(0.6)
                        .foregroundStyle(theme.secondaryLabel)
                    Spacer(minLength: MobileDesign.Spacing.small)
                    rangePicker(selection: $overviewDays)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                    Text(metricValue(total))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(qualityLine(range))
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryLabel)
                }
                if !projection.providers.isEmpty {
                    Divider().overlay(theme.divider)
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                        ForEach(projection.providers, id: \.id) { provider in
                            VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                                HStack(alignment: .firstTextBaseline) {
                                    Label {
                                        Text(provider.name).lineLimit(1)
                                    } icon: {
                                        Circle()
                                            .fill(seriesColor(provider.styleIndex, isOther: false))
                                            .frame(width: 8, height: 8)
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    Spacer(minLength: MobileDesign.Spacing.small)
                                    Text(metricValue(
                                        metric == .cost
                                            ? provider.costUSD
                                            : Double(provider.tokens.processed)
                                    ))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                }
                                ProgressView(value: providerShare(provider, total: total))
                                    .tint(seriesColor(provider.styleIndex, isOther: false))
                                Text(providerDetail(provider, total: total))
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryLabel)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The days of the period as stacked areas, one per provider, under the metric toggle.
    private func dailyChart(_ range: RemoteUsageRangeDTO) -> some View {
        let projection = metricProjection(range)
        let legend = projection.chartSeries.map { series in
            (title: series.title ?? MobileL10n.string("Other"),
             color: seriesColor(series.styleIndex, isOther: series.isOther))
        }
        return UsageCard {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                HStack(alignment: .firstTextBaseline) {
                    Text(MobileL10n.string(metric == .cost ? "Daily cost" : "Daily tokens"))
                        .font(.headline)
                    Spacer(minLength: MobileDesign.Spacing.small)
                    Picker("Metric", selection: $metric) {
                        ForEach(MobileUsageMetric.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Chart {
                    ForEach(projection.chartSeries, id: \.id) { series in
                        ForEach(series.points, id: \.at) { point in
                            AreaMark(
                                x: .value("Day", Date(timeIntervalSince1970: point.at), unit: .day),
                                y: .value(metric.title, point.value)
                            )
                            .foregroundStyle(by: .value("Provider", series.title ?? MobileL10n.string("Other")))
                            .interpolationMethod(.monotone)
                            LineMark(
                                x: .value("Day", Date(timeIntervalSince1970: point.at), unit: .day),
                                y: .value(metric.title, point.value)
                            )
                            .foregroundStyle(by: .value("Provider", series.title ?? MobileL10n.string("Other")))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: legend.map(\.title),
                    range: legend.map(\.color)
                )
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(theme.divider)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(theme.tertiaryLabel)
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 180)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Daily \(metric.title.lowercased()) chart")
                .accessibilityValue(chartSummary(projection))
                HStack(spacing: MobileDesign.Spacing.medium) {
                    ForEach(legend, id: \.title) { entry in
                        Label {
                            Text(entry.title).lineLimit(1)
                        } icon: {
                            Circle().fill(entry.color).frame(width: 7, height: 7)
                        }
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                    }
                    Spacer(minLength: 0)
                    Text("\(range.activeDayCount) active days")
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryLabel)
                }
            }
        }
    }

    /// The token totals as a strip the thumb runs along, each with the one line that gives
    /// its number a scale.
    private func statsStrip(_ range: RemoteUsageRangeDTO) -> some View {
        let tokens = range.tokens
        let observedInput = Double(tokens.cachedInput + tokens.uncachedInput)
        let cards: [(title: String, value: String, detail: String?)] = [
            (MobileL10n.string("Processed tokens"), compact(Double(tokens.processed)),
             range.activeDayCount > 0
                 ? MobileL10n.string("%@ per active day",
                                     compact(Double(tokens.processed) / Double(range.activeDayCount)))
                 : nil),
            (MobileL10n.string("Cached input"), compact(Double(tokens.cachedInput)),
             observedInput > 0
                 ? MobileL10n.string("%@ of observed input",
                                     percent(Double(tokens.cachedInput) / observedInput))
                 : nil),
            (MobileL10n.string("Uncached input"), compact(Double(tokens.uncachedInput)),
             MobileL10n.string("%@ cache writes", compact(Double(tokens.cacheWrite)))),
            (MobileL10n.string("Output"), compact(Double(tokens.output)),
             MobileL10n.string("Includes %@ reasoning", compact(Double(tokens.reasoning)))),
            (MobileL10n.string("Cache savings"), compactCurrency(range.cost.cacheSavingsUSD),
             range.cost.totalUSD > 0
                 ? MobileL10n.string("%@× the raw token cost",
                                     String(format: "%.1f", range.cost.cacheSavingsUSD / range.cost.totalUSD))
                 : nil),
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileDesign.Spacing.small) {
                ForEach(cards, id: \.title) { card in
                    UsageMetricCard(title: card.title, value: card.value, detail: card.detail)
                        .frame(width: 156)
                }
            }
            .padding(.horizontal, MobileDesign.Spacing.hairline)
        }
        .scrollClipDisabled()
    }

    /// Where the figure went, by model, project or account, in the Mac's own bounded rows.
    @ViewBuilder
    private func breakdown(_ range: RemoteUsageRangeDTO) -> some View {
        let available = range.breakdowns
        if !available.isEmpty {
            let current = available.first { $0.kind == breakdownKind } ?? available[0]
            let total = metric == .cost ? range.cost.totalUSD : Double(range.tokens.processed)
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle("Breakdown")
                    Spacer(minLength: MobileDesign.Spacing.small)
                    if available.count > 1 {
                        Picker("Breakdown", selection: $breakdownKind) {
                            ForEach(available, id: \.kind) { breakdown in
                                Text(breakdownTitle(breakdown.kind)).tag(breakdown.kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                UsageCard {
                    LazyVStack(spacing: 0) {
                        HStack {
                            Text(breakdownTitle(current.kind))
                            Spacer()
                            Text(metric.title)
                                .frame(width: 88, alignment: .trailing)
                            Text(MobileL10n.string("Share"))
                                .frame(width: 56, alignment: .trailing)
                        }
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryLabel)
                        .padding(.bottom, MobileDesign.Spacing.small)
                        ForEach(Array(current.rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider().overlay(theme.divider) }
                            let value = metric == .cost ? row.costUSD : Double(row.tokens)
                            HStack {
                                Text(row.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: MobileDesign.Spacing.small)
                                Text(metricValue(value))
                                    .monospacedDigit()
                                    .frame(width: 88, alignment: .trailing)
                                Text(total > 0 ? percent(value / total) : MobileUsageDefaults.unknownValue)
                                    .monospacedDigit()
                                    .foregroundStyle(theme.secondaryLabel)
                                    .frame(width: 56, alignment: .trailing)
                            }
                            .font(.subheadline)
                            .padding(.vertical, MobileDesign.Spacing.small)
                        }
                        if current.omittedRowCount > 0 {
                            Divider().overlay(theme.divider)
                            HStack {
                                Text(MobileL10n.string("+%lld more", Int64(current.omittedRowCount)))
                                Spacer()
                                Text(metricValue(
                                    metric == .cost ? current.omittedCostUSD : Double(current.omittedTokens)
                                ))
                                .monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(theme.tertiaryLabel)
                            .padding(.top, MobileDesign.Spacing.small)
                        }
                    }
                }
            }
        }
    }

    private func breakdownTitle(_ kind: RemoteUsageBreakdownKindDTO) -> String {
        switch kind {
        case .models: return MobileL10n.string("Models")
        case .projects: return MobileL10n.string("Projects")
        case .accounts: return MobileL10n.string("Accounts")
        case .providers: return MobileL10n.string("Providers")
        }
    }

    /// How much of the figure is measured, how much estimated, and what the cache saved.
    private func costQuality(_ range: RemoteUsageRangeDTO) -> some View {
        let total = range.cost.totalUSD
        let rows: [(String, String)] = [
            (MobileL10n.string("Provider reported"),
             total > 0 ? percent(range.cost.providerReportedUSD / total) : MobileUsageDefaults.unknownValue),
            (MobileL10n.string("Model priced"),
             total > 0 ? percent(range.cost.catalogPricedUSD / total) : MobileUsageDefaults.unknownValue),
            (MobileL10n.string("Unpriced"),
             range.tokens.processed > 0
                 ? percent(Double(range.cost.unpricedTokens) / Double(range.tokens.processed))
                 : MobileUsageDefaults.unknownValue),
            (MobileL10n.string("Cache savings"), compactCurrency(range.cost.cacheSavingsUSD)),
        ]
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            sectionTitle("Cost quality")
            UsageCard {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().overlay(theme.divider) }
                        HStack {
                            Text(row.0)
                                .foregroundStyle(theme.secondaryLabel)
                            Spacer()
                            Text(row.1)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                        .padding(.vertical, MobileDesign.Spacing.small)
                    }
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
            sectionTitle("Limit history")
            UsageCard {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                    if let account = selectedAccount, account.windows.count > 1 {
                        Picker("Window", selection: Binding(
                            get: { model.selectedLimitID ?? "" },
                            set: { model.selectedLimitID = $0 }
                        )) {
                            ForEach(account.windows) { window in
                                Text(window.windowLabel).tag(window.id)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else if let selected = model.limitSeries.first(where: {
                        $0.id == model.selectedLimitID
                    }) {
                        UsageSeriesSelectionLabel(series: selected)
                    }
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
                            .foregroundStyle(reset.cause == .bankedCredit ? theme.positive : theme.secondaryLabel)
                            .lineStyle(.init(lineWidth: reset.cause == .bankedCredit ? 2 : 1, dash: [3, 3]))
                    }

                    if let expiry = detail.series.nextBankedResetExpiresAt {
                        RuleMark(x: .value("Banked reset expiry", Date(timeIntervalSince1970: expiry)))
                            .foregroundStyle(theme.negative)
                            .lineStyle(.init(lineWidth: 2, dash: [2, 3]))
                    }
                }
                .chartXScale(domain: MobileUsageLimitChartDomain.range(for: detail))
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
                .accessibilityLabel(MobileL10n.string("Limit history chart"))
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

    private func coverageSymbol(_ state: RemoteUsageCoverageState) -> String {
        switch state {
        case .complete: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .failed: return "xmark.octagon.fill"
        default: return "questionmark.circle"
        }
    }

    private func coverageTitle(_ state: RemoteUsageCoverageState) -> String {
        switch state {
        case .complete: return MobileL10n.string("Complete")
        case .partial: return MobileL10n.string("Partial")
        case .failed: return MobileL10n.string("Failed")
        default: return MobileL10n.string("Unavailable")
        }
    }

    private func coverageColor(_ state: RemoteUsageCoverageState) -> Color {
        switch state {
        case .complete: return theme.positive
        case .partial: return theme.warning
        case .failed: return theme.negative
        default: return theme.secondaryLabel
        }
    }

    /// The same spelling the Mac uses, from the same implementation: the phone renders the
    /// prepared values the desktop prepared, so the two cannot disagree about how a dollar
    /// reads. See `UsageValueFormat`.
    private func currency(_ value: Double) -> String {
        UsageValueFormat.currency(value)
    }

    /// For a tile whose width is the grid's rather than the number's — the same rule the Mac's
    /// stats band follows.
    private func compactCurrency(_ value: Double) -> String {
        UsageValueFormat.compactCurrency(value)
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
                    state: .complete,
                    sourceCount: 2,
                    recordCount: 2_814,
                    detail: nil
                ),
                .init(
                    runtimeID: "claude",
                    runtimeName: "Claude Code",
                    state: .complete,
                    sourceCount: 1,
                    recordCount: 1_492,
                    detail: nil
                ),
                .init(
                    runtimeID: "openCode",
                    runtimeName: "OpenCode",
                    state: .partial,
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
        let value = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey] ?? ""
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
                    cause: .bankedCredit,
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
            nextBankedResetExpiresAt: now + 28 * 86_400
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
