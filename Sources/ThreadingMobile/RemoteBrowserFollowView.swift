import ThreadingRemoteKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A read-only view of the browser the agent is driving on the Mac.
///
/// This intentionally renders a bounded Mac snapshot rather than loading the URL in an iPhone
/// `WKWebView`: the latter would have different cookies, permissions, history, and page state.
struct RemoteBrowserFollowView: View {
    let session: RemoteSessionSummaryDTO
    let client: RemoteClient
    @ObservedObject var activity: MobileWorkspaceActivity

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.remoteTheme) private var theme
    @State private var workspace = RemoteWorkspaceDTO(browserTabs: [])
    @State private var selectedTabID: String?
    @State private var preview: UIImage?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var isDeciding = false
    @State private var permissionError: String?
    @State private var isLoadingLink = false
    @State private var linkError: String?
    @State private var sharePayload: MobileSharePayload?
    private let loadsRemotely: Bool
    private let showsCloseButton: Bool

    init(
        session: RemoteSessionSummaryDTO,
        client: RemoteClient,
        activity: MobileWorkspaceActivity,
        initialTabID: String? = nil,
        initialWorkspace: RemoteWorkspaceDTO = RemoteWorkspaceDTO(browserTabs: []),
        initialPreview: UIImage? = nil,
        loadsRemotely: Bool = true,
        showsCloseButton: Bool = false
    ) {
        self.session = session
        self.client = client
        self.loadsRemotely = loadsRemotely
        self.showsCloseButton = showsCloseButton
        _activity = ObservedObject(wrappedValue: activity)
        _workspace = State(initialValue: initialWorkspace)
        _selectedTabID = State(initialValue: initialTabID)
        _preview = State(initialValue: initialPreview)
    }

    private var selectedTab: RemoteBrowserTabDTO? {
        Self.resolveTab(in: workspace, preferredID: selectedTabID)
    }

    /// A nil preference follows the Mac; only an explicit choice pins a tab.
    static func resolveTab(
        in workspace: RemoteWorkspaceDTO,
        preferredID: String?
    ) -> RemoteBrowserTabDTO? {
        if let preferredID,
           let selected = workspace.browserTabs.first(where: { $0.id == preferredID }) {
            return selected
        }
        return workspace.browserTabs.first(where: { $0.isActive })
            ?? workspace.browserTabs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.browserTabs.isEmpty && workspace.browserPermission == nil {
                browserHeader
                Divider()
                    .overlay(theme.divider)
            }
            browserContent
        }
        .background(theme.ground)
        .navigationTitle("Browser")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(MobileL10n.string("Close browser"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    if isLoading || isDeciding {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading || isDeciding)
                .accessibilityLabel(MobileL10n.string("Refresh browser preview"))
            }
        }
        .task(id: activity.changeSequence) {
            activity.markBrowserSeen()
            guard loadsRemotely else { return }
            await refresh()
        }
        .sheet(item: $sharePayload) { payload in
            MobileSystemShareSheet(items: payload.items)
        }
        .themedAlert(
            "Couldn’t use browser link",
            message: linkError ?? "",
            isPresented: Binding(
                get: { linkError != nil },
                set: { if !$0 { linkError = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
    }

    private var browserHeader: some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                Text(selectedTitle)
                    .font(.headline)
                    .foregroundStyle(theme.label)
                    .lineLimit(1)

                if let tab = selectedTab, let displayURL = tab.displayURL {
                    HStack(spacing: MobileDesign.Spacing.tight) {
                        Text(displayURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.secondaryLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if tab.canPreview && !tab.isPrivate &&
                            (displayURL.hasPrefix("http://") || displayURL.hasPrefix("https://")) {
                            Menu {
                                Button("Open in Browser", systemImage: "safari") {
                                    useLink(.open, from: tab)
                                }
                                Button("Share Link", systemImage: "square.and.arrow.up") {
                                    useLink(.share, from: tab)
                                }
                                Button("Copy Link", systemImage: "link") {
                                    useLink(.copy, from: tab)
                                }
                            } label: {
                                Image(systemName: isLoadingLink ? "hourglass" : "ellipsis.circle")
                                    .font(.title3)
                                    .frame(
                                        width: MobileDesign.Size.minimumTapTarget,
                                        height: MobileDesign.Size.minimumTapTarget
                                    )
                                    .contentShape(Rectangle())
                            }
                            .foregroundStyle(theme.secondaryLabel)
                            .disabled(isLoadingLink)
                            .accessibilityLabel(MobileL10n.string("Link actions"))
                        }
                    }
                }

                Label("Following your Mac · Read only", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(theme.tertiaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if workspace.browserTabs.count > 1 {
                Menu {
                    ForEach(workspace.browserTabs) { tab in
                        Button {
                            select(tab)
                        } label: {
                            if tab.id == selectedTab?.id {
                                Label(tabTitle(tab), systemImage: "checkmark")
                            } else {
                                Text(tabTitle(tab))
                            }
                        }
                    }
                } label: {
                    Label(
                        MobileL10n.string(
                            "%lld Tabs",
                            Int64(workspace.browserTabs.count)
                        ),
                        systemImage: "rectangle.stack"
                    )
                }
            }
        }
        .padding(MobileDesign.Spacing.inset)
        .background(theme.surface)
    }

    @ViewBuilder
    private var browserContent: some View {
        if let permission = workspace.browserPermission {
            permissionContent(permission)
        } else if workspace.browserTabs.isEmpty {
            ContentUnavailableView {
                Label("No Browser Tabs", systemImage: "globe")
            } description: {
                Text("A browser opened by the agent will appear here.")
            }
            .foregroundStyle(theme.secondaryLabel)
        } else if selectedTab?.isPrivate == true {
            ContentUnavailableView {
                Label("Private Browser", systemImage: "hand.raised.fill")
            } description: {
                Text("Private browser pixels stay on your Mac.")
            }
            .foregroundStyle(theme.secondaryLabel)
        } else if let preview {
            ScrollView {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .background(theme.surface)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(selectedTitle)
            }
            .scrollIndicators(.hidden)
        } else if isLoading {
            MobileLoadingPlaceholder(MobileL10n.string("Updating browser preview…"))
        } else if let loadError {
            ContentUnavailableView {
                Label("Preview Unavailable", systemImage: "rectangle.slash")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") {
                    Task { await refresh() }
                }
            }
            .foregroundStyle(theme.secondaryLabel)
        } else {
            ContentUnavailableView {
                Label("Browser Ready", systemImage: "globe")
            } description: {
                Text("This tab has not loaded a previewable page yet.")
            }
            .foregroundStyle(theme.secondaryLabel)
        }
    }

    private func permissionContent(_ permission: RemoteBrowserPermissionDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.inset) {
                Label("Browser permission needed", systemImage: "hand.raised")
                    .font(.headline)
                    .foregroundStyle(theme.label)
                Text(permission.title)
                    .font(.title2.bold())
                    .foregroundStyle(theme.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(permission.message)
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let permissionError {
                    Text(permissionError)
                        .foregroundStyle(theme.secondaryLabel)
                }
                permissionButton(permission.allowTitle, decision: .allowOnce, request: permission)
                if let rememberTitle = permission.rememberTitle {
                    permissionButton(rememberTitle, decision: .allowRemembered, request: permission)
                }
                if let allSitesTitle = permission.allSitesTitle {
                    permissionButton(allSitesTitle, decision: .allowAllSites, request: permission)
                }
                permissionButton(permission.denyTitle, decision: .deny, request: permission)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MobileDesign.Spacing.inset)
        }
    }

    private func permissionButton(
        _ title: String,
        decision: RemoteBrowserPermissionDecision,
        request: RemoteBrowserPermissionDTO
    ) -> some View {
        Button(title) {
            Task { await decide(request, decision: decision) }
        }
        .buttonStyle(MobileThemedActionButtonStyle(kind: .secondary, theme: theme))
        .disabled(isDeciding)
    }

    private func decide(
        _ permission: RemoteBrowserPermissionDTO,
        decision: RemoteBrowserPermissionDecision
    ) async {
        guard loadsRemotely, !isDeciding else { return }
        isDeciding = true
        permissionError = nil
        defer { isDeciding = false }
        do {
            workspace = try await client.decideBrowserPermission(
                sessionID: session.id, id: permission.id, decision: decision
            )
            activity.reconcile(workspace)
            await refresh()
        } catch {
            // Another device may have answered, or the turn may have ended. Read the current
            // request before offering another action; never retarget this answer to its successor.
            await refresh()
            permissionError = error.localizedDescription
        }
    }

    private var selectedTitle: String {
        selectedTab.map(tabTitle) ?? MobileL10n.string("Browser")
    }

    private func tabTitle(_ tab: RemoteBrowserTabDTO) -> String {
        if tab.isPrivate {
            return MobileL10n.string("Private Browser")
        }
        if !tab.title.isEmpty {
            return tab.title
        }
        return tab.displayURL ?? MobileL10n.string("Browser")
    }

    private func select(_ tab: RemoteBrowserTabDTO) {
        selectedTabID = tab.id
        preview = nil
        loadError = nil
        activity.markBrowserSeen()
        Task { await refreshPreview(for: tab) }
    }

    private enum LinkAction {
        case open
        case share
        case copy
    }

    private func useLink(_ action: LinkAction, from tab: RemoteBrowserTabDTO) {
        guard !isLoadingLink else { return }
        isLoadingLink = true
        Task {
            defer { isLoadingLink = false }
            do {
                let url = try await client.browserLink(sessionID: session.id, tabID: tab.id)
                guard selectedTab?.id == tab.id else { return }
                switch action {
                case .open:
                    openURL(url)
                case .share:
                    sharePayload = MobileSharePayload(items: [url])
                case .copy:
                    UIPasteboard.general.setItems(
                        [[UTType.utf8PlainText.identifier: url.absoluteString]],
                        options: [.localOnly: true]
                    )
                }
            } catch {
                guard selectedTab?.id == tab.id else { return }
                linkError = error.localizedDescription
            }
        }
    }

    private func refresh() async {
        isLoading = true
        loadError = nil
        do {
            let fetched = try await client.workspace(sessionID: session.id)
            guard !Task.isCancelled else { return }
            let previousTabID = selectedTab?.id
            workspace = fetched
            activity.reconcile(fetched)

            let selected = selectedTab
            if selected?.id != previousTabID {
                preview = nil
            }
            if let selectedTabID,
               !fetched.browserTabs.contains(where: { $0.id == selectedTabID }) {
                self.selectedTabID = nil
            }

            if let selected {
                await refreshPreview(for: selected)
            } else {
                preview = nil
            }
        } catch is CancellationError {
            return
        } catch {
            MobileDiagnostics.logDegraded(.browserTabs, error: error)
            preview = nil
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func refreshPreview(for tab: RemoteBrowserTabDTO) async {
        guard !tab.isPrivate, tab.canPreview else {
            preview = nil
            isLoading = false
            return
        }

        isLoading = true
        loadError = nil
        do {
            let data = try await client.browserPreviewData(
                sessionID: session.id,
                tabID: tab.id
            )
            guard !Task.isCancelled, selectedTab?.id == tab.id,
                  let image = UIImage(data: data) else {
                if !Task.isCancelled, selectedTab?.id == tab.id {
                    loadError = MobileL10n.string("The Mac returned an unreadable preview.")
                }
                isLoading = false
                return
            }
            preview = image
        } catch is CancellationError {
            return
        } catch {
            MobileDiagnostics.logDegraded(.browserPreview, error: error)
            if selectedTab?.id == tab.id {
                preview = nil
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }
}
