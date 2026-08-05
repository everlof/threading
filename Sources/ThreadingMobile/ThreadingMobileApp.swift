import ThreadingRemoteKit
import SwiftUI

/// SwiftUI remains an implementation detail of screens that have not moved to UIKit yet. The
/// application and scene lifecycle are UIKit-owned, which lets native routes avoid paying for a
/// root hosting transaction and gives the coordinator one place to migrate screens incrementally.
struct ThreadingMobileHostedRoot: View {
    @ObservedObject var model: RemoteAppModel
    let continuity: MobileSessionContinuityStore
    @ObservedObject var notifications: RemoteNotificationManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environmentObject(model)
            .environmentObject(continuity)
            .environmentObject(notifications)
            .task {
                await notifications.prepare()
                await notifications.sync(hosts: model.hosts)
            }
            .onChange(of: scenePhase) { _, phase in
                notifications.scenePhase = phase
                if phase == .active {
                    MobileDiagnostics.record(.appBecameActive)
                    Task {
                        await notifications.refreshAuthorization()
                        await notifications.sync(hosts: model.hosts)
                    }
                }
            }
            .onChange(of: notifications.deviceToken) { _, _ in
                Task { await notifications.sync(hosts: model.hosts) }
            }
            .onChange(of: model.hosts) { _, hosts in
                Task { await notifications.sync(hosts: hosts) }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: RemoteNotificationBridge.openedNotification
            )) { note in
                guard let event = note.object as? RemoteNotificationEventDTO else { return }
                model.openSessionFromNotification(
                    hostID: event.hostID,
                    sessionID: event.sessionID
                )
            }
    }
}
