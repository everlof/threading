import AppKit
import Foundation
import Network

/// Something that may have moved the Mac off the path its hosted control socket was using.
enum RemoteHostedConnectivityChange: Equatable, Sendable {
    /// The Mac woke from sleep. A socket that slept through a network's idle timeout is dead and
    /// nothing on it says so.
    case systemWake
    /// The network path changed and settled. `isSatisfied` is whether it reaches anything now.
    case networkPath(isSatisfied: Bool)
}

/// Where `RemoteHostedServiceController` hears about wakes and path changes. A protocol so a
/// test can deliver a change on demand instead of waiting for the machine to sleep.
@MainActor
protocol RemoteHostedConnectivityObserving: AnyObject {
    func start(onChange: @escaping @MainActor (RemoteHostedConnectivityChange) -> Void)
    func stop()
}

private enum RemoteHostedConnectivityDefaults {
    /// A handoff between networks reports several paths in a row; only the one it settles on
    /// matters, and a socket asked mid-handoff would be asked again anyway.
    static let pathSettleDelay: TimeInterval = 1
    static let queueLabel = "codes.threading.remote.hosted-connectivity"
}

/// Watches system wake and the network path for as long as Hosted Direct is wanted.
///
/// The LAN listener already rebuilds on a path change (`RemoteListenerSet`), but the hosted
/// control socket is not bound to an address it can re-read: it is one outbound connection that
/// silently stops working. On 2026-09-17 a laptop woke at 04:50 and a phone was still refused with
/// `hostOffline` hours later. These signals are what lets the controller ask the socket at once.
///
/// Every path update after the first is passed on once it settles, without trying to judge
/// whether it was material: asking a live socket costs one keepalive round trip, and a Wi-Fi
/// network change on the same interface — the case that kills the socket — is invisible to a
/// filter on interface kinds.
@MainActor
final class RemoteHostedConnectivityMonitor: RemoteHostedConnectivityObserving {
    // Written on the main actor and read in deinit, which is nonisolated: a controller that is
    // dropped without `stop()` — a test fixture, a replaced environment — must not leave a path
    // monitor running and a wake observer registered for the life of the process.
    nonisolated(unsafe) private var pathMonitor: NWPathMonitor?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    private var settleTask: Task<Void, Never>?
    private var onChange: (@MainActor (RemoteHostedConnectivityChange) -> Void)?
    private var hasSeenInitialPath = false

    deinit {
        pathMonitor?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func start(onChange: @escaping @MainActor (RemoteHostedConnectivityChange) -> Void) {
        self.onChange = onChange
        guard pathMonitor == nil else { return }
        hasSeenInitialPath = false

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.pathUpdated(isSatisfied: isSatisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: RemoteHostedConnectivityDefaults.queueLabel))
        pathMonitor = monitor

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onChange?(.systemWake)
            }
        }
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        settleTask?.cancel()
        settleTask = nil
        onChange = nil
    }

    private func pathUpdated(isSatisfied: Bool) {
        // NWPathMonitor reports the current path as soon as it starts; that is not a change.
        guard hasSeenInitialPath else {
            hasSeenInitialPath = true
            return
        }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RemoteHostedConnectivityDefaults.pathSettleDelay))
            guard !Task.isCancelled else { return }
            self?.onChange?(.networkPath(isSatisfied: isSatisfied))
        }
    }
}
