import AppKit
import Foundation
import LinuxWindowBridge

/// Keeps SDL pumping on its owning thread. Worker completion wakes its blocking wait;
/// the next host turn drains MainActor callbacks before deciding which pixels are owed.
@MainActor
final class NativeUIWorkLoop {
    private let token: UUID

    init(window: OpaquePointer) {
        let identity = tw_worker_wake_identity(window)
        token = NSWindowWorkerDelivery.shared.install { _ = tw_worker_wake(identity) }
    }

    @discardableResult
    func drain() -> Bool { NSWindowWorkerDelivery.shared.drain() }
    func close() { NSWindowWorkerDelivery.shared.uninstall(token) }
}
