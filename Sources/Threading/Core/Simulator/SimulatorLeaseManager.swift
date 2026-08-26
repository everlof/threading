import Foundation

protocol SimulatorLeaseManaging: Sendable {
    func availableDevices() async throws -> [SimulatorDevice]
    func acquire(deviceID: SimulatorDeviceID) async throws -> SimulatorDeviceLease
    func release(_ lease: SimulatorDeviceLease) async
}

/// Shares exact device boot ownership across panes and holds the final release briefly.
///
/// Without this registry, a second pane sees a device booted by the first and mistakes it for a
/// user-owned boot. Closing the first pane can then shut the second pane's device down. Reference
/// counting the original capability is what preserves the real owner, while the short grace avoids
/// boot/shutdown churn when a tab is immediately restored or moved.
actor SimulatorLeaseManager: SimulatorLeaseManaging {
    static let shared = SimulatorLeaseManager(control: SimctlSimulatorControl())

    private struct Entry {
        let lease: SimulatorDeviceLease
        var referenceCount: Int
        var releaseToken: UUID?
        var releaseTask: Task<Void, Never>?
    }

    private struct Acquisition {
        let token: UUID
        let task: Task<SimulatorDeviceLease, Error>
    }

    private let control: any SimulatorControlling
    private let releaseGraceNanoseconds: UInt64
    private var entries: [SimulatorDeviceID: Entry] = [:]
    private var acquisitions: [SimulatorDeviceID: Acquisition] = [:]

    init(
        control: any SimulatorControlling,
        releaseGraceNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.control = control
        self.releaseGraceNanoseconds = releaseGraceNanoseconds
    }

    func availableDevices() async throws -> [SimulatorDevice] {
        try await control.availableDevices()
    }

    func acquire(deviceID: SimulatorDeviceID) async throws -> SimulatorDeviceLease {
        if var entry = entries[deviceID] {
            entry.releaseTask?.cancel()
            entry.releaseTask = nil
            entry.releaseToken = nil
            entry.referenceCount += 1
            entries[deviceID] = entry
            return entry.lease
        }

        let acquisition: Acquisition
        if let existing = acquisitions[deviceID] {
            acquisition = existing
        } else {
            let control = control
            let created = Acquisition(
                token: UUID(),
                task: Task { try await control.prepare(deviceID: deviceID) }
            )
            acquisitions[deviceID] = created
            acquisition = created
        }

        do {
            let lease = try await acquisition.task.value
            if acquisitions[deviceID]?.token == acquisition.token { acquisitions[deviceID] = nil }
            if var entry = entries[deviceID] {
                entry.referenceCount += 1
                entries[deviceID] = entry
                return entry.lease
            }
            entries[deviceID] = Entry(
                lease: lease,
                referenceCount: 1,
                releaseToken: nil,
                releaseTask: nil
            )
            return lease
        } catch {
            if acquisitions[deviceID]?.token == acquisition.token { acquisitions[deviceID] = nil }
            throw error
        }
    }

    func release(_ lease: SimulatorDeviceLease) async {
        let deviceID = lease.device.id
        guard var entry = entries[deviceID], entry.lease == lease else { return }
        guard entry.referenceCount > 0 else { return }
        entry.referenceCount -= 1
        guard entry.referenceCount == 0 else {
            entries[deviceID] = entry
            return
        }

        let token = UUID()
        entry.releaseToken = token
        let delay = releaseGraceNanoseconds
        entry.releaseTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            await self?.finishRelease(deviceID: deviceID, token: token)
        }
        entries[deviceID] = entry
    }

    private func finishRelease(deviceID: SimulatorDeviceID, token: UUID) async {
        guard let entry = entries[deviceID],
              entry.referenceCount == 0,
              entry.releaseToken == token else { return }
        entries[deviceID] = nil
        try? await control.release(entry.lease)
    }
}
