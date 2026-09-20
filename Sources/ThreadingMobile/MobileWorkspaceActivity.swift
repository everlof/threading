import Combine
import Foundation
import ThreadingRemoteKit

private enum MobileWorkspaceActivityDefaults {
    static let seenBrowserPrefix = "workspace.seen.browser."
}

/// Per-phone acknowledgement for ambient session Workspace changes.
///
/// The Mac owns the current activity id, while this phone alone owns whether it has been seen.
/// That keeps opening Browser here from clearing another paired device's hint.
@MainActor
final class MobileWorkspaceActivity: ObservableObject {
    let sessionID: String

    @Published private(set) var latestBrowserActivityID: String?
    @Published private(set) var seenBrowserActivityID: String?
    @Published private(set) var changeSequence = 0

    private let defaults: UserDefaults

    var hasUnseenBrowser: Bool {
        guard let latestBrowserActivityID else { return false }
        return latestBrowserActivityID != seenBrowserActivityID
    }

    init(sessionID: String, defaults: UserDefaults = .standard) {
        self.sessionID = sessionID
        self.defaults = defaults
        seenBrowserActivityID = defaults.string(
            forKey: MobileWorkspaceActivityDefaults.seenBrowserPrefix
                + sessionID.lowercased()
        )
    }

    func receive(_ event: RemoteWorkspaceChangedDTO) {
        guard event.kind == .browser else { return }
        changeSequence &+= 1
        if let activityID = event.activityID {
            latestBrowserActivityID = activityID
        }
    }

    func reconcile(_ workspace: RemoteWorkspaceDTO) {
        if let activityID = workspace.latestActivityID {
            latestBrowserActivityID = activityID
        }
        if workspace.browserTabs.isEmpty && workspace.browserPermission == nil {
            markBrowserSeen()
        }
    }

    func markBrowserSeen() {
        guard seenBrowserActivityID != latestBrowserActivityID else { return }
        seenBrowserActivityID = latestBrowserActivityID
        if let latestBrowserActivityID {
            defaults.set(latestBrowserActivityID, forKey: seenBrowserKey)
        } else {
            defaults.removeObject(forKey: seenBrowserKey)
        }
    }

    private var seenBrowserKey: String {
        MobileWorkspaceActivityDefaults.seenBrowserPrefix + sessionID.lowercased()
    }
}
