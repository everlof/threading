import Foundation

protocol SimulatorLeaseManaging: Sendable {
    func availableDevices() async throws -> [SimulatorDevice]
    func acquire(deviceID: SimulatorDeviceID) async throws -> SimulatorDeviceLease
    func refresh(_ lease: SimulatorDeviceLease) async throws -> SimulatorDeviceLease
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
        var validCapabilityIDs: Set<UUID>
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
    private var refreshes: [SimulatorDeviceID: Acquisition] = [:]

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
                validCapabilityIDs: [lease.capabilityID],
                releaseToken: nil,
                releaseTask: nil
            )
            return lease
        } catch {
            if acquisitions[deviceID]?.token == acquisition.token { acquisitions[deviceID] = nil }
            throw error
        }
    }

    /// Revalidates a lease after the public fallback proves its device snapshot is stale.
    ///
    /// Refreshing does not add a reference. Every existing holder may still release the older
    /// capability identity, while new acquisitions receive the refreshed device state and boot
    /// ownership. If Threading originally owned the boot, seeing that same device booted during
    /// refresh must not launder it into user ownership.
    func refresh(_ lease: SimulatorDeviceLease) async throws -> SimulatorDeviceLease {
        let deviceID = lease.device.id
        guard let existingEntry = entries[deviceID],
              existingEntry.referenceCount > 0,
              existingEntry.validCapabilityIDs.contains(lease.capabilityID) else {
            throw SimulatorControlError.deviceNotFound(deviceID)
        }

        let refresh: Acquisition
        if let existing = refreshes[deviceID] {
            refresh = existing
        } else {
            let control = control
            let created = Acquisition(
                token: UUID(),
                task: Task { try await control.prepare(deviceID: deviceID) }
            )
            refreshes[deviceID] = created
            refresh = created
        }

        do {
            let prepared = try await refresh.task.value
            if refreshes[deviceID]?.token == refresh.token { refreshes[deviceID] = nil }
            guard var entry = entries[deviceID],
                  entry.validCapabilityIDs.contains(lease.capabilityID) else {
                try? await control.release(prepared)
                throw SimulatorControlError.deviceNotFound(deviceID)
            }
            let ownership: SimulatorDeviceBootOwnership =
                entry.lease.bootOwnership == .threading ? .threading : prepared.bootOwnership
            let refreshed = SimulatorDeviceLease(
                device: prepared.device,
                bootOwnership: ownership
            )
            entry = Entry(
                lease: refreshed,
                referenceCount: entry.referenceCount,
                validCapabilityIDs: entry.validCapabilityIDs.union([refreshed.capabilityID]),
                releaseToken: entry.releaseToken,
                releaseTask: entry.releaseTask
            )
            entries[deviceID] = entry
            return refreshed
        } catch {
            if refreshes[deviceID]?.token == refresh.token { refreshes[deviceID] = nil }
            throw error
        }
    }

    func release(_ lease: SimulatorDeviceLease) async {
        let deviceID = lease.device.id
        guard var entry = entries[deviceID],
              entry.validCapabilityIDs.contains(lease.capabilityID) else { return }
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
