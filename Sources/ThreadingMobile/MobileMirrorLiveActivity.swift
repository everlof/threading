// ActivityKit's asynchronous update/end API predates Sendable annotations on Activity.
// The app's reference and lifecycle remain owned by the main actor.
@preconcurrency import ActivityKit
import Foundation
import ThreadingGlanceKit
import ThreadingRemoteKit

/// The Live Activity of the mirror on the stage.
///
/// Started locally the moment the stage shows, while the app is necessarily in front, so it
/// needs no push. ActivityKit shows it only once the person leaves the app: then it is the way
/// back, and **End** is the way out.
@MainActor
final class MobileMirrorLiveActivity {
    private var activity: Activity<MirrorActivityAttributes>?

    var mirrorID: String? { activity?.attributes.mirrorID }

    func show(macName: String, hostID: String, mirrorID: String, title: String) {
        let content = ActivityContent(
            state: MirrorActivityAttributes.ContentState(sourceTitle: title, updatedAt: Date()),
            staleDate: Date().addingTimeInterval(RemoteMirror.awayLifetime)
        )
        if let activity, activity.attributes.mirrorID == mirrorID {
            Task { await activity.update(content) }
            return
        }
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: MirrorActivityAttributes(macName: macName, hostID: hostID, mirrorID: mirrorID),
            content: content,
            pushType: nil
        )
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Ends every activity for `mirrorID`, including one a previous launch of the app started.
    static func endAll(mirrorID: String) async {
        for activity in Activity<MirrorActivityAttributes>.activities where activity.attributes.mirrorID == mirrorID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
