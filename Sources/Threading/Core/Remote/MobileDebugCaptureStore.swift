#if DEBUG
import Foundation
import os
import ThreadingRemoteKit

struct MobileDebugStoredCapture: Codable, Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let storedAt: String
    let capture: RemoteMobileDebugCaptureDTO
}

struct MobileDebugDeviceSummary: Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let isConnected: Bool
    let latestCapture: RemoteMobileDebugCaptureDTO?
    let storedAt: String?
}

/// Debug-only custody for evidence copied from a paired iPhone.
///
/// Live socket identities, pending request nonces, and the bounded disk cache share one lock so
/// an upload can only consume a request minted for the same device. File reads happen once at
/// construction; the hot list/inspect path is memory-only and bounded to forty captures.
final class MobileDebugCaptureStore: @unchecked Sendable {
    static let shared = MobileDebugCaptureStore()

    static let maximumCaptures = 40
    static let maximumCapturesPerDevice = 8
    static let maximumDiagnostics = RemoteDiagnosticUploadPolicy.maximumRecordsPerUpload
    static let maximumScreenshotBytes = 420 * 1024
    static let maximumEncodedCaptureBytes = 900 * 1024
    static let requestLifetime: TimeInterval = 30
    static let automaticRequestInterval: TimeInterval = 60

    private struct PendingRequest {
        let deviceID: String
        let expiresAt: Date
    }

    private struct ConnectionRecord {
        let connection: RemoteConnection
        let deviceName: String
    }

    private struct State {
        var captures: [MobileDebugStoredCapture]
        var connections: [String: ConnectionRecord] = [:]
        var pending: [String: PendingRequest] = [:]
        var lastAutomaticRequest: [String: Date] = [:]
    }

    enum StoreError: Error, Equatable {
        case unsolicited
        case invalid
        case persistence
    }

    private let directory: URL
    private let lock: OSAllocatedUnfairLock<State>

    init(directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Threading", isDirectory: true)
        .appendingPathComponent("MobileDebugCaptures", isDirectory: true)) {
        self.directory = directory
        lock = OSAllocatedUnfairLock(initialState: State(
            captures: Self.loadCaptures(from: directory)
        ))
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
        lock.withLock { state in
            state.connections = state.connections.filter {
                $0.value.connection !== connection
            }
        }
    }

    @discardableResult
    func requestCapture(
        deviceID: String,
        screenshotPolicy: RemoteMobileDebugCaptureRequestDTO.ScreenshotPolicy,
        automatic: Bool,
        now: Date = Date()
    ) -> String? {
        let result: (RemoteConnection, RemoteMobileDebugCaptureRequestDTO)? = lock.withLock {
            state in
            state.pending = state.pending.filter { $0.value.expiresAt > now }
            guard let live = state.connections[deviceID] else { return nil }
            if automatic,
               let last = state.lastAutomaticRequest[deviceID],
               now.timeIntervalSince(last) < Self.automaticRequestInterval {
                return nil
            }
            if automatic { state.lastAutomaticRequest[deviceID] = now }
            let requestID = UUID().uuidString.lowercased()
            state.pending[requestID] = PendingRequest(
                deviceID: deviceID,
                expiresAt: now.addingTimeInterval(Self.requestLifetime)
            )
            return (
                live.connection,
                RemoteMobileDebugCaptureRequestDTO(
                    requestID: requestID,
                    screenshotPolicy: screenshotPolicy
                )
            )
        }
        guard let result else { return nil }
        guard let data = try? JSONEncoder().encode(result.1) else { return nil }
        result.0.sendText(String(decoding: data, as: UTF8.self))
        return result.1.requestID
    }

    func accept(
        _ capture: RemoteMobileDebugCaptureDTO,
        from deviceID: String,
        deviceName: String?,
        now: Date = Date()
    ) throws -> MobileDebugStoredCapture {
        guard Self.accepts(capture, now: now) else { throw StoreError.invalid }

        let authorization = lock.withLock { state -> (requested: Bool, deviceName: String) in
            state.pending = state.pending.filter { $0.value.expiresAt > now }
            guard let pending = state.pending.removeValue(forKey: capture.requestID) else {
                return (false, "")
            }
            guard pending.deviceID == deviceID, pending.expiresAt > now else {
                return (false, "")
            }
            return (
                true,
                state.connections[deviceID]?.deviceName
                    ?? Self.normalizedDeviceName(deviceName)
            )
        }
        guard authorization.requested else { throw StoreError.unsolicited }

        let stored = MobileDebugStoredCapture(
            deviceID: deviceID,
            deviceName: authorization.deviceName,
            storedAt: Self.timestamp(now),
            capture: capture
        )
        let data = try JSONEncoder().encode(stored)
        guard data.count <= Self.maximumEncodedCaptureBytes else { throw StoreError.invalid }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent("\(capture.captureID).json")
            try data.write(to: destination, options: [.atomic])
            let verified = try JSONDecoder().decode(
                MobileDebugStoredCapture.self,
                from: Data(contentsOf: destination, options: [.mappedIfSafe])
            )
            guard verified == stored else { throw StoreError.persistence }
        } catch {
            throw StoreError.persistence
        }

        let removed: [String] = lock.withLock { state in
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
        for captureID in Set(removed) {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(captureID).json")
            )
        }
        return stored
    }

    func deviceSummaries() -> [MobileDebugDeviceSummary] {
        lock.withLock { state in
            let ids = Set(state.captures.map(\.deviceID)).union(state.connections.keys)
            return ids.map { deviceID in
                let latest = state.captures.first { $0.deviceID == deviceID }
                return MobileDebugDeviceSummary(
                    deviceID: deviceID,
                    deviceName: state.connections[deviceID]?.deviceName
                        ?? latest?.deviceName
                        ?? "iPhone",
                    isConnected: state.connections[deviceID] != nil,
                    latestCapture: latest?.capture,
                    storedAt: latest?.storedAt
                )
            }.sorted {
                ($0.storedAt ?? "") > ($1.storedAt ?? "")
            }
        }
    }

    func latestCapture(deviceID: String? = nil) -> MobileDebugStoredCapture? {
        lock.withLock { state in
            if let deviceID {
                return state.captures.first { $0.deviceID == deviceID }
            }
            return state.captures.first
        }
    }

    func capture(requestID: String) -> MobileDebugStoredCapture? {
        lock.withLock { state in
            state.captures.first { $0.capture.requestID == requestID }
        }
    }

    static func accepts(_ capture: RemoteMobileDebugCaptureDTO, now: Date) -> Bool {
        guard capture.schemaVersion == RemoteMobileDebugCaptureDTO.currentSchemaVersion,
              UUID(uuidString: capture.captureID) != nil,
              UUID(uuidString: capture.requestID) != nil,
              capture.appVersion.utf8.count <= 64,
              capture.appBuild.utf8.count <= 64,
              capture.operatingSystem.utf8.count <= 160,
              capture.deviceModel.utf8.count <= 64,
              ["active", "inactive", "background", "unknown"].contains(
                capture.applicationState
              ),
              ["idle", "connecting", "online", "offline"].contains(
                capture.connectionState
              ),
              capture.activeEndpointKind == RemoteHostEndpointKind.lan,
              (0...64).contains(capture.pairedHostCount),
              (0...10_000).contains(capture.visibleSessionCount),
              !capture.diagnostics.isEmpty,
              capture.diagnostics.count <= maximumDiagnostics,
              RemoteDiagnosticUploadPolicy.accepts(
                RemoteDiagnosticUploadRequestDTO(
                    source: .iOSClient,
                    records: capture.diagnostics
                ),
                now: now
              ) else { return false }

        if let encoded = capture.screenshotJPEGBase64 {
            guard capture.screenshotKind == "current" || capture.screenshotKind == "incident",
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

    private static func loadCaptures(from directory: URL) -> [MobileDebugStoredCapture] {
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
                    MobileDebugStoredCapture.self,
                    from: data
                  ),
                  accepts(stored.capture, now: Date()) else { return nil }
            return stored
        }
        .sorted { $0.storedAt > $1.storedAt }
        .prefix(maximumCaptures)
        .map { $0 }
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
}
#endif
