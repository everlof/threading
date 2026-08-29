import SwiftUI
import ThreadingRemoteKit

#if os(iOS)
/// The small provider-plan receipt immediately below a session's navigation bar.
struct MobileRunPlanDisclosure: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var theme
    @State private var isExpanded = false

    init(connection: RemoteSessionConnection) {
        self.connection = connection
#if DEBUG
        _isExpanded = State(initialValue:
            ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "conversation-run-plan-expanded"
        )
#endif
    }

    var body: some View {
        if let plan = connection.runPlan {
            Button {
                isExpanded.toggle()
                if isExpanded { connection.requestNextRunPlanPage() }
            } label: {
                HStack(spacing: MobileDesign.Spacing.small) {
                    Image(systemName: "checklist")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                    Text(plan.activeTitle ?? MobileL10n.string("Plan"))
                        .font(.caption)
                        .foregroundStyle(theme.label)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(MobileL10n.string("%lld of %lld", Int64(plan.current), Int64(plan.total)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.secondaryLabel)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.tertiaryLabel)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, MobileDesign.Spacing.inset)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(theme.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
            }
            .accessibilityLabel(MobileL10n.string("Show plan"))
            .accessibilityValue(
                MobileL10n.string(
                    "%@, step %lld of %lld",
                    plan.activeTitle ?? MobileL10n.string("Plan"),
                    Int64(plan.current),
                    Int64(plan.total)
                )
            )
            .popover(isPresented: $isExpanded, arrowEdge: .top) {
                MobileRunPlanDetail(connection: connection)
                    .mobileTheme(theme)
                    .presentationCompactAdaptation(.popover)
            }
            .onChange(of: connection.runPlan == nil) { _, isCleared in
                if isCleared { isExpanded = false }
            }
        }
    }
}

private struct MobileRunPlanDetail: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(MobileL10n.string("Plan"))
                    .font(.headline)
                    .foregroundStyle(theme.label)
                Spacer()
                if let plan = connection.runPlan {
                    Text(MobileL10n.string(
                        "%lld of %lld complete",
                        Int64(plan.completed),
                        Int64(plan.total)
                    ))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryLabel)
                }
            }
            .padding(MobileDesign.Spacing.inset)

            Rectangle().fill(theme.divider).frame(height: theme.borderWidth)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(connection.runPlanSteps) { step in
                        MobileRunPlanStepRow(step: step)
                        if step.id != connection.runPlanSteps.last?.id {
                            Rectangle()
                                .fill(theme.divider)
                                .frame(height: theme.borderWidth)
                                .padding(.leading, MobileDesign.Spacing.inset + 24)
                        }
                    }
                    if let plan = connection.runPlan,
                       connection.runPlanSteps.count < plan.total {
                        ProgressView()
                            .tint(theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(MobileDesign.Spacing.inset)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 360)
        .background(theme.floatingSurface)
        .task { connection.requestNextRunPlanPage() }
        .onChange(of: connection.runPlanSteps.count) { _, _ in
            connection.requestNextRunPlanPage()
        }
    }
}

private struct MobileRunPlanStepRow: View {
    let step: RemoteRunPlanStepDTO
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: presentation.symbol)
                .font(.caption)
                .foregroundStyle(presentation.color(theme))
                .frame(width: 20)
            Text(step.title)
                .font(.subheadline)
                .foregroundStyle(step.status == .pending ? theme.secondaryLabel : theme.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(presentation.label)
                .font(.caption2)
                .foregroundStyle(theme.tertiaryLabel)
        }
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.vertical, MobileDesign.Spacing.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.title)
        .accessibilityValue(presentation.label)
    }

    private var presentation: (
        symbol: String,
        label: String,
        color: (RemoteThemePalette) -> Color
    ) {
        switch step.status {
        case .pending:
            return ("circle", MobileL10n.string("Pending"), { $0.tertiaryLabel })
        case .inProgress:
            return ("circle.inset.filled", MobileL10n.string("Active"), { $0.warning })
        case .completed:
            return ("checkmark.circle.fill", MobileL10n.string("Complete"), { $0.positive })
        }
    }
}
#endif
