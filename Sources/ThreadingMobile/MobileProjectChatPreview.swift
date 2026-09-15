import SwiftUI
import ThreadingRemoteKit

/// A value projection; hidden chats never become collection rows or hosted views.
struct MobileProjectChatPreview {
    enum Stage: Int {
        case compact, firstBatch, secondBatch, all

        var limit: Int {
            switch self {
            case .compact: 3
            case .firstBatch: 8
            case .secondBatch: 13
            case .all: .max
            }
        }

        var next: Stage {
            switch self {
            case .compact: .firstBatch
            case .firstBatch: .secondBatch
            case .secondBatch, .all: .all
            }
        }
    }

    static let visibleLimit = 3
    let stage: Stage
    let nextStage: Stage
    let nextRevealCount: Int
    let sessions: ArraySlice<RemoteSessionSummaryDTO>
    let hiddenCount: Int
    let canExpand: Bool
    let isExpanded: Bool
    let attentionCount: Int
    let workingCount: Int

    init(sessions: [RemoteSessionSummaryDTO], isExpanded: Bool, isLive: Bool) {
        self.init(sessions: sessions, stage: isExpanded ? .all : .compact, isLive: isLive)
    }

    init(sessions: [RemoteSessionSummaryDTO], stage: Stage, isLive: Bool) {
        self.stage = stage
        canExpand = sessions.count > Self.visibleLimit
        self.sessions = sessions.prefix(stage.limit)
        hiddenCount = sessions.count - self.sessions.count
        isExpanded = hiddenCount == 0 && stage != .compact
        nextStage = isExpanded ? .compact : stage.next
        nextRevealCount = min(sessions.count, nextStage.limit) - self.sessions.count
        var attention = 0
        var working = 0
        if isLive {
            for session in sessions.dropFirst(self.sessions.count) where !session.isArchived {
                switch session.state {
                case .needsAttention, .awaitingUser, .limitReached: attention += 1
                case .working where session.isAvailable: working += 1
                default: break
                }
            }
        }
        attentionCount = attention
        workingCount = working
    }

    var title: String {
        if isExpanded { return MobileL10n.string("Show fewer") }
        if nextStage == .all {
            return MobileL10n.string("Show remaining (%lld)", Int64(hiddenCount))
        }
        return MobileL10n.string("Show %lld more", Int64(nextRevealCount))
    }

    var attentionDescription: String {
        guard attentionCount > 0 else { return "" }
        return attentionCount == 1 ? MobileL10n.string("1 needs attention")
            : MobileL10n.string("%lld need attention", Int64(attentionCount))
    }

    var workingDescription: String {
        workingCount > 0 ? MobileL10n.string("%lld working", Int64(workingCount)) : ""
    }

    var activityDescription: String {
        [attentionDescription, workingDescription].filter { !$0.isEmpty }.joined(separator: " · ")
    }

}

/// The collection's existing plate owns the ground and outline. This button only owns its
/// pressed wash and content, and occupies one ordinary reusable, Dynamic Type-sized row.
struct MobileProjectChatDisclosure: View {
    let preview: MobileProjectChatPreview
    let projectTitle: String
    let action: () -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Button {
            MobileButtonFeedback.shared.perform()
            action()
        } label: {
            HStack(spacing: MobileDesign.Spacing.medium) {
                Image(systemName: preview.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: MobileDesign.Size.rowMark)
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                    Text(preview.title)
                        .font(.subheadline.weight(.medium))
                    if !preview.activityDescription.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            (Text(preview.attentionDescription).foregroundColor(theme.warning)
                                + Text(verbatim: preview.attentionCount > 0 && preview.workingCount > 0
                                    ? " · " : "").foregroundColor(theme.secondaryLabel)
                                + Text(preview.workingDescription).foregroundColor(theme.secondaryLabel))
                                .fixedSize(horizontal: true, vertical: false)
                            // Keep both counts readable at accessibility sizes. The button's
                            // complete accessibility value still spells out their meaning.
                            HStack(spacing: MobileDesign.Spacing.medium) {
                                if preview.attentionCount > 0 {
                                    Label {
                                        Text(verbatim: String(preview.attentionCount))
                                    } icon: {
                                        Image(systemName: "exclamationmark.circle")
                                    }
                                    .foregroundStyle(theme.warning)
                                }
                                if preview.workingCount > 0 {
                                    Text(preview.workingDescription)
                                        .foregroundStyle(theme.secondaryLabel)
                                }
                            }
                        }
                        .font(.caption2)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, MobileDesign.Spacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: MobileDesign.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(MobileProjectDisclosureButtonStyle())
        .onAppear { MobileButtonFeedback.shared.prepare() }
        .accessibilityLabel(MobileL10n.string(
            preview.isExpanded ? "Show fewer chats in %@" : "Show more chats in %@",
            projectTitle
        ))
        .accessibilityValue([preview.title, preview.activityDescription]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("project-chat-disclosure.\(projectTitle)")
    }
}

struct MobileProjectDisclosureButtonStyle: ButtonStyle {
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? theme.controlResting : .clear)
            .animation(reduceMotion ? nil : .easeOut(duration: MobileDesign.Motion.controlResponse),
                       value: configuration.isPressed)
    }
}
