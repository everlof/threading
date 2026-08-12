import ThreadingRemoteKit
import SwiftUI
import UIKit

/// A read-only view of the browser the agent is driving on the Mac.
///
/// This intentionally renders a bounded Mac snapshot rather than loading the URL in an iPhone
/// `WKWebView`: the latter would have different cookies, permissions, history, and page state.
struct RemoteBrowserFollowView: View {
    let session: RemoteSessionSummaryDTO
    let client: RemoteClient
    @ObservedObject var activity: MobileWorkspaceActivity

    @Environment(\.remoteTheme) private var theme
    @State private var workspace = RemoteWorkspaceDTO(browserTabs: [])
    @State private var selectedTabID: String?
    @State private var preview: UIImage?
    @State private var loadError: String?
    @State private var isLoading = false
    private let loadsRemotely: Bool

    init(
        session: RemoteSessionSummaryDTO,
        client: RemoteClient,
        activity: MobileWorkspaceActivity,
        initialTabID: String? = nil,
        initialWorkspace: RemoteWorkspaceDTO = RemoteWorkspaceDTO(browserTabs: []),
        initialPreview: UIImage? = nil,
        loadsRemotely: Bool = true
    ) {
        self.session = session
        self.client = client
        self.loadsRemotely = loadsRemotely
        _activity = ObservedObject(wrappedValue: activity)
        _workspace = State(initialValue: initialWorkspace)
        _selectedTabID = State(initialValue: initialTabID)
        _preview = State(initialValue: initialPreview)
    }

    private var selectedTab: RemoteBrowserTabDTO? {
        if let selectedTabID,
           let selected = workspace.browserTabs.first(where: { $0.id == selectedTabID }) {
            return selected
        }
        return workspace.browserTabs.first(where: { $0.isActive })
            ?? workspace.browserTabs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.browserTabs.isEmpty {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel("Refresh browser preview")
            }
        }
        .task(id: activity.changeSequence) {
            activity.markBrowserSeen()
            guard loadsRemotely else { return }
            await refresh()
        }
    }

    private var browserHeader: some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                Text(selectedTitle)
                    .font(.headline)
                    .foregroundStyle(theme.label)
                    .lineLimit(1)

                if let displayURL = selectedTab?.displayURL {
                    Text(displayURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
        if workspace.browserTabs.isEmpty {
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
                    .clipShape(RoundedRectangle(
                        cornerRadius: theme.controlRadius,
                        style: .continuous
                    ))
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: theme.controlRadius,
                            style: .continuous
                        )
                        .stroke(theme.border, lineWidth: theme.borderWidth)
                    }
                    .padding(MobileDesign.Spacing.inset)
            }
            .scrollIndicators(.hidden)
        } else if isLoading {
            VStack(spacing: MobileDesign.Spacing.medium) {
                ProgressView()
                Text("Updating browser preview…")
                    .foregroundStyle(theme.secondaryLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func refresh() async {
        isLoading = true
        loadError = nil
        do {
            let fetched = try await client.workspace(sessionID: session.id)
            guard !Task.isCancelled else { return }
            workspace = fetched
            activity.reconcile(fetched)

            let selected = selectedTabID.flatMap { selectedID in
                fetched.browserTabs.first(where: { $0.id == selectedID })
            } ?? fetched.browserTabs.first(where: { $0.isActive })
                ?? fetched.browserTabs.first
            selectedTabID = selected?.id

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
            guard !Task.isCancelled, selectedTabID == tab.id,
                  let image = UIImage(data: data) else {
                if !Task.isCancelled, selectedTabID == tab.id {
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
            if selectedTabID == tab.id {
                preview = nil
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }
}
