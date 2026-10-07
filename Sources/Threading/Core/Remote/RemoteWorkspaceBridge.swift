import Foundation
import ThreadingRemoteKit

enum RemoteWorkspaceDefaults {
    static let maximumTitleCharacters = 160
    static let maximumPreviewBytes = 8 * 1_024 * 1_024
}

/// Exact URLs may leave the Mac only after an owner asks for one shared, loaded web tab.
enum RemoteBrowserLinkPolicy {
    static let maximumURLBytes = 16_384

    static func exportableURL(_ url: URL?, contextKind: BrowserContextKind) -> URL? {
        guard contextKind == .shared,
              let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.absoluteString.utf8.count <= maximumURLBytes
        else {
            return nil
        }
        return url
    }
}

/// The narrow UI seam behind the owner-only remote Workspace.
///
/// Remote Access never reaches into a `WKWebView` or a tab host directly. The window projects
/// bounded browser metadata and a visible PNG through this protocol; the server only handles
/// authorization and transport.
@MainActor
protocol RemoteWorkspaceProviding: AnyObject {
    func remoteBrowserTabs(for sessionID: SessionID) -> [RemoteBrowserTabDTO]
    func remoteBrowserPreview(for sessionID: SessionID, tabID: UUID) async -> Data?
    func remoteBrowserLink(for sessionID: SessionID, tabID: UUID) -> URL?
}

@MainActor
enum RemoteWorkspaceBridge {
    private static weak var provider: RemoteWorkspaceProviding?

    static func install(_ provider: RemoteWorkspaceProviding) {
        self.provider = provider
    }

    static func workspace(
        for sessionID: SessionID,
        latestActivityID: String?
    ) -> RemoteWorkspaceDTO? {
        guard RemoteSessionAccess.isVisible(
                ProjectStore.shared.session(withID: sessionID)
              ) else {
            return nil
        }
        let permission = BrowserPermissionRequests.shared.pending(for: sessionID)
        guard provider != nil || permission != nil else { return nil }
        return RemoteWorkspaceDTO(
            browserTabs: provider?.remoteBrowserTabs(for: sessionID) ?? [],
            latestActivityID: latestActivityID,
            browserPermission: permission
        )
    }

    static func browserPreview(
        for sessionID: SessionID,
        tabID: UUID
    ) async -> Data? {
        guard let provider,
              RemoteSessionAccess.isVisible(
                ProjectStore.shared.session(withID: sessionID)
              ) else {
            return nil
        }
        return await provider.remoteBrowserPreview(for: sessionID, tabID: tabID)
    }

    static func browserLink(for sessionID: SessionID, tabID: UUID) -> RemoteBrowserLinkDTO? {
        guard let provider,
              RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID)),
              let url = provider.remoteBrowserLink(for: sessionID, tabID: tabID)
        else {
            return nil
        }
        return RemoteBrowserLinkDTO(url: url)
    }
}
