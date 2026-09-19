import ThreadingRemoteKit
import SwiftUI
import UIKit

/// The session-scoped surfaces that complement its primary conversation or terminal.
///
/// The list is deliberately semantic rather than a projection of the Mac's `PaneTab`: mobile
/// owns its navigation and presentation, while each destination keeps the remote authorization
/// and bounded-data rules it already had. Browser and Subagents can join this inventory without
/// adding another session-toolbar button.
private enum SessionWorkspaceItem: String, CaseIterable, Hashable, Identifiable {
    case browser
    case review
    case files
    case attachments

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .browser: return "globe"
        case .review: return "plus.forwardslash.minus"
        case .files: return "folder"
        case .attachments: return "paperclip"
        }
    }

    var route: SessionWorkspaceRoute {
        switch self {
        case .browser: return .browser(tabID: nil)
        case .review: return .review
        case .files: return .files
        case .attachments: return .attachments
        }
    }
}

enum SessionWorkspaceRoute: Hashable {
    case browser(tabID: String?)
    case review
    case files
    case attachments
    case attachment(id: String)
    case extensionPanel(extensionIdentifier: String, panelID: String)

    static func notificationDestination(
        _ destination: RemoteNotificationDestinationDTO?
    ) -> Self? {
        guard let destination, destination.isValid else { return nil }
        switch destination.kind {
        case .session:
            return nil
        case .attachment:
            return destination.attachmentID.map { .attachment(id: $0) }
        case .browserTab:
            return destination.browserTabID.map { .browser(tabID: $0) }
        case .extensionPanel:
            guard let extensionIdentifier = destination.extensionIdentifier,
                  let panelID = destination.extensionPanelID else { return nil }
            return .extensionPanel(
                extensionIdentifier: extensionIdentifier,
                panelID: panelID
            )
        }
    }
}

struct SessionWorkspaceView: View {
    let session: RemoteSessionSummaryDTO
    let client: RemoteClient
    @ObservedObject var activity: MobileWorkspaceActivity

    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme
    @State private var workspace: RemoteWorkspaceDTO?
    @State private var path: [SessionWorkspaceRoute]
    @State private var browserPresentation: BrowserPresentation?

    private struct BrowserPresentation: Identifiable {
        let tabID: String?
        var id: String { tabID ?? "active-browser" }
    }
    private let loadsRemotely: Bool
    private let initialBrowserPreview: UIImage?
    /// Whether the Mac advertised `RemoteRESTFeature.attachmentThumbnails`. Carried in rather
    /// than read from the model, because the drawer is hosted outside SwiftUI's environment.
    private let offersAttachmentThumbnails: Bool
    /// Whether the Mac can serve file-backed movies without a whole-file download.
    private let offersAttachmentVideoStreaming: Bool

    init(
        session: RemoteSessionSummaryDTO,
        client: RemoteClient,
        activity: MobileWorkspaceActivity,
        initialWorkspace: RemoteWorkspaceDTO? = nil,
        initialDestination: RemoteNotificationDestinationDTO? = nil,
        offersAttachmentThumbnails: Bool = false,
        offersAttachmentVideoStreaming: Bool = false,
        loadsRemotely: Bool = true,
        initialBrowserPreview: UIImage? = nil
    ) {
        self.loadsRemotely = loadsRemotely
        self.initialBrowserPreview = initialBrowserPreview
        self.session = session
        self.client = client
        self.offersAttachmentThumbnails = offersAttachmentThumbnails
        self.offersAttachmentVideoStreaming = offersAttachmentVideoStreaming
        _activity = ObservedObject(wrappedValue: activity)
        _workspace = State(initialValue: initialWorkspace)
        let destination = SessionWorkspaceRoute.notificationDestination(initialDestination)
        if case .browser(let tabID) = destination {
            _path = State(initialValue: [])
            _browserPresentation = State(initialValue: BrowserPresentation(tabID: tabID))
        } else {
            _path = State(initialValue: destination.map { [$0] } ?? [])
            _browserPresentation = State(initialValue: nil)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(SessionWorkspaceItem.allCases) { item in
                Group {
                    if item == .browser {
                        Button {
                            browserPresentation = BrowserPresentation(tabID: nil)
                        } label: {
                            workspaceRow(item)
                        }
                    } else {
                        NavigationLink(value: item.route) {
                            workspaceRow(item)
                        }
                    }
                }
                .themedSettingsRow(theme)
            }
            .listStyle(.plain)
            .themedSettingsPage(theme)
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SessionWorkspaceRoute.self) { route in
                destination(for: route)
            }
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(MobileL10n.string("Close workspace"))
                }
            }
        }
        .background(theme.ground)
        .fullScreenCover(item: $browserPresentation) { presentation in
            NavigationStack {
                RemoteBrowserFollowView(
                    session: session,
                    client: client,
                    activity: activity,
                    initialTabID: presentation.tabID,
                    initialWorkspace: workspace ?? RemoteWorkspaceDTO(browserTabs: []),
                    initialPreview: initialBrowserPreview,
                    loadsRemotely: loadsRemotely,
                    showsCloseButton: true
                )
            }
            .mobileTheme(theme)
        }
        .task(id: activity.changeSequence) {
            guard loadsRemotely else { return }
            await refreshWorkspace()
        }
    }

    private func workspaceRow(_ item: SessionWorkspaceItem) -> some View {
        SessionWorkspaceItemRow(
            item: item,
            workspace: workspace,
            hasUnseenActivity: item == .browser && activity.hasUnseenBrowser
        )
    }

    @ViewBuilder
    private func destination(for route: SessionWorkspaceRoute) -> some View {
        switch route {
        case .browser(let tabID):
            RemoteBrowserFollowView(
                session: session,
                client: client,
                activity: activity,
                initialTabID: tabID
            )
        case .review:
            RemoteGitReviewView(
                session: session,
                client: client,
                initialSection: .changed,
                showsCloseButton: false
            )
        case .files:
            RemoteGitReviewView(
                session: session,
                client: client,
                initialSection: .allFiles,
                showsCloseButton: false
            )
        case .attachments:
            RemoteAttachmentsView(
                session: session,
                client: client,
                showsCloseButton: false,
                offersThumbnails: offersAttachmentThumbnails,
                offersVideoStreaming: offersAttachmentVideoStreaming
            )
        case .attachment(let id):
            RemoteAttachmentTargetView(
                session: session,
                attachmentID: id,
                client: client,
                offersThumbnails: offersAttachmentThumbnails,
                offersVideoStreaming: offersAttachmentVideoStreaming
            )
        case .extensionPanel(let extensionIdentifier, let panelID):
            RemoteExtensionPanelView(
                session: session,
                extensionIdentifier: extensionIdentifier,
                panelID: panelID,
                client: client
            )
        }
    }

    private func refreshWorkspace() async {
        guard let fetched = try? await client.workspace(sessionID: session.id) else { return }
        workspace = fetched
        activity.reconcile(fetched)
    }
}

private struct SessionWorkspaceItemRow: View {
    let item: SessionWorkspaceItem
    let workspace: RemoteWorkspaceDTO?
    let hasUnseenActivity: Bool

    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            Image(systemName: item.symbolName)
                .font(.title3)
                .foregroundStyle(theme.accent)
                .frame(
                    width: MobileDesign.Size.minimumTapTarget,
                    height: MobileDesign.Size.minimumTapTarget
                )
                .background(theme.controlResting, in: RoundedRectangle(
                    cornerRadius: theme.controlRadius
                ))

            copy
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasUnseenActivity {
                Circle()
                    .fill(theme.accent)
                    .frame(
                        width: MobileDesign.Size.workspaceActivityDot,
                        height: MobileDesign.Size.workspaceActivityDot
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, MobileDesign.Spacing.small)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var copy: some View {
        switch item {
        case .browser:
            itemCopy(
                title: Text("Browser"),
                description: Text(browserDescription)
            )
        case .review:
            itemCopy(
                title: Text("Review"),
                description: Text("Inspect changed files and compare working-tree states.")
            )
        case .files:
            itemCopy(
                title: Text("Files"),
                description: Text("Browse text files in this session’s repository.")
            )
        case .attachments:
            itemCopy(
                title: Text("Attachments"),
                description: Text("Open images and PDFs mentioned by the agent.")
            )
        }
    }

    private var browserDescription: String {
        guard let workspace else {
            return MobileL10n.string("Follow browser tabs opened on your Mac.")
        }
        guard !workspace.browserTabs.isEmpty else {
            return MobileL10n.string("No browser tabs are open on your Mac.")
        }

        guard let active = workspace.browserTabs.first(where: { $0.isActive })
            ?? workspace.browserTabs.first else {
            return MobileL10n.string("No browser tabs are open on your Mac.")
        }
        let detail: String
        if active.isPrivate {
            detail = MobileL10n.string("Private Browser")
        } else if !active.title.isEmpty {
            detail = active.title
        } else if let displayURL = active.displayURL, !displayURL.isEmpty {
            detail = displayURL
        } else {
            detail = MobileL10n.string("Browser ready on your Mac")
        }

        if workspace.browserTabs.count == 1 {
            return detail
        }
        return MobileL10n.string(
            "%lld browser tabs · %@",
            Int64(workspace.browserTabs.count),
            detail
        )
    }

    private func itemCopy(title: Text, description: Text) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
            title
                .font(.body.weight(.medium))
                .foregroundStyle(theme.label)
            description
                .font(.caption)
                .foregroundStyle(theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
