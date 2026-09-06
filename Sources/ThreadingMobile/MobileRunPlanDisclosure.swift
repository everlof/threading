import SwiftUI
import ThreadingRemoteKit

#if os(iOS)
/// The small provider-plan receipt immediately below a session's navigation bar.
struct MobileRunPlanDisclosure: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var theme
    @State private var isExpanded = false
    @State private var buttonFeedback = MobileButtonFeedback.shared

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
                buttonFeedback.perform()
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
            .onAppear { buttonFeedback.prepare() }
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

private enum RunPlanMetrics {
    static let popoverWidth: CGFloat = 360
    static let scrollMaxHeight: CGFloat = 360
    /// The leading rail: a status dot with the connectors that make the steps read as a
    /// sequence rather than a flat list.
    static let railColumn: CGFloat = 28
    static let glyph: CGFloat = 18
    static let connector: CGFloat = 1.5
    static let progressBar: CGFloat = 3
    /// The dot sits on the title's first line, `rowTop` down from the row's top edge; the
    /// connectors meet its top and bottom edges, so this is where they stop and start.
    static let rowTop = MobileDesign.Spacing.small
    static let activeCorner: CGFloat = 10
}

private struct MobileRunPlanDetail: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(connection.runPlanSteps.enumerated()), id: \.element.id) { index, step in
                        MobileRunPlanStepRow(
                            step: step,
                            isFirst: index == 0,
                            isLast: isLastRow(index)
                        )
                    }
                    if let plan = connection.runPlan,
                       connection.runPlanSteps.count < plan.total {
                        ProgressView()
                            .tint(theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(MobileDesign.Spacing.inset)
                            .onAppear { connection.requestNextRunPlanPage() }
                    }
                }
                .padding(.vertical, MobileDesign.Spacing.small)
            }
            .frame(maxHeight: RunPlanMetrics.scrollMaxHeight)
        }
        .frame(width: RunPlanMetrics.popoverWidth)
        .background(theme.floatingSurface)
    }

    /// The last *loaded* step is the plan's last only once the whole plan is loaded; while more
    /// pages are pending, its connector must still reach down toward them.
    private func isLastRow(_ index: Int) -> Bool {
        guard index == connection.runPlanSteps.count - 1 else { return false }
        guard let total = connection.runPlan?.total else { return true }
        return connection.runPlanSteps.count >= total
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text(MobileL10n.string("Plan"))
                    .font(.headline)
                    .foregroundStyle(theme.label)
                Spacer()
                if let plan = connection.runPlan {
                    Text(verbatim: "\(plan.completed)/\(plan.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryLabel)
                        .accessibilityLabel(MobileL10n.string(
                            "%lld of %lld complete",
                            Int64(plan.completed),
                            Int64(plan.total)
                        ))
                }
            }
            if let plan = connection.runPlan, plan.total > 0 {
                RunPlanProgressBar(fraction: Double(plan.completed) / Double(plan.total))
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.top, MobileDesign.Spacing.medium)
        .padding(.bottom, MobileDesign.Spacing.small)
    }
}

/// A quiet completion track under the header: how much of the plan is done, at a glance.
private struct RunPlanProgressBar: View {
    let fraction: Double
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(theme.divider)
                Capsule(style: .continuous)
                    .fill(theme.positive)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: RunPlanMetrics.progressBar)
        .accessibilityHidden(true)
    }
}

private struct MobileRunPlanStepRow: View {
    let step: RemoteRunPlanStepDTO
    let isFirst: Bool
    let isLast: Bool
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rail
            Text(step.title)
                .font(step.status == .inProgress
                    ? .subheadline.weight(.semibold)
                    : .subheadline)
                .foregroundStyle(titleColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, MobileDesign.Spacing.small)
                .padding(.trailing, MobileDesign.Spacing.inset)
        }
        .padding(.leading, MobileDesign.Spacing.small)
        .background {
            if step.status == .inProgress {
                RoundedRectangle(cornerRadius: RunPlanMetrics.activeCorner, style: .continuous)
                    .fill(theme.controlResting)
                    .padding(.horizontal, MobileDesign.Spacing.small)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.title)
        .accessibilityValue(statusLabel)
    }

    /// The status dot with the two connectors that reach the steps above and below it. Drawn per
    /// row — not as one full-height overlay — so a long plan stays virtualized: each row pays for
    /// its own dot and nothing more.
    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : reachedColor)
                .frame(width: RunPlanMetrics.connector, height: RunPlanMetrics.rowTop)
            Color.clear.frame(width: RunPlanMetrics.connector, height: RunPlanMetrics.glyph)
            Rectangle()
                .fill(isLast ? Color.clear : passedColor)
                .frame(width: RunPlanMetrics.connector)
                .frame(maxHeight: .infinity)
        }
        .frame(width: RunPlanMetrics.railColumn)
        .overlay(alignment: .top) {
            Image(systemName: symbol)
                .font(.system(size: RunPlanMetrics.glyph - 4, weight: .medium))
                .foregroundStyle(glyphColor)
                .frame(width: RunPlanMetrics.glyph, height: RunPlanMetrics.glyph)
                .background(Circle().fill(theme.floatingSurface))
                .symbolEffect(.pulse, options: .repeating, isActive: pulses)
                .offset(y: RunPlanMetrics.rowTop)
        }
    }

    /// The connector above a step is "reached" once the step is no longer pending; the one below
    /// is "passed" once it is complete. So the rail runs in `positive` down to and through the
    /// active dot, then fades to `divider` for the work still ahead.
    private var reachedColor: Color { step.status == .pending ? theme.divider : theme.positive }
    private var passedColor: Color { step.status == .completed ? theme.positive : theme.divider }

    private var pulses: Bool {
#if DEBUG
        guard ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"] == nil else {
            return false
        }
#endif
        return step.status == .inProgress && !reduceMotion
    }

    private var titleColor: Color {
        step.status == .inProgress ? theme.label : theme.secondaryLabel
    }

    private var symbol: String {
        switch step.status {
        case .pending: return "circle"
        case .inProgress: return "circle.inset.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var glyphColor: Color {
        switch step.status {
        case .pending: return theme.tertiaryLabel
        case .inProgress: return theme.warning
        case .completed: return theme.positive
        }
    }

    private var statusLabel: String {
        switch step.status {
        case .pending: return MobileL10n.string("Pending")
        case .inProgress: return MobileL10n.string("Active")
        case .completed: return MobileL10n.string("Complete")
        }
    }
}
#endif
