import Foundation
import ThreadingRemoteKit

enum RemoteWorkspaceDefaults {
    static let maximumTitleCharacters = 160
    static let maximumPreviewBytes = 8 * 1_024 * 1_024
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
        guard let provider,
              RemoteSessionAccess.isVisible(
                ProjectStore.shared.session(withID: sessionID)
              ) else {
            return nil
        }
        return RemoteWorkspaceDTO(
            browserTabs: provider.remoteBrowserTabs(for: sessionID),
            latestActivityID: latestActivityID
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
}
