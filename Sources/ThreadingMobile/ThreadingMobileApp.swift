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
                // `onChange(of: scenePhase)` does not fire for the phase the app launches into,
                // so the first foreground is this one.
                model.startDiscovery()
                model.startNetworkPathWatch()
                if model.needsHostStorageRecovery {
                    await model.refresh(reason: .foreground)
                }
                if !model.isEphemeralTerminalWireFixture {
                    await notifications.clearTurnCompletionsOnApplicationActivation()
                    await MobileIssueReportOutbox.shared.setConnectivityRetryActive(true)
                    await notifications.prepare()
                    await notifications.sync(hosts: model.hosts)
                    await MobileIssueReportOutbox.shared.flush()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                notifications.scenePhase = phase
                if phase == .active {
                    MobileDiagnostics.record(.appBecameActive)
                    // Browsing belongs to the foreground: it is a multicast listener, and the
                    // address it finds is only useful while somebody is looking at the app.
                    model.startDiscovery()
                    model.startNetworkPathWatch()
                    Task {
                        await notifications.clearTurnCompletionsOnApplicationActivation()
                        await model.refresh(reason: .foreground)
                        if !model.isEphemeralTerminalWireFixture {
                            await MobileIssueReportOutbox.shared.setConnectivityRetryActive(true)
                            await notifications.refreshAuthorization()
                            await notifications.sync(hosts: model.hosts)
                            await MobileIssueReportOutbox.shared.flush()
                        }
                    }
                } else if phase == .background {
                    model.stopDiscovery()
                    model.stopNetworkPathWatch()
                    model.suspendHostedConnections()
                    if !model.isEphemeralTerminalWireFixture {
                        Task {
                            await MobileIssueReportOutbox.shared.setConnectivityRetryActive(false)
                        }
                    }
                }
            }
            .onChange(of: notifications.deviceToken) { _, _ in
                guard !model.isEphemeralTerminalWireFixture else { return }
                Task { await notifications.sync(hosts: model.hosts) }
            }
            .onChange(of: model.hosts) { _, hosts in
                guard !model.isEphemeralTerminalWireFixture else { return }
                Task { await notifications.sync(hosts: hosts) }
            }
    }
}
