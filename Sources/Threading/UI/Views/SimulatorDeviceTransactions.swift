import Foundation

/// Quiesces every direct viewer of one exact device while its public CoreSimulator service runs.
/// Boot leases may be shared across sessions; transaction exclusion must have that same scope.
@MainActor
final class SimulatorDeviceTransactions {
    static let shared = SimulatorDeviceTransactions()

    private final class Viewer {
        weak var controller: SimulatorPaneViewController?
        init(_ controller: SimulatorPaneViewController) { self.controller = controller }
    }
    private struct Entry {
        var viewers: [ObjectIdentifier: Viewer] = [:]
        var transactions = 0
    }
    private var entries: [SimulatorDeviceID: Entry] = [:]

    func register(_ controller: SimulatorPaneViewController, for device: SimulatorDeviceID) {
        var entry = entries[device] ?? Entry()
        let identity = ObjectIdentifier(controller)
        guard entry.viewers[identity] == nil else { return }
        entry.viewers = entry.viewers.filter { $0.value.controller != nil }
        entry.viewers[identity] = Viewer(controller)
        entries[device] = entry
        for _ in 0..<entry.transactions { controller.suspendDeviceTransaction() }
    }

    func unregister(_ controller: SimulatorPaneViewController, from device: SimulatorDeviceID) {
        guard var entry = entries[device] else { return }
        entry.viewers.removeValue(forKey: ObjectIdentifier(controller))
        entries[device] = entry.viewers.isEmpty && entry.transactions == 0 ? nil : entry
        controller.clearDeviceTransactions()
    }

    /// A fallback poll asks before taking a public screenshot, rather than suspending the device's
    /// direct viewers on every interval.
    func hasDirectViewer(of device: SimulatorDeviceID, besides controller: SimulatorPaneViewController) -> Bool {
        entries[device]?.viewers.values.contains {
            guard let viewer = $0.controller, viewer !== controller else { return false }
            return viewer.holdsDirectStream
        } ?? false
    }

    func begin(on device: SimulatorDeviceID) {
        var entry = entries[device] ?? Entry()
        entry.viewers = entry.viewers.filter { $0.value.controller != nil }
        entry.transactions += 1
        entries[device] = entry
        for viewer in entry.viewers.values { viewer.controller?.suspendDeviceTransaction() }
    }

    func end(on device: SimulatorDeviceID) {
        guard var entry = entries[device], entry.transactions > 0 else { return }
        entry.transactions -= 1
        entries[device] = entry.viewers.isEmpty && entry.transactions == 0 ? nil : entry
        for viewer in entry.viewers.values { viewer.controller?.resumeDeviceTransaction() }
    }
}
