import Foundation
import ThreadingGlanceKit
import ThreadingRemoteKit
import WidgetKit

enum MobileUsageGlanceIssue {
    case accessRemoved, updateFailed, storageFailed, hostUpdateNeeded

    var message: String {
        switch self {
        case .accessRemoved:
            return MobileL10n.string("Widget access was removed. Connect your Mac to enable it again.")
        case .updateFailed:
            return MobileL10n.string("Widgets could not update. The last reading keeps its original time.")
        case .storageFailed:
            return MobileL10n.string("The widget cache could not be reset. Update Threading or try again.")
        case .hostUpdateNeeded:
            return MobileL10n.string("Update Threading on your Mac to share usage with widgets.")
        }
    }
}

/// App-owned, opt-in publisher. One fetch and one queued invalidation regardless of event rate.
/// Browsing another Mac leaves the chosen Mac's cache intact; it never retargets a widget.
@MainActor
final class MobileUsageGlancePublisher {
    static let preferenceKey = "threading.mobile.widgets.host"
    private let defaults: UserDefaults
    private let store: UsageGlanceStore
    private var task: Task<Void, Never>?
    private var pending: Request?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private(set) var pairingID: String?
    var reportIssue: ((MobileUsageGlanceIssue?) -> Void)?

    private struct Request {
        let pairingID: String
        let hostName: String
        let client: RemoteClient
    }

    init(defaults: UserDefaults = .standard, store: UsageGlanceStore = .shared) {
        self.defaults = defaults
        self.store = store
        pairingID = defaults.string(forKey: Self.preferenceKey)
    }

    func choose(_ id: String?) {
        guard pairingID != id else { return }
        suspend()
        pairingID = id
        defaults.set(id, forKey: Self.preferenceKey)
        clear()
    }

    func suspend() {
        generation &+= 1
        task?.cancel()
        task = nil
        pending = nil
    }

    func refresh(pairingID: String, hostName: String, client: RemoteClient) {
        guard self.pairingID == pairingID else { return }
        pending = Request(pairingID: pairingID, hostName: hostName, client: client)
        guard task == nil else { return }
        let admitted = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == admitted { task = nil } }
            while let request = pending, !Task.isCancelled, generation == admitted {
                pending = nil
                // Coalesce a batch of provider readings without extending the deadline per edge.
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                for attempt in 0..<3 {
                    do {
                        let capacity = try await request.client.fetchUsageCapacity()
                        guard !Task.isCancelled, generation == admitted,
                              pairingID == request.pairingID else { return }
                        sequence += 1
                        let value = UsageGlanceSnapshot(pairingID: request.pairingID,
                            hostName: request.hostName, capacity: capacity, receivedAt: Date())
                        let changed = try await store.publish(value, sequence: sequence)
                        if changed { WidgetCenter.shared.reloadTimelines(ofKind: UsageGlanceStore.widgetKind) }
                        reportIssue?(nil)
                        break
                    } catch is CancellationError { return }
                    catch {
                        guard generation == admitted, !Task.isCancelled else { return }
                        if error is UsageGlanceStoreError {
                            reportIssue?(.storageFailed)
                            return
                        }
                        let accessRemoved: Bool
                        if case RemoteClientError.unauthorized = error { accessRemoved = true }
                        else { accessRemoved = (error as? RemoteClientError)?.statusCode == 403 }
                        if accessRemoved {
                            choose(nil)
                            reportIssue?(.accessRemoved)
                            return
                        }
                        if attempt == 2 {
                            reportIssue?(.updateFailed)
                        } else {
                            do { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) }
                            catch { return }
                        }
                    }
                }
            }
        }
    }

    func clear() {
        sequence += 1
        let admitted = sequence
        Task {
            do {
                try await store.clear(sequence: admitted)
                WidgetCenter.shared.reloadTimelines(ofKind: UsageGlanceStore.widgetKind)
                reportIssue?(nil)
            } catch UsageGlanceStoreError.superseded { }
            catch { reportIssue?(.storageFailed) }
        }
    }
}
