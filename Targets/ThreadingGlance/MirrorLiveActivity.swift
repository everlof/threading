import ActivityKit
import AppIntents
import SwiftUI
import ThreadingGlanceKit
import WidgetKit

/// **End** in the Mirror Live Activity. It runs in the app's process — this declaration exists so
/// the button can name it. Keep its name and parameters identical to
/// `Sources/ThreadingMobile/MobileMirrorEndIntent.swift`.
struct MirrorEndIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Mirror"
    static let isDiscoverable = false

    @Parameter(title: "Mirror")
    var mirrorID: String

    @Parameter(title: "Mac")
    var hostID: String

    init() {}

    init(mirrorID: String, hostID: String) {
        self.mirrorID = mirrorID
        self.hostID = hostID
    }

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// A running Mirror, while Threading is not in front: the way back to the stage and the way out.
struct MirrorLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MirrorActivityAttributes.self) { context in
            MirrorActivityLockScreen(context: context)
                .activityBackgroundTint(nil)
                .widgetURL(context.attributes.returnURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .foregroundStyle(GlanceDesign.accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: GlanceDesign.Spacing.tight) {
                        Text(verbatim: context.state.sourceTitle)
                            .font(GlanceDesign.heading)
                            .lineLimit(1)
                        Text("Mirroring from \(context.attributes.macName)")
                            .font(GlanceDesign.caption)
                            .foregroundStyle(GlanceDesign.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MirrorActivityActions(attributes: context.attributes)
                }
            } compactLeading: {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(GlanceDesign.accent)
            } compactTrailing: {
                Text("Mirroring").font(GlanceDesign.caption)
            } minimal: {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(GlanceDesign.accent)
            }
            .widgetURL(context.attributes.returnURL)
        }
    }
}

private struct MirrorActivityLockScreen: View {
    let context: ActivityViewContext<MirrorActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: GlanceDesign.Spacing.medium) {
            HStack(spacing: GlanceDesign.Spacing.medium) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(GlanceDesign.accent)
                Text("Threading · Mirroring from \(context.attributes.macName)")
                    .font(GlanceDesign.caption)
                    .foregroundStyle(GlanceDesign.secondary)
                    .lineLimit(1)
            }
            Text(verbatim: context.state.sourceTitle)
                .font(GlanceDesign.heading)
                .lineLimit(1)
            Text("Updated \(context.state.updatedAt, style: .relative) ago")
                .font(GlanceDesign.caption)
                .foregroundStyle(GlanceDesign.secondary)
            MirrorActivityActions(attributes: context.attributes)
        }
        .padding(GlanceDesign.Spacing.pane)
    }
}

private struct MirrorActivityActions: View {
    let attributes: MirrorActivityAttributes

    var body: some View {
        HStack(spacing: GlanceDesign.Spacing.medium) {
            if let url = attributes.returnURL {
                Link(destination: url) {
                    Text("Return")
                        .font(GlanceDesign.reading)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(GlanceDesign.accent)
            }
            Button(intent: MirrorEndIntent(mirrorID: attributes.mirrorID, hostID: attributes.hostID)) {
                Text("End")
                    .font(GlanceDesign.reading)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}
