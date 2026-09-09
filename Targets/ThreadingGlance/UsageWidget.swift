import AppIntents
import SwiftUI
import ThreadingGlanceKit
import ThreadingRemoteKit
import WidgetKit

struct UsageAccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static var defaultQuery: UsageAccountQuery { UsageAccountQuery() }
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct UsageAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [UsageAccountEntity] {
        let wanted = Set(identifiers.prefix(128))
        return try await suggestedEntities().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [UsageAccountEntity] {
        guard let snapshot = try await UsageGlanceStore.shared.read() else { return [] }
        return snapshot.capacity.accounts.map {
            UsageAccountEntity(id: snapshot.selectionID(for: $0),
                               title: "\($0.runtimeName) · \($0.accountName)")
        }
    }
}

struct UsageConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage"
    static let description = IntentDescription("Choose the account to keep in view.")
    @Parameter(title: "Account") var account: UsageAccountEntity?
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageGlanceSnapshot?
    let account: RemoteUsageCapacityAccountDTO?
    var storageFailed = false
    var route: URL? {
        snapshot.map { UsageGlanceRoute(pairingID: $0.pairingID, accountID: account?.id).url }
    }
}

struct UsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .preview }

    func snapshot(for configuration: UsageConfiguration, in context: Context) async -> UsageEntry {
        if context.isPreview { return .preview }
        return await entry(for: configuration)
    }

    func timeline(for configuration: UsageConfiguration, in context: Context) async -> Timeline<UsageEntry> {
        let current = await entry(for: configuration)
        let dates = UsageGlanceFreshness.transitions(account: current.account, now: current.date)
        return Timeline(entries: dates.map {
            UsageEntry(date: $0, snapshot: current.snapshot, account: current.account,
                       storageFailed: current.storageFailed)
        }, policy: .after(current.date.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: UsageConfiguration) async -> UsageEntry {
        let snapshot: UsageGlanceSnapshot?
        do { snapshot = try await UsageGlanceStore.shared.read() }
        catch { return UsageEntry(date: Date(), snapshot: nil, account: nil, storageFailed: true) }
        let account: RemoteUsageCapacityAccountDTO?
        if let selection = configuration.account, let snapshot {
            account = snapshot.capacity.accounts.first { snapshot.selectionID(for: $0) == selection.id }
        } else if configuration.account != nil {
            account = nil
        } else { account = snapshot?.account(id: nil) }
        return UsageEntry(date: Date(), snapshot: snapshot, account: account)
    }
}

/// System-owned widget containment. WidgetKit owns background removal, tinted rendering,
/// Lock Screen ink and margins. The feature draws through GlanceDesign's semantic tokens.
struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            if let account = entry.account, let window = account.windows.first {
                switch family {
                case .accessoryCircular: circular(account, window)
                case .accessoryInline: inline(account, window)
                case .accessoryRectangular: rectangular(account, window)
                default: home(account)
                }
            } else {
                empty
            }
        }
        .widgetURL(entry.route)
        .containerBackground(GlanceDesign.background, for: .widget)
    }

    private func freshness(_ account: RemoteUsageCapacityAccountDTO,
                           _ window: RemoteAccountUsageWindowDTO) -> UsageGlanceFreshness {
        .resolve(account: account, window: window, now: entry.date)
    }

    private func remaining(_ window: RemoteAccountUsageWindowDTO) -> Double {
        1 - (window.fraction ?? 0)
    }

    @ViewBuilder
    private func circular(_ account: RemoteUsageCapacityAccountDTO,
                          _ window: RemoteAccountUsageWindowDTO) -> some View {
        if freshness(account, window).showsCapacity {
            Gauge(value: remaining(window)) {
                Image(systemName: "chart.pie")
            } currentValueLabel: {
                VStack(spacing: GlanceDesign.Spacing.tight) {
                    Text(remaining(window), format: .percent.precision(.fractionLength(0)))
                    if freshness(account, window) != .recent {
                        Image(systemName: "clock").font(GlanceDesign.caption)
                    }
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel(Text("\(account.runtimeName), \(window.name), remaining capacity"))
            .accessibilityValue(Text(remaining(window), format: .percent.precision(.fractionLength(0))))
            .accessibilityHint(freshness(account, window) == .recent
                ? Text("Recent reading")
                : Text("Cached \(Date(timeIntervalSince1970: account.observedAt ?? 0), style: .relative) ago"))
        } else {
            Image(systemName: "arrow.clockwise")
                .accessibilityLabel(Text("Update needed"))
        }
    }

    private func inline(_ account: RemoteUsageCapacityAccountDTO,
                        _ window: RemoteAccountUsageWindowDTO) -> some View {
        if freshness(account, window) == .recent {
            return Text("\(account.runtimeName): \(Int((remaining(window) * 100).rounded()))% left")
        }
        if freshness(account, window).showsCapacity {
            return Text("Cached · \(Int((remaining(window) * 100).rounded()))% left")
        }
        return Text("Threading · Update needed")
    }

    private func rectangular(_ account: RemoteUsageCapacityAccountDTO,
                             _ window: RemoteAccountUsageWindowDTO) -> some View {
        VStack(alignment: .leading, spacing: GlanceDesign.Spacing.tight) {
            Text(verbatim: "\(account.runtimeName) · \(account.accountName)")
                .font(GlanceDesign.heading).lineLimit(1)
            capacityLine(account, window)
            status(account, window).font(GlanceDesign.caption).lineLimit(1)
        }
    }

    private func home(_ account: RemoteUsageCapacityAccountDTO) -> some View {
        VStack(alignment: .leading, spacing: GlanceDesign.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: GlanceDesign.Spacing.tight) {
                    Text(verbatim: account.runtimeName).font(GlanceDesign.heading)
                    Text(verbatim: account.accountName).font(GlanceDesign.caption)
                        .foregroundStyle(GlanceDesign.secondary).lineLimit(1)
                }
                Spacer(minLength: GlanceDesign.Spacing.small)
                Image(systemName: "chart.pie").foregroundStyle(GlanceDesign.accent)
                    .widgetAccentable()
            }
            if family == .systemMedium {
                HStack(alignment: .top, spacing: GlanceDesign.Spacing.pane) {
                    ForEach(Array(account.windows.prefix(2))) { window in
                        windowReading(account, window, showsStatus: true)
                    }
                }
            } else {
                ForEach(Array(account.windows.prefix(2))) { window in
                    windowReading(account, window, showsStatus: window.id == account.windows.first?.id)
                }
            }
            Spacer(minLength: 0)
            Text(verbatim: entry.snapshot?.hostName ?? "Threading")
                .font(GlanceDesign.caption).foregroundStyle(GlanceDesign.secondary).lineLimit(1)
        }
    }

    private func windowReading(_ account: RemoteUsageCapacityAccountDTO,
                               _ window: RemoteAccountUsageWindowDTO, showsStatus: Bool) -> some View {
        VStack(alignment: .leading, spacing: GlanceDesign.Spacing.tight) {
            capacityLine(account, window)
            if freshness(account, window).showsCapacity {
                ProgressView(value: remaining(window)).tint(GlanceDesign.accent)
                    .widgetAccentable().accessibilityHidden(true)
            }
            if showsStatus {
                status(account, window).font(GlanceDesign.caption)
                    .foregroundStyle(GlanceDesign.secondary).lineLimit(1)
            }
        }
    }

    private func capacityLine(_ account: RemoteUsageCapacityAccountDTO,
                              _ window: RemoteAccountUsageWindowDTO) -> some View {
        HStack {
            Text(verbatim: window.name).lineLimit(1)
            Spacer(minLength: GlanceDesign.Spacing.small)
            if freshness(account, window).showsCapacity {
                Text("\(Int((remaining(window) * 100).rounded()))% left").monospacedDigit()
            } else { Text("—") }
        }.font(GlanceDesign.reading)
    }

    @ViewBuilder
    private func status(_ account: RemoteUsageCapacityAccountDTO,
                        _ window: RemoteAccountUsageWindowDTO) -> some View {
        switch freshness(account, window) {
        case .recent:
            if let reset = window.resetsAt {
                Text("Resets \(Date(timeIntervalSince1970: reset), style: .relative)")
            } else { Text("Recent reading") }
        case .dated, .cached:
            if let observed = account.observedAt {
                Text("Cached \(Date(timeIntervalSince1970: observed), style: .relative) ago")
            }
        case .expired, .unavailable: Text("Open Threading to update")
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: GlanceDesign.Spacing.small) {
            Image(systemName: "chart.pie")
            if entry.storageFailed || entry.account != nil {
                Text("Open Threading to update").font(GlanceDesign.heading)
            } else if entry.snapshot == nil {
                Text("Set up widgets in Threading").font(GlanceDesign.heading)
            } else {
                Text("Choose an available account").font(GlanceDesign.heading)
            }
        }
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: UsageGlanceStore.widgetKind, intent: UsageConfiguration.self,
                               provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("Remaining capacity and reset times for your agent account.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular,
                            .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ThreadingGlanceBundle: WidgetBundle {
    var body: some Widget { UsageWidget() }
}

extension UsageEntry {
    static var preview: Self {
        let now = Date()
        let account = RemoteUsageCapacityAccountDTO(runtimeID: "codex", runtimeName: "Codex",
            accountID: "personal", accountName: "Personal", observedAt: now.timeIntervalSince1970,
            state: .current, windows: [
                .init(id: "session", name: "Session", fraction: 0.28,
                      resetsAt: now.addingTimeInterval(7200).timeIntervalSince1970),
                .init(id: "weekly", name: "Week", fraction: 0.61,
                      resetsAt: now.addingTimeInterval(172800).timeIntervalSince1970)
            ])
        return Self(date: now, snapshot: nil, account: account)
    }
}
