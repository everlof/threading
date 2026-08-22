import SwiftUI

struct AdvancedConnectionSettingsView: View {
    @Environment(\.remoteTheme) private var theme
    @ObservedObject private var pool: MobileSessionConnectionPool
    @State private var confirmsReset = false

    @MainActor
    init(pool: MobileSessionConnectionPool = .shared) {
        self.pool = pool
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                settingsSection(
                    "Connection reuse",
                    footer: MobileL10n.string(
                        "Threading keeps only the authenticated connection warm. Parked chats "
                            + "receive no terminal output, hold no viewport, and do not appear "
                            + "as viewers on the Mac. Set the pool size to zero to turn reuse off."
                    )
                ) {
                    PoolStepperRow(
                        title: "Hold connections",
                        value: retentionBinding,
                        range: MobileSessionConnectionPool.minimumRetentionSeconds...MobileSessionConnectionPool.maximumRetentionSeconds,
                        step: 5,
                        detail: MobileL10n.string("%d seconds", pool.retentionSeconds)
                    )
                    ThemedRowDivider()
                    PoolStepperRow(
                        title: "Pool size",
                        value: capacityBinding,
                        range: 0...MobileSessionConnectionPool.maximumCapacity,
                        step: 1,
                        detail: pool.capacity == 0
                            ? MobileL10n.string("Off")
                            : MobileL10n.string("Up to %d connections", pool.capacity)
                    )
                }

                settingsSection("Live now") {
                    MetricRow(
                        "Held connections",
                        value: MobileL10n.string("%d of %d", pool.occupancy, pool.capacity)
                    )
                    ThemedRowDivider()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        MetricRow(
                            "Oldest hold",
                            value: pool.oldestHeldDuration.map(formatDuration)
                                ?? MobileL10n.string("None")
                        )
                    }
                }

                settingsSection(
                    "Since metrics reset",
                    footer: MobileL10n.string(
                        "Stored only on this iPhone. Metrics contain counts and timings, never "
                            + "Mac names, chat names, prompts, or a connection history."
                    )
                ) {
                    MetricRow("Reuse hit rate", value: formatPercent(pool.metrics.hitRate))
                    ThemedRowDivider()
                    MetricRow("Reused", value: formatCount(pool.metrics.reused))
                    ThemedRowDivider()
                    MetricRow("Pool misses", value: formatCount(pool.metrics.misses))
                    ThemedRowDivider()
                    MetricRow("Connections parked", value: formatCount(pool.metrics.parked))
                    ThemedRowDivider()
                    MetricRow(
                        "Held without reuse",
                        value: formatCount(pool.metrics.heldWithoutReuse)
                    )
                    ThemedRowDivider()
                    MetricRow("Peak pool size", value: formatCount(pool.metrics.peakOccupancy))
                }

                settingsSection("Hold timing") {
                    MetricRow(
                        "Average before reuse",
                        value: formatDuration(pool.metrics.averageReusedHold)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "Average without reuse",
                        value: formatDuration(pool.metrics.averageUnusedHold)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "Longest hold",
                        value: formatDuration(
                            Double(pool.metrics.longestHoldMilliseconds) / 1_000
                        )
                    )
                }

                settingsSection(
                    "Pool outcomes",
                    footer: MobileL10n.string(
                        "Unsupported is the number of opens against older Macs that cannot park a "
                            + "session transport safely. They always disconnect normally."
                    )
                ) {
                    MetricRow(
                        "Expired",
                        value: formatCount(pool.metrics.expiredWithoutReuse)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "Pool was full",
                        value: formatCount(pool.metrics.capacityEvictions)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "Settings changed",
                        value: formatCount(pool.metrics.configurationEvictions)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "App backgrounded",
                        value: formatCount(pool.metrics.backgroundEvictions)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "Memory pressure",
                        value: formatCount(pool.metrics.memoryPressureEvictions)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "Switched Macs",
                        value: formatCount(pool.metrics.hostChangeEvictions)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "Connection lost while held",
                        value: formatCount(pool.metrics.invalidatedWhileHeld)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "Could not enter pool",
                        value: formatCount(pool.metrics.failedToPark)
                    )
                    ThemedRowDivider()
                    MetricRow(
                        "Mac does not support reuse",
                        value: formatCount(pool.metrics.unsupported)
                    )
                }

                settingsSection(
                    "Reuse by hold time",
                    footer: MobileL10n.string(
                        "Each row is reused / not reused. These fixed buckets show whether a "
                            + "shorter or longer hold would change the result without keeping a log."
                    )
                ) {
                    ageRow("Under 5 seconds", reused: \.under5Seconds)
                    ThemedRowDivider()
                    ageRow("5–15 seconds", reused: \.under15Seconds)
                    ThemedRowDivider()
                    ageRow("15–30 seconds", reused: \.under30Seconds)
                    ThemedRowDivider()
                    ageRow("30–60 seconds", reused: \.under60Seconds)
                    ThemedRowDivider()
                    ageRow("1–2 minutes", reused: \.under120Seconds)
                    ThemedRowDivider()
                    ageRow("2 minutes or more", reused: \.atLeast120Seconds)
                }

                Button {
                    confirmsReset = true
                } label: {
                    Text("Reset connection metrics")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, MobileDesign.Spacing.small)
                }
                .buttonStyle(.bordered)
                .tint(theme.accent)

                Text(
                    MobileL10n.string(
                        "Metrics reset %@",
                        pool.metrics.resetAt.formatted(date: .abbreviated, time: .shortened)
                    )
                )
                .font(.footnote)
                .foregroundStyle(theme.tertiaryLabel)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.top, MobileDesign.Spacing.medium)
            .padding(.bottom, MobileDesign.Spacing.pane)
        }
        .background(theme.ground)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .themedConfirmationDialog(
            "Reset connection metrics?",
            message: "Connection reuse settings stay unchanged.",
            isPresented: $confirmsReset,
            actions: [
                ThemedDialogAction("Reset Metrics", role: .destructive) {
                    pool.resetMetrics()
                },
                ThemedDialogAction("Cancel", role: .cancel),
            ]
        )
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { pool.retentionSeconds },
            set: { pool.setRetentionSeconds($0) }
        )
    }

    private var capacityBinding: Binding<Int> {
        Binding(
            get: { pool.capacity },
            set: { pool.setCapacity($0) }
        )
    }

    private func ageRow(
        _ title: LocalizedStringKey,
        reused keyPath: KeyPath<MobileConnectionPoolAgeBuckets, Int>
    ) -> some View {
        MetricRow(
            title,
            value: MobileL10n.string(
                "%d / %d",
                pool.metrics.reusedByAge[keyPath: keyPath],
                pool.metrics.unusedByAge[keyPath: keyPath]
            )
        )
    }

    private func settingsSection<Content: View>(
        _ title: LocalizedStringKey,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.label)
                .padding(.horizontal, MobileDesign.Spacing.inset)
            ThemedRowGroup(content: content)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .padding(.horizontal, MobileDesign.Spacing.inset)
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 { return MobileL10n.string("Less than 1 second") }
        if duration < 1.5 { return MobileL10n.string("1 second") }
        if duration < 60 { return MobileL10n.string("%d seconds", Int(duration.rounded())) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes == 1, seconds == 0 { return MobileL10n.string("1 minute") }
        return seconds == 0
            ? MobileL10n.string("%d minutes", minutes)
            : MobileL10n.string("%d min %d sec", minutes, seconds)
    }

    private func formatPercent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func formatCount(_ value: Int) -> String {
        value.formatted()
    }
}

private struct PoolStepperRow: View {
    @Environment(\.remoteTheme) private var theme
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let detail: String

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                Text(title)
                    .foregroundStyle(theme.label)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryLabel)
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.vertical, MobileDesign.Spacing.small)
    }
}

private struct MetricRow: View {
    @Environment(\.remoteTheme) private var theme
    let title: LocalizedStringKey
    let value: String

    init(_ title: LocalizedStringKey, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.medium) {
            Text(title)
                .foregroundStyle(theme.label)
            Spacer(minLength: MobileDesign.Spacing.small)
            Text(value)
                .foregroundStyle(theme.secondaryLabel)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.vertical, MobileDesign.Spacing.small)
    }
}
