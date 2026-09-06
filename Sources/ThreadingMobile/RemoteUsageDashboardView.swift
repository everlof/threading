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

/// Places the clock on a provider window without asking the phone to receive its full history.
/// `resetsAt - windowDuration` is the start; the normalized distance from there to `referenceTime`
/// is the same pace comparison the Mac's usage bars draw.
enum MobileUsageCapacityProjection {
    static func elapsedFraction(
        for window: RemoteUsageLimitSeriesSummaryDTO,
        at referenceTime: Double
    ) -> Double? {
        guard let reset = window.resetsAt,
              let duration = window.windowDuration,
              reset.isFinite,
              duration.isFinite,
              duration > 0,
              referenceTime.isFinite else { return nil }
        let elapsed = duration - (reset - referenceTime)
        return min(max(elapsed / duration, 0), 1)
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

/// The dates a time axis labels: whole days on an even step, none so near either end of the
/// domain that the label centred on it would be cut. Swift Charts places its automatic ticks
/// without regard to the label's width and truncates one that runs past the plot's edge rather
/// than moving it, so a weekly tick two days before a projected reset read "18…"; padding the
/// plot does not help, the label is cut at the plot however wide the card is. The step is the
/// smallest of the ladder that keeps the count near `desiredCount`; weeks start on the
/// calendar's first weekday and months on their first day, the way the automatic axis chose
/// them.
enum MobileUsageAxisTicks {
    /// The share of the span a label reaches past its tick: half a short date at the caption
    /// size against a phone-wide plot that has given its leading edge to the value axis. A tick
    /// nine per cent from the end was still cut.
    static let edgeClearance = 0.12
    static let dayStepLadder = [1, 2, 3, 7, 14]
    /// How far past `desiredCount` a step may run before the next coarser one is taken: the
    /// automatic axis put four weekly ticks on a month asked for three, and a fortnightly step
    /// there leaves one label on the whole chart.
    static let countTolerance = 2

    static func dates(
        in domain: ClosedRange<Date>,
        desiredCount: Int,
        calendar: Calendar = .current
    ) -> [Date] {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0, span.isFinite, desiredCount > 0 else { return [] }
        let clearance = span * edgeClearance
        let fits: (Date) -> Bool = { date in
            date.timeIntervalSince(domain.lowerBound) >= clearance
                && domain.upperBound.timeIntervalSince(date) >= clearance
        }
        let allowed = Double(desiredCount + countTolerance)
        let stepDays = dayStepLadder.first { span / (Double($0) * 86_400) <= allowed }
        var ticks: [Date] = []
        if let stepDays {
            var cursor = calendar.startOfDay(for: domain.lowerBound)
            if stepDays >= 7 {
                while calendar.component(.weekday, from: cursor) != calendar.firstWeekday {
                    guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                    cursor = next
                }
            }
            while cursor <= domain.upperBound {
                if fits(cursor) { ticks.append(cursor) }
                guard let next = calendar.date(byAdding: .day, value: stepDays, to: cursor) else { break }
                cursor = next
            }
        } else {
            let monthStep = max(1, Int((span / (30 * 86_400) / allowed).rounded(.up)))
            var components = calendar.dateComponents([.year, .month], from: domain.lowerBound)
            components.day = 1
            var cursor = calendar.date(from: components) ?? domain.lowerBound
            while cursor <= domain.upperBound {
                if fits(cursor) { ticks.append(cursor) }
                guard let next = calendar.date(byAdding: .month, value: monthStep, to: cursor) else { break }
                cursor = next
            }
        }
        return ticks
    }
}

/// The daily chart's bands, each standing on the one beneath it so the top edge is the day's
/// total and a band's own height is its share: the Mac's additive composition, stated for
/// Swift Charts. The edges are built here rather than left to each mark, because an `AreaMark`
/// stacks itself by default and a `LineMark` never does — the chart used to draw every
/// provider's outline at that provider's own height, which for the smaller one ran through the
/// middle of the band above it and read as a third series nobody had named.
///
/// Series that do not share one timestamp sequence cannot be summed honestly; they fall back to
/// standing on zero independently, the same degradation the Mac's band chart makes.
enum MobileUsageStackProjection {
    struct Band: Equatable, Identifiable {
        struct Edge: Equatable {
            let at: Double
            let lower: Double
            let upper: Double
        }

        let id: String
        let title: String?
        let isOther: Bool
        let styleIndex: Int
        let edges: [Edge]
    }

    static func isAligned(_ series: [RemoteUsageChartSeriesDTO]) -> Bool {
        guard let first = series.first else { return true }
        let timestamps = first.points.map(\.at)
        return series.dropFirst().allSatisfy { $0.points.map(\.at) == timestamps }
    }

    static func bands(for series: [RemoteUsageChartSeriesDTO]) -> [Band] {
        let stacked = isAligned(series)
        var floor: [Double: Double] = [:]
        return series.map { entry in
            let edges = entry.points.map { point -> Band.Edge in
                let lower = stacked ? (floor[point.at] ?? 0) : 0
                let upper = lower + max(0, point.value)
                if stacked { floor[point.at] = upper }
                return Band.Edge(at: point.at, lower: lower, upper: upper)
            }
            return Band(
                id: entry.id,
                title: entry.title,
                isOther: entry.isOther,
                styleIndex: entry.styleIndex,
                edges: edges
            )
        }
    }
}

/// The phone's reading of `UsageLimitChartForm` over the wire values: which form the selected
/// window's history takes, and the columns when it takes the dense one. The decision itself is
/// shared with the Mac, so both screens answer the same way about the same observations.
enum MobileUsageLimitChartProjection {
    typealias Form = UsageLimitChartForm
    typealias Peak = UsageLimitChartForm.Peak

    static var maximumBuckets: Int { UsageLimitChartForm.maximumBuckets }
    static var dayBucket: TimeInterval { UsageLimitChartForm.dayBucket }

    static func form(for detail: RemoteUsageLimitDTO) -> Form {
        // Without a stated window length, the discontinuities the Mac observed stand in.
        let segments = (detail.observed.last?.segment ?? 0) + 1
        return UsageLimitChartForm.resolve(
            span: detail.end - detail.start,
            windowDuration: detail.series.windowDuration,
            observedCycles: max(segments, detail.recordedResetCount + 1)
        )
    }

    static func peaks(
        for detail: RemoteUsageLimitDTO,
        bucket: TimeInterval,
        calendar: Calendar = .current
    ) -> [Peak] {
        UsageLimitChartForm.peaks(
            detail.observed.map { UsageLimitChartObservation(at: $0.at, fraction: $0.fraction) },
            start: detail.start,
            end: detail.end,
            bucket: bucket,
            calendar: calendar
        )
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
    @Published private(set) var isUsingBankedReset = false
    @Published private(set) var bankedResetStatusMessage: String?
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

    func prepareBankedReset(
        seriesID: String
    ) async -> RemoteBankedUsageResetOfferDTO? {
        guard !isUsingBankedReset else { return nil }
        isUsingBankedReset = true
        bankedResetStatusMessage = nil
        defer { isUsingBankedReset = false }
        do {
            if isDemo,
               let series = limitSeries.first(where: { $0.id == seriesID }),
               let count = series.bankedResetCount,
               count > 0 {
                return RemoteBankedUsageResetOfferDTO(
                    seriesID: seriesID,
                    accountName: series.accountName,
                    availableCount: count,
                    offerFingerprint: String(repeating: "d", count: 64),
                    selectedCreditTitle: MobileL10n.string("Banked usage reset"),
                    selectedCreditExpiresAt: series.nextBankedResetExpiresAt,
                    letsProviderChooseCredit: false,
                    eligibleWindowLabels: [series.windowLabel],
                    owedContinuationCount: 1
                )
            }
            return try await client.fetchBankedUsageResetOffer(seriesID: seriesID)
        } catch is CancellationError {
            return nil
        } catch {
            limitErrorMessage = error.localizedDescription
            return nil
        }
    }

    func consumeBankedReset(
        _ offer: RemoteBankedUsageResetOfferDTO,
        days: Int
    ) async {
        guard !isUsingBankedReset else { return }
        isUsingBankedReset = true
        bankedResetStatusMessage = nil
        defer { isUsingBankedReset = false }
        do {
            let result = isDemo
                ? RemoteBankedUsageResetResponseDTO(
                    outcome: .reset,
                    remainingCreditCount: max(0, offer.availableCount - 1),
                    releasedContinuationCount: offer.owedContinuationCount,
                    hasVerifiedHeadroom: true,
                    continuationReleaseFailed: false
                )
                : try await client.consumeBankedUsageReset(offer)
            bankedResetStatusMessage = Self.bankedResetMessage(result)
            guard !isDemo else { return }
            await fetchDashboard(initial: false)
            await loadLimit(seriesID: offer.seriesID, days: days, force: true)
        } catch is CancellationError {
            return
        } catch {
            limitErrorMessage = error.localizedDescription
        }
    }

    private static func bankedResetMessage(
        _ result: RemoteBankedUsageResetResponseDTO
    ) -> String {
        switch result.outcome {
        case .reset:
            if !result.hasVerifiedHeadroom {
                return MobileL10n.string(
                    "Codex used the reset, but the account still reports a full usage window. Waiting chats were not released."
                )
            }
            if result.continuationReleaseFailed {
                return MobileL10n.string(
                    "Codex used the reset, but Threading could not release waiting continuations."
                )
            }
            return result.releasedContinuationCount == 0
                ? MobileL10n.string("Codex used the banked reset.")
                : MobileL10n.string(
                    "Codex used the reset · %lld continuations released.",
                    Int64(result.releasedContinuationCount)
                )
        case .alreadyRedeemed:
            if !result.hasVerifiedHeadroom {
                return MobileL10n.string(
                    "Codex confirmed that reset was already used, but the account still reports a full usage window."
                )
            }
            return MobileL10n.string("Codex confirmed that reset was already used.")
        case .nothingToReset:
            return MobileL10n.string("Codex found no eligible limit to reset.")
        case .noCredit:
            return MobileL10n.string("Codex found no banked reset available.")
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
    @State private var pendingBankedReset: RemoteBankedUsageResetOfferDTO?
    @State private var isConfirmingBankedReset = false

    init(link: RemoteConnectionLink, isDemo: Bool, focus: MobileUsageAccountFocus? = nil) {
        self.isDemo = isDemo
        self.focus = focus
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        demoShowsStaleSnapshot = environment[MobileDemoScene.environmentKey] == "usage-stale"
            || environment["THREADING_MOBILE_UI_EVIDENCE_ID"]?.contains("usage-stale") == true
        demoStartsAtLimitHistory = environment[MobileDemoScene.environmentKey]?
            .hasPrefix("usage-limit") == true
        switch environment[MobileDemoScene.environmentKey].flatMap(MobileDemoFixture.init(rawValue:)) {
        case .usageTotals:
            _scope = State(initialValue: .totals)
        case .usageLimitDenseWeek:
            _limitDays = State(initialValue: 7)
        case .usageLimitDenseQuarter:
            _limitDays = State(initialValue: 90)
        default:
            break
        }
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
    /// login when the series first arrive, otherwise the login that owns the series the model
    /// already selected — the Mac lists its current account's windows first, and the demo names
    /// the window a scene is about — then the first login when the selected one disappears, and
    /// the selected login's first live window whenever the history points elsewhere. Starting
    /// on the alphabetically first login regardless used to move every scene onto one Claude
    /// window, so the three banked-reset captures all showed the same Codex-less history.
    private func syncAccountSelection() {
        let accounts = fleetAccounts
        if selectedAccountID == nil || !accounts.contains(where: { $0.id == selectedAccountID }) {
            let focused = focus.flatMap { _ in
                MobileUsageFleetProjection.startingAccountID(in: accounts, focus: focus)
            }
            let owner = model.selectedLimitID.flatMap { id in
                accounts.first { $0.windows.contains { $0.id == id } }?.id
            }
            selectedAccountID = focused
                ?? owner
                ?? MobileUsageFleetProjection.startingAccountID(in: accounts, focus: nil)
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

    /// The scope picker, and beneath it only what the reader cannot see for themselves: the
    /// snapshot's age while it is stale, offline or being rebuilt. The caption that used to
    /// stand there — "Per login — its windows and history", "Across all 7 logins" — restated the
    /// segment above it and the rail of logins below, and a green dot beside it said "fresh"
    /// about a page that is fresh nearly always.
    private var scopeHeader: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Picker("Scope", selection: $scope) {
                ForEach(MobileUsageScope.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            if let dashboard = model.dashboard, !snapshotIsCurrent(dashboard) {
                HStack {
                    Spacer(minLength: MobileDesign.Spacing.small)
                    snapshotFreshnessBadge(dashboard)
                }
            }
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
            let snapshotTime = model.dashboard?.preparedAt ?? Date().timeIntervalSince1970
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                accountRail(accounts)
                if let account = selectedAccount {
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                        sectionTitle("Current capacity")
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            capacityCard(
                                account,
                                snapshotTime: snapshotTime,
                                clockTime: isDemo
                                    ? snapshotTime
                                    : context.date.timeIntervalSince1970
                            )
                        }
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
        snapshotTime: Double,
        clockTime: Double
    ) -> some View {
        let activeWindows = account.windows.filter {
            ($0.resetsAt ?? .greatestFiniteMagnitude) > snapshotTime
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
                                Text(livePercent(window, referenceTime: snapshotTime))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }
                            MobileUsageCapacityBar(
                                fraction: liveFraction(window, referenceTime: snapshotTime),
                                timeMark: MobileUsageCapacityProjection.elapsedFraction(
                                    for: window,
                                    at: clockTime
                                ),
                                tint: capacityColor(window, referenceTime: snapshotTime)
                            )
                            if let reset = window.resetsAt, reset > snapshotTime {
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
                    .accessibilityValue(capacityAccessibilityValue(
                        window,
                        snapshotTime: snapshotTime,
                        clockTime: clockTime
                    ))
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

    private func capacityAccessibilityValue(
        _ window: RemoteUsageLimitSeriesSummaryDTO,
        snapshotTime: Double,
        clockTime: Double
    ) -> String {
        let used = livePercent(window, referenceTime: snapshotTime)
        guard let elapsed = MobileUsageCapacityProjection.elapsedFraction(
            for: window,
            at: clockTime
        ) else { return used }
        return MobileL10n.string(
            "%@ used · current time is %@ through the window",
            used,
            percent(elapsed)
        )
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

    /// The days of the period as bands standing on one another, one per provider, under the
    /// metric toggle. Each band is a translucent fill with its own top edge drawn over it: the
    /// edge is the provider's cumulative height, so the outline never wanders through a
    /// neighbour and the topmost edge is the day's total.
    private func dailyChart(_ range: RemoteUsageRangeDTO) -> some View {
        let projection = metricProjection(range)
        let bands = MobileUsageStackProjection.bands(for: projection.chartSeries)
        let legend = bands.map { band in
            (title: band.title ?? MobileL10n.string("Other"),
             color: seriesColor(band.styleIndex, isOther: band.isOther))
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
                    ForEach(bands) { band in
                        let color = seriesColor(band.styleIndex, isOther: band.isOther)
                        ForEach(band.edges, id: \.at) { edge in
                            AreaMark(
                                x: .value("Day", Date(timeIntervalSince1970: edge.at), unit: .day),
                                yStart: .value("From", edge.lower),
                                yEnd: .value(metric.title, edge.upper),
                                series: .value("Provider", band.id)
                            )
                            .foregroundStyle(color.opacity(MobileDesign.Chart.bandOpacity))
                            .interpolationMethod(.monotone)
                            LineMark(
                                x: .value("Day", Date(timeIntervalSince1970: edge.at), unit: .day),
                                y: .value(metric.title, edge.upper),
                                series: .value("Provider", band.id)
                            )
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(
                                lineWidth: MobileDesign.Chart.bandEdgeWidth,
                                lineCap: .round,
                                lineJoin: .round
                            ))
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: dailyTicks(range)) { _ in
                        AxisGridLine().foregroundStyle(theme.divider)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(theme.tertiaryLabel)
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: MobileDesign.Chart.dailyHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Daily \(metric.title.lowercased()) chart")
                .accessibilityValue(chartSummary(projection))
                HStack(spacing: MobileDesign.Spacing.medium) {
                    ForEach(legend, id: \.title) { entry in
                        chartLegend(entry.title, color: entry.color, symbol: "circle.fill")
                    }
                    Spacer(minLength: 0)
                    Text("\(range.activeDayCount) active days")
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryLabel)
                }
            }
        }
    }

    private func dailyTicks(_ range: RemoteUsageRangeDTO) -> [Date] {
        MobileUsageAxisTicks.dates(
            in: Date(timeIntervalSince1970: range.start)...Date(timeIntervalSince1970: max(range.start, range.end)),
            desiredCount: 3
        )
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
        // Edge to edge with the page inset as scroll-content margins, like the login rail: the
        // strip's cards then run under the screen's edge as a carousel does, instead of being
        // cut off at the page margin with the ground showing beside the cut.
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileDesign.Spacing.small) {
                ForEach(cards, id: \.title) { card in
                    UsageMetricCard(title: card.title, value: card.value, detail: card.detail)
                        .frame(width: 156)
                }
            }
            .padding(.vertical, MobileDesign.Spacing.hairline)
        }
        .contentMargins(.horizontal, MobileDesign.Spacing.inset, for: .scrollContent)
        .padding(.horizontal, -MobileDesign.Spacing.inset)
    }

    /// Where the figure went, by model, project or account, in the Mac's own bounded rows.
    @ViewBuilder
    private func breakdown(_ range: RemoteUsageRangeDTO) -> some View {
        let available = range.breakdowns
        if !available.isEmpty {
            let current = available.first { $0.kind == breakdownKind } ?? available[0]
            let total = metric == .cost ? range.cost.totalUSD : Double(range.tokens.processed)
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                sectionTitle("Breakdown")
                if available.count > 1 {
                    breakdownRail(available)
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

    /// The breakdown selector as a horizontally scrollable pill rail rather than a segmented
    /// control. Four localized labels — "Providers" is "Leverantörer" — cannot share one screen
    /// width as fixed segments without running off it or being clipped; a rail shows each label
    /// in full, scrolls to the rest, and brings the chosen one into view. The same idiom, and
    /// the same edge-to-edge margins, as `accountRail`.
    private func breakdownRail(_ available: [RemoteUsageBreakdownDTO]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    ForEach(available, id: \.kind) { breakdown in
                        breakdownChip(breakdown.kind, isSelected: breakdown.kind == breakdownKind)
                            .id(breakdown.kind)
                    }
                }
                .padding(.vertical, MobileDesign.Spacing.hairline)
            }
            .contentMargins(.horizontal, MobileDesign.Spacing.inset, for: .scrollContent)
            .padding(.horizontal, -MobileDesign.Spacing.inset)
            .onChange(of: breakdownKind) { _, kind in
                withAnimation(.easeOut(duration: MobileDesign.Motion.controlResponse)) {
                    proxy.scrollTo(kind, anchor: .center)
                }
            }
        }
    }

    private func breakdownChip(
        _ kind: RemoteUsageBreakdownKindDTO,
        isSelected: Bool
    ) -> some View {
        Button {
            breakdownKind = kind
        } label: {
            Text(breakdownTitle(kind))
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.label : theme.secondaryLabel)
                .lineLimit(1)
                .padding(.horizontal, MobileDesign.Spacing.medium)
                .frame(height: MobileDesign.Size.compactControl)
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
        .accessibilityLabel(breakdownTitle(kind))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
            // One card, one heading: the window and range choosers, the chart they control, and
            // the selected window's readings as quiet rows beneath it. This used to be three
            // blocks — a card of two pickers, a "Current window" grid of four tiles, then a
            // second card titled Limit history again — so the controls stood a screen away from
            // the chart they changed, the heading appeared twice, and the tiles' largest text
            // on the page was "Unavailable", twice.
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

                    if model.isLoadingLimit, model.limit == nil {
                        HStack(spacing: MobileDesign.Spacing.medium) {
                            ProgressView().tint(theme.accent)
                            Text("Preparing selected history…")
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryLabel)
                        }
                        .frame(maxWidth: .infinity, minHeight: MobileDesign.Chart.limitHeight)
                    } else if let detail = selectedLimit {
                        limitChart(detail)
                        Divider().overlay(theme.divider)
                        limitSummaryRows(detail)
                        if detail.series.canRedeemBankedReset == true {
                            Divider().overlay(theme.divider)
                            bankedResetButton(detail.series)
                        }
                        if let status = model.bankedResetStatusMessage {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryLabel)
                        }
                    } else if let message = model.limitErrorMessage {
                        Label {
                            Text(message)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(theme.warning)
                        }
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                        .frame(maxWidth: .infinity, minHeight: MobileDesign.Chart.limitHeight)
                    }
                }
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

    private func bankedResetButton(
        _ series: RemoteUsageLimitSeriesSummaryDTO
    ) -> some View {
        Button {
            actionTask?.cancel()
            actionTask = Task {
                guard let offer = await model.prepareBankedReset(seriesID: series.id) else { return }
                pendingBankedReset = offer
                isConfirmingBankedReset = true
            }
        } label: {
            if model.isUsingBankedReset {
                HStack {
                    ProgressView()
                    Text("Checking banked reset…")
                }
                .frame(maxWidth: .infinity)
            } else {
                Label("Use Banked Reset", systemImage: "arrow.counterclockwise.circle")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(MobileThemedActionButtonStyle(
            kind: .primary,
            theme: theme
        ))
        .disabled(model.isUsingBankedReset)
        .frame(minHeight: MobileDesign.Size.minimumTapTarget)
        .themedConfirmationDialog(
            "Use a banked reset?",
            message: pendingBankedReset.map(bankedResetConfirmationMessage),
            isPresented: $isConfirmingBankedReset,
            actions: pendingBankedReset.map { offer in
                [
                    ThemedDialogAction("Use Banked Reset", role: .destructive) {
                        actionTask?.cancel()
                        actionTask = Task { await model.consumeBankedReset(offer, days: limitDays) }
                    },
                    ThemedDialogAction("Cancel", role: .cancel)
                ]
            } ?? [ThemedDialogAction("Cancel", role: .cancel)]
        )
    }

    private func bankedResetConfirmationMessage(
        _ offer: RemoteBankedUsageResetOfferDTO
    ) -> String {
        let count = MobileL10n.string(
            "This permanently spends 1 of %lld banked resets for %@.",
            Int64(offer.availableCount),
            offer.accountName
        )
        let credit: String
        if offer.letsProviderChooseCredit {
            credit = MobileL10n.string(
                "Codex did not report individual credits, so Codex will choose which reset to use."
            )
        } else {
            let title = offer.selectedCreditTitle ?? MobileL10n.string("Banked usage reset")
            let expiry = offer.selectedCreditExpiresAt.map {
                MobileL10n.string("expires %@", exactDateTime($0))
            } ?? MobileL10n.string("no expiry reported")
            credit = MobileL10n.string("Credit: %@ · %@.", title, expiry)
        }
        let windows = offer.eligibleWindowLabels.isEmpty
            ? MobileL10n.string("Eligible windows: determined by Codex.")
            : MobileL10n.string(
                "Eligible windows: %@.",
                offer.eligibleWindowLabels.joined(separator: ", ")
            )
        let continuation = offer.owedContinuationCount == 0
            ? MobileL10n.string("No chat message will be created or sent by this reset.")
            : MobileL10n.string(
                "%lld existing “continue on reset” messages for this account will be released only after Codex confirms new headroom. No message will be created or sent for any other chat.",
                Int64(offer.owedContinuationCount)
            )
        return [
            count,
            credit,
            windows,
            MobileL10n.string("The next reset date for an affected window may move."),
            continuation
        ].joined(separator: "\n\n")
    }

    /// A snapshot that is recent, complete and not being replaced has nothing to say for itself.
    private func snapshotIsCurrent(_ dashboard: RemoteUsageDashboardDTO) -> Bool {
        snapshotIsFresh(dashboard) && model.errorMessage == nil
            && !dashboard.isBuilding && !model.isRefreshing
    }

    private func snapshotFreshnessBadge(_ dashboard: RemoteUsageDashboardDTO) -> some View {
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

    /// The selected window's readings as rows: the title in the quiet ink, the figure against
    /// the trailing edge and its one explaining line beneath. The same shape as Cost quality,
    /// so a value that is not there reads as an ordinary row saying so rather than as the
    /// page's loudest figure. Banked resets keep their three distinct answers — a count,
    /// an authoritative zero, and not reported.
    private func limitSummaryRows(_ detail: RemoteUsageLimitDTO) -> some View {
        let banked = bankedResetPresentation(detail.series)
        let projection = projectionPresentation(detail)
        let used = usedPresentation(detail)
        let rows: [(title: String, value: String, detail: String?, isPlaceholder: Bool)] = [
            (MobileL10n.string("Used"), used.value, used.detail, used.isPlaceholder),
            (projection.title, projection.value, projection.detail, detail.projection == nil),
            (MobileL10n.string("Recorded resets"),
             String(detail.recordedResetCount),
             detail.restoredPaceFraction > 0
                 ? MobileL10n.string("%@ restored pace", percent(detail.restoredPaceFraction))
                 : MobileL10n.string("Observed reset boundaries"),
             false),
            (MobileL10n.string("Banked resets"),
             banked.value,
             banked.detail,
             detail.series.bankedResetCount == nil),
        ]
        return LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().overlay(theme.divider) }
                HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.medium) {
                    Text(row.title)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                    Spacer(minLength: MobileDesign.Spacing.small)
                    VStack(alignment: .trailing, spacing: MobileDesign.Spacing.hairline) {
                        Text(row.value)
                            .font(.subheadline.weight(row.isPlaceholder ? .regular : .semibold))
                            .monospacedDigit()
                            .foregroundStyle(row.isPlaceholder ? theme.tertiaryLabel : theme.label)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(theme.tertiaryLabel)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.vertical, MobileDesign.Spacing.small)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// What the window is at now. A reading whose scheduled reset has already passed is not a
    /// current reading — the window ended — so the row says that instead of "Resets 2 days
    /// ago", which is what the reset date read as once the window it belonged to was gone.
    private func usedPresentation(
        _ detail: RemoteUsageLimitDTO
    ) -> (value: String, detail: String?, isPlaceholder: Bool) {
        let reference = model.dashboard?.preparedAt ?? detail.preparedAt
        if let reset = detail.series.resetsAt, reset <= reference {
            return (
                MobileUsageDefaults.unknownValue,
                MobileL10n.string("Window ended %@ · %@", relativeDate(reset), exactDateTime(reset)),
                true
            )
        }
        guard let fraction = detail.series.currentFraction else {
            return (MobileL10n.string("Unavailable"), nil, true)
        }
        return (
            percent(fraction),
            detail.series.resetsAt.map {
                MobileL10n.string("Resets %@ · %@", relativeDate($0), exactDateTime($0))
            },
            false
        )
    }

    /// One window's history in whichever form its density allows: the observed line with its
    /// resets ruled through it, or — for a window that cycles too often for a line to be read —
    /// one column per bucket at the highest reading it reached, the ones that reached the limit
    /// in the negative role. Scheduled resets are not drawn in the column form; a window that
    /// resets every five hours resets every five hours, and the count stands in the rows below.
    /// Banked-credit resets and a pending expiry are rarer and stay ruled in both forms.
    /// The marks one window's chart carries, decided once so the plot, its legend and its
    /// accessibility summary agree about what is on it.
    private struct LimitChartPlan {
        let form: MobileUsageLimitChartProjection.Form
        let peaks: [MobileUsageLimitChartProjection.Peak]
        let columns: [PeakColumn]
        let ruledResets: [RemoteUsageLimitResetDTO]
        let drawsProjection: Bool
        let drawsScheduledResets: Bool
        let hasBankedResets: Bool
        let drawsExpiry: Bool

        var reachedLimit: Bool { peaks.contains(where: \.reachedLimit) }
    }

    private func limitChartPlan(_ detail: RemoteUsageLimitDTO) -> LimitChartPlan {
        let form = MobileUsageLimitChartProjection.form(for: detail)
        var peaks: [MobileUsageLimitChartProjection.Peak] = []
        var columns: [PeakColumn] = []
        if case .peaks(let bucket) = form {
            peaks = MobileUsageLimitChartProjection.peaks(for: detail, bucket: bucket)
            let inset = bucket * MobileDesign.Chart.columnGapFraction / 2
            columns = peaks.map { peak in
                PeakColumn(
                    id: peak.id,
                    from: Date(timeIntervalSince1970: peak.start + inset),
                    to: Date(timeIntervalSince1970: peak.end - inset),
                    top: peak.fraction,
                    color: (peak.reachedLimit ? theme.negative : theme.accent)
                        .opacity(MobileDesign.Chart.columnOpacity)
                )
            }
        }
        let isLine = form == .line
        let domain = MobileUsageLimitChartDomain.range(for: detail)
        return LimitChartPlan(
            form: form,
            peaks: peaks,
            columns: columns,
            ruledResets: detail.resets.filter { $0.cause == .bankedCredit || isLine },
            drawsProjection: isLine && detail.projection != nil,
            drawsScheduledResets: isLine && detail.resets.contains { $0.cause != .bankedCredit },
            hasBankedResets: detail.resets.contains { $0.cause == .bankedCredit },
            drawsExpiry: detail.series.nextBankedResetExpiresAt.map {
                domain.contains(Date(timeIntervalSince1970: $0))
            } ?? false
        )
    }

    /// One window's history in whichever form its density allows: the observed line with its
    /// resets ruled through it, or — for a window that cycles too often for a line to be read —
    /// one column per bucket at the highest reading it reached, the ones that reached the limit
    /// in the negative role. Scheduled resets are not drawn in the column form; a window that
    /// resets every five hours resets every five hours, and the count stands in the rows below.
    /// Banked-credit resets and a pending expiry are rarer and stay ruled in both forms.
    private func limitChart(_ detail: RemoteUsageLimitDTO) -> some View {
        let plan = limitChartPlan(detail)
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            Chart {
                observedMarks(detail, plan: plan)
                projectionMarks(detail, plan: plan)
                resetMarks(plan.ruledResets)
                expiryMarks(detail, plan: plan)
            }
            .chartXScale(domain: MobileUsageLimitChartDomain.range(for: detail))
            .chartYScale(domain: 0...1)
            // The value axis stands at the leading edge so the last date label has the card's
            // whole trailing margin to land in; against a trailing axis it was cut to "31 a…".
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 0.5, 1]) { value in
                    AxisGridLine().foregroundStyle(theme.divider)
                    AxisValueLabel {
                        if let fraction = value.as(Double.self) {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(theme.tertiaryLabel)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: MobileUsageAxisTicks.dates(
                    in: MobileUsageLimitChartDomain.range(for: detail),
                    desiredCount: 4
                )) { _ in
                    AxisGridLine().foregroundStyle(theme.divider)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(theme.tertiaryLabel)
                }
            }
            .frame(height: MobileDesign.Chart.limitHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MobileL10n.string("Limit history chart"))
            .accessibilityValue(limitChartSummary(detail, form: plan.form, peaks: plan.peaks))
            limitLegend(plan)
        }
    }

    private var observedStroke: StrokeStyle {
        StrokeStyle(lineWidth: MobileDesign.Chart.lineWidth, lineCap: .round, lineJoin: .round)
    }

    private var projectionStroke: StrokeStyle {
        StrokeStyle(
            lineWidth: MobileDesign.Chart.lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: MobileDesign.Chart.projectionDash
        )
    }

    private func markerStroke(emphasized: Bool) -> StrokeStyle {
        StrokeStyle(
            lineWidth: emphasized
                ? MobileDesign.Chart.emphasizedMarkerWidth
                : MobileDesign.Chart.markerWidth,
            dash: MobileDesign.Chart.markerDash
        )
    }

    /// Erased rather than built with a branch: the two forms are different mark types, and the
    /// chart builder's branching is what the compiler gave up on.
    private func observedMarks(_ detail: RemoteUsageLimitDTO, plan: LimitChartPlan) -> AnyChartContent {
        switch plan.form {
        case .line:
            return AnyChartContent(ForEach(detail.observed, id: \.at) { point in
                observedPointMarks(point)
            })
        case .peaks:
            return AnyChartContent(ForEach(plan.columns) { column in
                columnMark(column)
            })
        }
    }

    /// A rectangle rather than a bar: a bar takes a start and an end on one axis only, and a
    /// column that spans its bucket needs both edges stated on both.
    private func columnMark(_ column: PeakColumn) -> some ChartContent {
        RectangleMark(
            xStart: .value("From", column.from),
            xEnd: .value("To", column.to),
            yStart: .value("Baseline", column.baseline),
            yEnd: .value("Peak used", column.top)
        )
        .foregroundStyle(column.color)
        .cornerRadius(MobileDesign.Chart.columnRadius, style: .continuous)
    }

    @ChartContentBuilder
    private func observedPointMarks(_ point: RemoteUsageLimitPointDTO) -> some ChartContent {
        let at = Date(timeIntervalSince1970: point.at)
        AreaMark(
            x: .value("Observed at", at),
            y: .value("Used", point.fraction),
            series: .value("Observed segment", point.segment)
        )
        .foregroundStyle(theme.accent.opacity(MobileDesign.Chart.areaOpacity))
        LineMark(
            x: .value("Observed at", at),
            y: .value("Used", point.fraction),
            series: .value("Observed segment", point.segment)
        )
        .foregroundStyle(theme.accent)
        .lineStyle(observedStroke)
    }

    @ChartContentBuilder
    private func projectionMarks(_ detail: RemoteUsageLimitDTO, plan: LimitChartPlan) -> some ChartContent {
        if plan.drawsProjection, let projection = detail.projection {
            let from = Date(timeIntervalSince1970: projection.observedAt)
            let to = Date(timeIntervalSince1970: projection.projectedExhaustionAt ?? projection.resetsAt)
            let endFraction: Double = projection.projectedExhaustionAt == nil
                ? projection.projectedFractionAtReset
                : 1
            LineMark(
                x: .value("Projected from", from),
                y: .value("Projected use", projection.observedFraction),
                series: .value("Projection", "projection")
            )
            .foregroundStyle(theme.warning)
            .lineStyle(projectionStroke)
            LineMark(
                x: .value("Projected to", to),
                y: .value("Projected use", endFraction),
                series: .value("Projection", "projection")
            )
            .foregroundStyle(theme.warning)
            .lineStyle(projectionStroke)
        }
    }

    @ChartContentBuilder
    private func resetMarks(_ resets: [RemoteUsageLimitResetDTO]) -> some ChartContent {
        ForEach(resets) { reset in
            let isBanked = reset.cause == .bankedCredit
            RuleMark(x: .value("Reset", Date(timeIntervalSince1970: reset.detectedAt)))
                .foregroundStyle(isBanked ? theme.positive : theme.secondaryLabel)
                .lineStyle(markerStroke(emphasized: isBanked))
        }
    }

    @ChartContentBuilder
    private func expiryMarks(_ detail: RemoteUsageLimitDTO, plan: LimitChartPlan) -> some ChartContent {
        if plan.drawsExpiry, let expiry = detail.series.nextBankedResetExpiresAt {
            RuleMark(x: .value("Banked reset expiry", Date(timeIntervalSince1970: expiry)))
                .foregroundStyle(theme.negative)
                .lineStyle(markerStroke(emphasized: true))
        }
    }

    /// Only the marks that are on the chart are keyed: a legend that names a projection or an
    /// expiry the plot does not carry is a legend that lies about the plot.
    private func limitLegend(_ plan: LimitChartPlan) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 128), spacing: MobileDesign.Spacing.small)],
            alignment: .leading,
            spacing: MobileDesign.Spacing.small
        ) {
            switch plan.form {
            case .line:
                chartLegend(Text("Observed"), color: theme.accent, symbol: "circle.fill")
            case .peaks(let bucket):
                chartLegend(peakLegendTitle(bucket: bucket), color: theme.accent, symbol: "chart.bar.fill")
                if plan.reachedLimit {
                    chartLegend(Text("Limit reached"), color: theme.negative, symbol: "chart.bar.fill")
                }
            }
            if plan.drawsProjection {
                chartLegend(Text("Projection"), color: theme.warning, symbol: "line.diagonal")
            }
            if plan.drawsScheduledResets {
                chartLegend(Text("Reset"), color: theme.secondaryLabel, symbol: "arrow.counterclockwise")
            }
            if plan.hasBankedResets {
                chartLegend(Text("Banked reset"), color: theme.positive, symbol: "bolt.fill")
            }
            if plan.drawsExpiry {
                chartLegend(Text("Expiry"), color: theme.negative, symbol: "hourglass")
            }
        }
    }

    /// What a column stands for, by the bucket it spans: the window itself, a day, or a span of
    /// days.
    private func peakLegendTitle(bucket: TimeInterval) -> String {
        let day = MobileUsageLimitChartProjection.dayBucket
        if bucket < day {
            return MobileL10n.string("Peak per window")
        }
        let days = Int((bucket / day).rounded())
        return days <= 1
            ? MobileL10n.string("Peak per day")
            : MobileL10n.string("Peak per %lld days", Int64(days))
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

    private func limitChartSummary(
        _ detail: RemoteUsageLimitDTO,
        form: MobileUsageLimitChartProjection.Form,
        peaks: [MobileUsageLimitChartProjection.Peak]
    ) -> String {
        let observed = MobileL10n.string(
            "%lld observations, %lld recorded resets, %@ currently used",
            detail.observed.count,
            detail.recordedResetCount,
            detail.series.currentFraction.map(percent) ?? MobileL10n.string("unknown")
        )
        guard case .peaks = form else { return observed }
        let limitHits = peaks.filter(\.reachedLimit).count
        return observed + ". " + MobileL10n.string(
            "%lld columns of peak use, %lld reached the limit",
            Int64(peaks.count),
            Int64(limitHits)
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
            // The Mac projects only measured weekly windows; a five-hour window has no weekly
            // pace to extrapolate, and telling its reader to wait for more history would be
            // promising a figure that never comes.
            let isWeekly = detail.series.windowDuration.map { $0 >= 6 * 86_400 } ?? true
            return (
                MobileL10n.string("Projection"),
                MobileL10n.string("Unavailable"),
                isWeekly
                    ? MobileL10n.string("More history is needed")
                    : MobileL10n.string("Projected for weekly windows only")
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

    /// One legend key: the mark's colour on its glyph, the words in the quiet text ink. The
    /// text never wears the series colour — a light hue is illegible as text, and the swatch
    /// beside it is what carries identity.
    private func chartLegend(_ title: Text, color: Color, symbol: String) -> some View {
        Label {
            title.lineLimit(1)
        } icon: {
            if symbol == "circle.fill" {
                Circle()
                    .fill(color)
                    .frame(width: MobileDesign.Chart.legendSwatch, height: MobileDesign.Chart.legendSwatch)
            } else {
                Image(systemName: symbol).foregroundStyle(color)
            }
        }
        .font(.caption)
        .foregroundStyle(theme.secondaryLabel)
    }

    private func chartLegend(_ title: String, color: Color, symbol: String) -> some View {
        chartLegend(Text(verbatim: title), color: color, symbol: symbol)
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

/// One peak column as the chart draws it: its span with the gap already taken off each side,
/// its top, and its colour resolved — kept as plain values so the chart body stays simple
/// enough to type-check.
private struct PeakColumn: Identifiable {
    let id: Double
    let from: Date
    let to: Date
    let top: Double
    let color: Color
    let baseline: Double = 0
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

/// Native SwiftUI counterpart of the Mac's `UsageBarView`: usage remains the colored length,
/// while the neutral line is elapsed time. Keeping the two independent makes under/over pace
/// visible without changing the provider's percentage.
private struct MobileUsageCapacityBar: View {
    @Environment(\.remoteTheme) private var theme

    let fraction: Double
    let timeMark: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clampedFraction = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.controlResting)
                    .frame(height: MobileDesign.Size.usageCapacityBarHeight)
                Capsule()
                    .fill(tint)
                    .frame(
                        width: width * clampedFraction,
                        height: MobileDesign.Size.usageCapacityBarHeight
                    )
                if let timeMark {
                    let markWidth = MobileDesign.Size.usageTimeMarkWidth
                    let markOrigin = min(
                        max(width * min(max(timeMark, 0), 1) - markWidth / 2, 0),
                        max(0, width - markWidth)
                    )
                    Capsule()
                        .fill(theme.label.opacity(MobileDesign.Opacity.usageTimeMark))
                        .frame(
                            width: markWidth,
                            height: MobileDesign.Size.usageTimeMarkHeight
                        )
                        .offset(x: markOrigin)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: MobileDesign.Size.usageTimeMarkHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        if value.hasPrefix("usage-limit-dense") {
            return series.first(where: { ($0.windowDuration ?? .infinity) < 86_400 })?.id
                ?? series.first?.id
        }
#endif
        return series.first?.id
    }

    static func limit(seriesID: String, days: Int) throws -> RemoteUsageLimitDTO {
        guard let summary = limitSummaries.first(where: { $0.id == seriesID }) else {
            throw RemoteClientError.invalidResponse
        }
        let start = now - Double(days) * 86_400
        if let duration = summary.windowDuration, duration < 86_400 {
            return denseLimit(summary: summary, days: days, start: start, windowDuration: duration)
        }
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

    /// A window that cycles many times a day, the way a five-hour session window does: every
    /// window climbs from near empty to its own peak — some of them to the limit — and the next
    /// starts low again, with the scheduled reset recorded between the two. Bounded to what the
    /// wire carries, a hundred windows spaced evenly through the range, since the phone only
    /// ever receives the Mac's downsampled series. No projection: the Mac projects weekly
    /// windows only.
    private static func denseLimit(
        summary: RemoteUsageLimitSeriesSummaryDTO,
        days: Int,
        start: Double,
        windowDuration: Double
    ) -> RemoteUsageLimitDTO {
        let span = Double(days) * 86_400
        let windowCount = max(1, min(Int((span / windowDuration).rounded(.down)), 100))
        let spacing = span / Double(windowCount)
        var observed: [RemoteUsageLimitPointDTO] = []
        var resets: [RemoteUsageLimitResetDTO] = []
        var previousPeak: (at: Double, fraction: Double)?
        for index in 0..<windowCount {
            let windowStart = start + Double(index) * spacing
            let isLast = index == windowCount - 1
            let peakAt = isLast ? now : min(windowStart + windowDuration * 0.8, now)
            let low = 0.02 + Double((index * 11) % 5) / 100
            let peak = isLast
                ? (summary.currentFraction ?? 0.5)
                : min(1, 0.18 + Double((index * 37) % 23) / 22 * 0.82)
            observed.append(.init(at: windowStart, fraction: low, segment: index))
            observed.append(.init(at: peakAt, fraction: peak, segment: index))
            if let previousPeak {
                resets.append(.init(
                    id: "demo-reset-\(index)",
                    detectedAt: windowStart,
                    previousObservedAt: previousPeak.at,
                    cause: .scheduled,
                    restoredFraction: previousPeak.fraction,
                    elapsedFraction: 1,
                    paceGainFraction: 0
                ))
            }
            previousPeak = (peakAt, peak)
        }
        return RemoteUsageLimitDTO(
            series: summary,
            days: days,
            start: start,
            end: now,
            observed: observed,
            resets: resets,
            recordedResetCount: resets.count,
            restoredPaceFraction: 0,
            projection: nil,
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
            windowDuration: 7 * 86_400,
            bankedResetCount: 2,
            nextBankedResetExpiresAt: now + 28 * 86_400,
            canRedeemBankedReset: true
        ),
        .init(
            id: "codex|work|weekly",
            runtimeName: "Codex",
            accountName: "Work",
            windowLabel: "Weekly",
            currentFraction: 0.28,
            resetsAt: now + 5 * 86_400,
            windowDuration: 7 * 86_400,
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
            windowDuration: 5 * 3_600,
            bankedResetCount: nil,
            nextBankedResetExpiresAt: nil
        ),
    ]
}
