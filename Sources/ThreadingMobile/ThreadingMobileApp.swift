import ThreadingRemoteKit
import SwiftUI

/// SwiftUI remains an implementation detail of screens that have not moved to UIKit yet. The
/// application and scene lifecycle are UIKit-owned, which lets native routes avoid paying for a
/// root hosting transaction and gives the coordinator one place to migrate screens incrementally.
struct ThreadingMobileHostedRoot: View {
    @ObservedObject var model: RemoteAppModel
    let continuity: MobileSessionContinuityStore
    let keyboards: MobileTerminalKeyboardStore
    @ObservedObject var notifications: RemoteNotificationManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environmentObject(model)
            .environmentObject(continuity)
            .environmentObject(keyboards)
            .environmentObject(notifications)
            .task {
                await notifications.prepare()
                await notifications.sync(hosts: model.hosts)
                await MobileIssueReportOutbox.shared.flush()
            }
            .onChange(of: scenePhase) { _, phase in
                notifications.scenePhase = phase
                if phase == .active {
                    MobileDiagnostics.record(.appBecameActive)
                    Task {
                        await model.refresh()
                        await notifications.refreshAuthorization()
                        await notifications.sync(hosts: model.hosts)
                        await MobileIssueReportOutbox.shared.flush()
                    }
                } else if phase == .background {
                    model.suspendHostedConnections()
                }
            }
            .onChange(of: notifications.deviceToken) { _, _ in
                Task { await notifications.sync(hosts: model.hosts) }
            }
            .onChange(of: model.hosts) { _, hosts in
                Task { await notifications.sync(hosts: hosts) }
            }
    }
}
