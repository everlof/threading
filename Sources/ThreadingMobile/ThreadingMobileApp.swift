import ThreadingRemoteKit
import SwiftUI

@main
struct ThreadingMobileApp: App {
    @UIApplicationDelegateAdaptor(ThreadingMobileAppDelegate.self)
    private var appDelegate
    @StateObject private var model = RemoteAppModel()
    @StateObject private var notifications = RemoteNotificationManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
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
}
