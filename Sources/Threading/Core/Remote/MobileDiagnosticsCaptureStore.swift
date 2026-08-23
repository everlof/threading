import Foundation
import os
import ThreadingRemoteKit

struct MobileDiagnosticsStoredCapture: Codable, Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let storedAt: String
    let capture: RemoteMobileDiagnosticsCaptureDTO
}

struct MobileDiagnosticsDeviceSummary: Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let isConnected: Bool
    let latestCapture: RemoteMobileDiagnosticsCaptureDTO?
    let storedAt: String?
}

/// Opt-in shipping custody for evidence copied from a paired iPhone.
///
/// Live socket identities, pending request nonces, the enabled gate and the bounded disk cache
/// share one lock. A phone may advertise while the Mac switch is off so enabling can take effect
/// immediately, but no request is minted and no upload is accepted until the persisted Mac opt-in
/// is on. Turning it off clears every outstanding nonce synchronously.
final class MobileDiagnosticsCaptureStore: @unchecked Sendable {
    static let shared = MobileDiagnosticsCaptureStore()

    static let maximumCaptures = 40
    static let maximumCapturesPerDevice = 8
    static let maximumDiagnostics = RemoteDiagnosticUploadPolicy.maximumRecordsPerUpload
    static let maximumScreenshotBytes = 420 * 1024
    static let maximumEncodedCaptureBytes = 900 * 1024
    static let requestLifetime: TimeInterval = 30
    static let automaticRequestInterval: TimeInterval = 60
    private static let maximumRememberedOutcomes = 64
    private static let rememberedOutcomeLifetime: TimeInterval = 60

    private struct PendingRequest {
        let deviceID: String
        let expiresAt: Date
        let automatic: Bool
    }

    private struct ManualRequest {
        let deviceID: String
    }

    private struct CaptureWaiter {
        let token: UUID
        let continuation: CheckedContinuation<CaptureWaitOutcome, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private struct RememberedOutcome {
        let outcome: CaptureWaitOutcome
        let recordedAt: Date
    }

    private struct ConnectionRecord {
        let connection: RemoteConnection
        let deviceName: String
    }

    private struct State {
        var isEnabled: Bool
        var consentGeneration: UInt64 = 0
        var captures: [MobileDiagnosticsStoredCapture]
        var connections: [String: ConnectionRecord] = [:]
        var pending: [String: PendingRequest] = [:]
        var manualRequests: [String: ManualRequest] = [:]
        var waiters: [String: CaptureWaiter] = [:]
        var rememberedOutcomes: [String: RememberedOutcome] = [:]
        var lastAutomaticRequest: [String: Date] = [:]
    }

    enum StoreError: Error, Equatable, Sendable {
        case disabled
        case unsolicited
        case invalid
        case persistence
    }

    enum CaptureWaitOutcome: Equatable, Sendable {
        case captured(MobileDiagnosticsStoredCapture)
        case disabled
        case disconnected
        case timedOut
        case cancelled
        case failed(StoreError)
    }

    private let directory: URL
    private let lock: OSAllocatedUnfairLock<State>
    private let beforePublishingCapture: (@Sendable () -> Void)?
    private var settingsObserver: NSObjectProtocol?

    init(
        directory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent("MobileDiagnosticsCaptures", isDirectory: true),
        isEnabled: Bool = MobileDiagnosticsCaptureStore.persistedFeatureEnabled(),
        observesSettings: Bool = true,
        beforePublishingCapture: (@Sendable () -> Void)? = nil
    ) {
        self.directory = directory
        self.beforePublishingCapture = beforePublishingCapture
        lock = OSAllocatedUnfairLock(initialState: State(
            isEnabled: isEnabled,
            captures: Self.loadCaptures(from: directory)
        ))
        if observesSettings {
            settingsObserver = NotificationCenter.default.addObserver(
                forName: AppSettingsDidChange.name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setEnabled(Self.persistedFeatureEnabled())
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        let waiters = lock.withLock { state -> [CaptureWaiter] in
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            state.manualRequests.removeAll()
            state.pending.removeAll()
            return waiters
        }
        Self.resume(waiters, with: .cancelled)
    }

    var isEnabled: Bool {
        lock.withLock { $0.isEnabled }
    }

    var captureCount: Int {
        lock.withLock { $0.captures.count }
    }

    func register(_ connection: RemoteConnection, deviceID: String, deviceName: String?) {
        let name = Self.normalizedDeviceName(deviceName)
        lock.withLock { state in
            state.connections[deviceID] = ConnectionRecord(
                connection: connection,
                deviceName: name
            )
        }
    }

    func unregister(_ connection: RemoteConnection) {
        let waiters = lock.withLock { state -> [CaptureWaiter] in
            let removedDevices = Set(state.connections.compactMap { deviceID, record in
                record.connection === connection ? deviceID : nil
            })
            state.connections = state.connections.filter {
                $0.value.connection !== connection
            }
            let manualRequestIDs = state.manualRequests.compactMap { requestID, request in
                removedDevices.contains(request.deviceID) ? requestID : nil
            }
            let waiters = Self.terminateManualRequests(
                manualRequestIDs,
                outcome: .disconnected,
                state: &state
            )
            state.pending = state.pending.filter { !removedDevices.contains($0.value.deviceID) }
            return waiters
        }
        Self.resume(waiters, with: .disconnected)
    }

    func setEnabled(_ enabled: Bool) {
        let transition: (connectedDeviceIDs: [String], waiters: [CaptureWaiter]) = lock.withLock {
            state in
            guard state.isEnabled != enabled else { return ([], []) }
            state.isEnabled = enabled
            state.consentGeneration &+= 1
            let waiters = enabled ? [] : Self.terminateManualRequests(
                Array(state.manualRequests.keys),
                outcome: .disabled,
                state: &state
            )
            state.pending.removeAll()
            state.lastAutomaticRequest.removeAll()
            return (enabled ? Array(state.connections.keys) : [], waiters)
        }
        Self.resume(transition.waiters, with: .disabled)
        for deviceID in transition.connectedDeviceIDs {
            _ = requestCapture(
                deviceID: deviceID,
                screenshotPolicy: .latestIncident,
                automatic: true
            )
        }
    }

    @discardableResult
    func requestCapture(
        deviceID: String,
        screenshotPolicy: RemoteMobileDiagnosticsCaptureRequestDTO.ScreenshotPolicy,
        automatic: Bool,
        now: Date = Date()
    ) -> String? {
        let result: (RemoteConnection, RemoteMobileDiagnosticsCaptureRequestDTO)? = lock.withLock {
            state in
            // Manual callers own an explicit timeout and must receive its terminal result.
            // Expired fire-and-forget requests can be forgotten immediately.
            state.pending = state.pending.filter {
                $0.value.expiresAt > now || !$0.value.automatic
            }
            guard state.isEnabled, let live = state.connections[deviceID] else { return nil }
            if automatic,
               let last = state.lastAutomaticRequest[deviceID],
               now.timeIntervalSince(last) < Self.automaticRequestInterval {
                return nil
            }
            if automatic { state.lastAutomaticRequest[deviceID] = now }
            let requestID = UUID().uuidString.lowercased()
            state.pending[requestID] = PendingRequest(
                deviceID: deviceID,
                expiresAt: now.addingTimeInterval(Self.requestLifetime),
                automatic: automatic
            )
            if !automatic {
                state.manualRequests[requestID] = ManualRequest(
                    deviceID: deviceID
                )
            }
            return (
                live.connection,
                RemoteMobileDiagnosticsCaptureRequestDTO(
                    requestID: requestID,
                    screenshotPolicy: screenshotPolicy
                )
            )
        }
        guard let result, let data = try? JSONEncoder().encode(result.1) else { return nil }
        result.0.sendText(String(decoding: data, as: UTF8.self))
        return result.1.requestID
    }

    /// Awaits the terminal state of one manually requested capture without polling.
    ///
    /// The nonce-owning store is the only layer that can distinguish a capture from consent
    /// revocation, disconnect, timeout, cancellation, or persistence failure. Remembering a
    /// bounded terminal result closes the race where one of those events happens just before the
    /// caller installs its continuation.
    func waitForCapture(
        requestID: String,
        timeout: Duration
    ) async -> CaptureWaitOutcome {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = lock.withLock { state -> CaptureWaitOutcome? in
                    Self.pruneRememberedOutcomes(state: &state, now: Date())
                    if let remembered = state.rememberedOutcomes.removeValue(
                        forKey: requestID
                    ) {
                        return remembered.outcome
                    }
                    if let stored = state.captures.first(where: {
                        $0.capture.requestID == requestID
                    }) {
                        state.manualRequests.removeValue(forKey: requestID)
                        state.pending.removeValue(forKey: requestID)
                        state.rememberedOutcomes.removeValue(forKey: requestID)
                        return .captured(stored)
                    }
                    guard state.manualRequests[requestID] != nil else {
                        return state.isEnabled ? .cancelled : .disabled
                    }
                    guard state.waiters[requestID] == nil else {
                        return .failed(.unsolicited)
                    }
                    state.waiters[requestID] = CaptureWaiter(
                        token: token,
                        continuation: continuation,
                        timeoutTask: nil
                    )
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finishManualRequest(
                        requestID: requestID,
                        outcome: .timedOut,
                        rememberWithoutWaiter: false
                    )
                }
                let waiterAlreadyFinished = lock.withLock { state -> Bool in
                    guard var waiter = state.waiters[requestID], waiter.token == token else {
                        return true
                    }
                    waiter.timeoutTask = timeoutTask
                    state.waiters[requestID] = waiter
                    return false
                }
                if waiterAlreadyFinished { timeoutTask.cancel() }
            }
        } onCancel: {
            self.finishManualRequest(
                requestID: requestID,
                outcome: .cancelled,
                rememberWithoutWaiter: true
            )
        }
    }

    func accept(
        _ capture: RemoteMobileDiagnosticsCaptureDTO,
        from deviceID: String,
        deviceName: String?,
        now: Date = Date()
    ) throws -> MobileDiagnosticsStoredCapture {
        guard isEnabled else { throw StoreError.disabled }
        guard Self.accepts(capture, now: now) else { throw StoreError.invalid }

        let authorization = lock.withLock {
            state -> (
                requested: Bool,
                deviceName: String,
                consentGeneration: UInt64,
                isManual: Bool
            ) in
            guard state.isEnabled else { return (false, "", state.consentGeneration, false) }
            guard let pending = state.pending[capture.requestID],
                  pending.deviceID == deviceID,
                  pending.expiresAt > now else {
                return (false, "", state.consentGeneration, false)
            }
            state.pending.removeValue(forKey: capture.requestID)
            let isManual = state.manualRequests[capture.requestID] != nil
            return (
                true,
                state.connections[deviceID]?.deviceName
                    ?? Self.normalizedDeviceName(deviceName),
                state.consentGeneration,
                isManual
            )
        }
        guard authorization.requested else {
            if !isEnabled { throw StoreError.disabled }
            throw StoreError.unsolicited
        }

        let stored = MobileDiagnosticsStoredCapture(
            deviceID: deviceID,
            deviceName: authorization.deviceName,
            storedAt: Self.timestamp(now),
            capture: capture
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(stored)
        } catch {
            if authorization.isManual {
                finishManualRequest(
                    requestID: capture.requestID,
                    outcome: .failed(.persistence)
                )
            }
            throw StoreError.persistence
        }
        guard data.count <= Self.maximumEncodedCaptureBytes else {
            if authorization.isManual {
                finishManualRequest(
                    requestID: capture.requestID,
                    outcome: .failed(.invalid)
                )
            }
            throw StoreError.invalid
        }
        let destination = directory.appendingPathComponent("\(capture.captureID).json")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: [.atomic])
            let verified = try JSONDecoder().decode(
                MobileDiagnosticsStoredCapture.self,
                from: Data(contentsOf: destination, options: [.mappedIfSafe])
            )
            guard verified == stored else { throw StoreError.persistence }
        } catch {
            if authorization.isManual {
                finishManualRequest(
                    requestID: capture.requestID,
                    outcome: .failed(.persistence)
                )
            }
            throw StoreError.persistence
        }

        beforePublishingCapture?()
        let removed: [String]? = lock.withLock { state in
            // The settings notification may arrive while the verified atomic write is in
            // progress. Publish only under the exact consent generation that minted the nonce.
            guard state.isEnabled,
                  state.consentGeneration == authorization.consentGeneration else { return nil }
            var removed: [String] = []
            state.captures.removeAll { $0.capture.captureID == capture.captureID }
            state.captures.append(stored)
            state.captures.sort { $0.storedAt > $1.storedAt }

            var perDevice: [String: Int] = [:]
            state.captures = state.captures.filter { candidate in
                let count = perDevice[candidate.deviceID, default: 0]
                guard count < Self.maximumCapturesPerDevice else {
                    removed.append(candidate.capture.captureID)
                    return false
                }
                perDevice[candidate.deviceID] = count + 1
                return true
            }
            if state.captures.count > Self.maximumCaptures {
                removed.append(contentsOf: state.captures.dropFirst(Self.maximumCaptures).map {
                    $0.capture.captureID
                })
                state.captures.removeLast(state.captures.count - Self.maximumCaptures)
            }
            return removed
        }
        guard let removed else {
            try? FileManager.default.removeItem(at: destination)
            if authorization.isManual {
                finishManualRequest(requestID: capture.requestID, outcome: .disabled)
            }
            throw StoreError.disabled
        }
        for captureID in Set(removed) {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(captureID).json")
            )
        }
        if authorization.isManual {
            finishManualRequest(
                requestID: capture.requestID,
                outcome: .captured(stored),
                rememberWithoutWaiter: false
            )
        }
        return stored
    }

    func deviceSummaries() -> [MobileDiagnosticsDeviceSummary] {
        lock.withLock { state in
            let ids = Set(state.captures.map(\.deviceID)).union(state.connections.keys)
            return ids.map { deviceID in
                let latest = state.captures.first { $0.deviceID == deviceID }
                return MobileDiagnosticsDeviceSummary(
                    deviceID: deviceID,
                    deviceName: state.connections[deviceID]?.deviceName
                        ?? latest?.deviceName
                        ?? "iPhone",
                    isConnected: state.connections[deviceID] != nil,
                    latestCapture: latest?.capture,
                    storedAt: latest?.storedAt
                )
            }.sorted { ($0.storedAt ?? "") > ($1.storedAt ?? "") }
        }
    }

    func latestCapture(deviceID: String? = nil) -> MobileDiagnosticsStoredCapture? {
        lock.withLock { state in
            if let deviceID { return state.captures.first { $0.deviceID == deviceID } }
            return state.captures.first
        }
    }

    @discardableResult
    func clearCaptures() -> Int {
        let captureIDs = lock.withLock { state -> [String] in
            let ids = state.captures.map { $0.capture.captureID }
            state.captures.removeAll()
            return ids
        }
        for captureID in captureIDs {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(captureID).json")
            )
        }
        return captureIDs.count
    }

    static func accepts(_ capture: RemoteMobileDiagnosticsCaptureDTO, now: Date) -> Bool {
        guard capture.schemaVersion == RemoteMobileDiagnosticsCaptureDTO.currentSchemaVersion,
              UUID(uuidString: capture.captureID) != nil,
              UUID(uuidString: capture.requestID) != nil,
              capture.appVersion.utf8.count <= 64,
              capture.appBuild.utf8.count <= 64,
              capture.operatingSystem.utf8.count <= 160,
              capture.deviceModel.utf8.count <= 64,
              capture.applicationState == .active
                || capture.applicationState == .inactive
                || capture.applicationState == .background,
              capture.connectionState == .idle
                || capture.connectionState == .connecting
                || capture.connectionState == .online
                || capture.connectionState == .offline,
              capture.activeEndpointKind == .lan,
              (0...64).contains(capture.pairedHostCount),
              (0...10_000).contains(capture.visibleSessionCount),
              !capture.diagnostics.isEmpty,
              capture.diagnostics.count <= maximumDiagnostics,
              RemoteDiagnosticUploadPolicy.accepts(
                RemoteDiagnosticUploadRequestDTO(source: .iOSClient, records: capture.diagnostics),
                now: now
              ) else { return false }

        if let encoded = capture.screenshotJPEGBase64 {
            guard capture.screenshotKind == .current || capture.screenshotKind == .incident,
                  let image = Data(base64Encoded: encoded),
                  !image.isEmpty,
                  image.count <= maximumScreenshotBytes,
                  image.starts(with: [0xFF, 0xD8]),
                  image.suffix(2) == Data([0xFF, 0xD9]) else { return false }
        } else if capture.screenshotKind != nil {
            return false
        }
        return true
    }

    private static func loadCaptures(from directory: URL) -> [MobileDiagnosticsStoredCapture] {
        guard let urls = try? RemoteBoundedDirectoryReader.shallowContents(
            of: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            maximumEntries: maximumCaptures * 3
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count <= maximumEncodedCaptureBytes,
                  let stored = try? JSONDecoder().decode(
                    MobileDiagnosticsStoredCapture.self,
                    from: data
                  ),
                  accepts(stored.capture, now: Date()) else { return nil }
            return stored
        }
        .sorted { $0.storedAt > $1.storedAt }
        .prefix(maximumCaptures)
        .map { $0 }
    }

    private static func persistedFeatureEnabled() -> Bool {
        AppSettingDefinitions.localDiagnosticsEnabled.read(from: .standard) ?? false
    }

    private static func normalizedDeviceName(_ value: String?) -> String {
        let trimmed = (value ?? "iPhone").trimmingCharacters(in: .whitespacesAndNewlines)
        let scalarPrefix = String(trimmed.unicodeScalars.prefix(64))
        return scalarPrefix.isEmpty ? "iPhone" : scalarPrefix
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func finishManualRequest(
        requestID: String,
        outcome: CaptureWaitOutcome,
        rememberWithoutWaiter: Bool = true
    ) {
        let waiter = lock.withLock { state -> CaptureWaiter? in
            let wasManual = state.manualRequests.removeValue(forKey: requestID) != nil
            state.pending.removeValue(forKey: requestID)
            if let waiter = state.waiters.removeValue(forKey: requestID) {
                state.rememberedOutcomes.removeValue(forKey: requestID)
                return waiter
            }
            if rememberWithoutWaiter, wasManual {
                state.rememberedOutcomes[requestID] = RememberedOutcome(
                    outcome: outcome,
                    recordedAt: Date()
                )
                Self.pruneRememberedOutcomes(state: &state, now: Date())
            }
            return nil
        }
        guard let waiter else { return }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: outcome)
    }

    private static func terminateManualRequests(
        _ requestIDs: [String],
        outcome: CaptureWaitOutcome,
        state: inout State
    ) -> [CaptureWaiter] {
        var waiters: [CaptureWaiter] = []
        let now = Date()
        for requestID in requestIDs {
            guard state.manualRequests.removeValue(forKey: requestID) != nil else { continue }
            state.pending.removeValue(forKey: requestID)
            if let waiter = state.waiters.removeValue(forKey: requestID) {
                waiters.append(waiter)
            } else {
                state.rememberedOutcomes[requestID] = RememberedOutcome(
                    outcome: outcome,
                    recordedAt: now
                )
            }
        }
        pruneRememberedOutcomes(state: &state, now: now)
        return waiters
    }

    private static func resume(
        _ waiters: [CaptureWaiter],
        with outcome: CaptureWaitOutcome
    ) {
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: outcome)
        }
    }

    private static func pruneRememberedOutcomes(state: inout State, now: Date) {
        state.rememberedOutcomes = state.rememberedOutcomes.filter {
            now.timeIntervalSince($0.value.recordedAt) <= rememberedOutcomeLifetime
        }
        let excess = state.rememberedOutcomes.count - maximumRememberedOutcomes
        guard excess > 0 else { return }
        let oldest = state.rememberedOutcomes.sorted {
            $0.value.recordedAt < $1.value.recordedAt
        }.prefix(excess)
        for (requestID, _) in oldest {
            state.rememberedOutcomes.removeValue(forKey: requestID)
        }
    }
}
