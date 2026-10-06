import AppKit
import Foundation
import Security
import ServiceManagement
import ThreadingController

struct TriggerDaemonSourceConfiguration: Codable, Equatable, Sendable {
    let id: TriggerSourceInstallationID
    let sourceType: String
    let baseURL: URL
    let credentialReference: String
    let enabled: Bool
}

struct TriggerDaemonConfiguration: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generation: UUID
    let sources: [TriggerDaemonSourceConfiguration]
    var nextScheduleUnixTime: Double? = nil
    /// Approved probe sources, enabled or paused. An unapproved probe is never written here.
    var probes: [TriggerProbeDaemonSource]? = nil

    /// Whether anything here needs the background listener: a connected source, an enabled
    /// probe or a scheduled automation. The app registers the listener exactly then, and the
    /// Sources page calls an unregistered listener idle, not broken, when this is false.
    var needsListener: Bool {
        !sources.isEmpty || nextScheduleUnixTime != nil || probes?.contains(where: \.enabled) == true
    }
}

enum TriggerDaemonLocations {
    static let notification = Notification.Name("codes.threading.triggerd.inbox-changed")

    static var directory: URL {
        AppDataLocations.supportDirectory.appendingPathComponent("Triggers", isDirectory: true)
    }

    static var configuration: URL {
        directory.appendingPathComponent("sources.json", isDirectory: false)
    }

    static var inbox: URL {
        directory.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Manual-poll requests the daemon consumes on its next tick.
    static var pollRequests: URL {
        directory.appendingPathComponent("Poll Requests", isDirectory: true)
    }
}

enum TriggerDaemonConfigurationStore {
    static let supportedSourceTypes: Set<String> = ["sonda"]

    enum Failure: LocalizedError {
        case malformedSource(String)

        var errorDescription: String? {
            switch self {
            case .malformedSource(let name):
                return "Trigger source “\(name)” is missing its HTTPS base URL or credential."
            }
        }
    }

    /// The credential-free projection the daemon reads. Pure, so the projection rules — above
    /// all that only an approved probe reaches the daemon — are testable without the file.
    static func configuration(
        for installations: [TriggerSourceInstallation], nextScheduleAt: Date? = nil
    ) throws -> TriggerDaemonConfiguration {
        let sources = try installations.compactMap { source -> TriggerDaemonSourceConfiguration? in
            guard source.enabled, supportedSourceTypes.contains(source.sourceType) else { return nil }
            guard case .string(let rawURL)? = source.configuration["base_url"],
                  let url = URL(string: rawURL),
                  url.scheme?.lowercased() == "https",
                  let credentialReference = source.credentialReference,
                  !credentialReference.isEmpty else {
                throw Failure.malformedSource(source.displayName)
            }
            return TriggerDaemonSourceConfiguration(
                id: source.id,
                sourceType: source.sourceType,
                baseURL: url,
                credentialReference: credentialReference,
                enabled: true
            )
        }
        let probes = installations.compactMap { source -> TriggerProbeDaemonSource? in
            guard source.sourceType == TriggerProbeDefaults.sourceType, let probe = source.probe,
                  probe.deletedAt == nil, let approvedHash = probe.approvedHash, probe.isApproved else { return nil }
            return TriggerProbeDaemonSource(id: source.id.rawValue, revision: probe.revision,
                                            spec: TriggerProbeRunSpec(probe.spec),
                                            approvedHash: approvedHash, enabled: source.enabled)
        }
        // Version 1 still: `probes` is additive and an older reader ignores it.
        return TriggerDaemonConfiguration(
            schemaVersion: 1,
            generation: UUID(),
            sources: sources,
            nextScheduleUnixTime: nextScheduleAt?.timeIntervalSince1970,
            probes: probes.isEmpty ? nil : probes
        )
    }

    @discardableResult
    static func publish(_ installations: [TriggerSourceInstallation], nextScheduleAt: Date? = nil) throws -> Bool {
        let payload = try configuration(for: installations, nextScheduleAt: nextScheduleAt)
        try FileManager.default.createDirectory(
            at: TriggerDaemonLocations.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: TriggerDaemonLocations.configuration, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: TriggerDaemonLocations.configuration.path
        )
        return payload.needsListener
    }

    /// Asks the daemon for one poll of an approved probe now. The daemon consumes the request on
    /// its next tick (within seconds) whether or not the probe is still approved by then.
    static func requestPoll(_ id: TriggerSourceInstallationID) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: TriggerDaemonLocations.directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: TriggerDaemonLocations.pollRequests, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let file = TriggerDaemonLocations.pollRequests.appendingPathComponent(id.uuidString, isDirectory: false)
        try Data().write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

extension TriggerProbeRunSpec {
    init(_ spec: ControllerSourceSpec) {
        self.init(executable: spec.executable, script: spec.script, arguments: spec.arguments,
                  environment: spec.environment, secrets: spec.secrets, intervalSeconds: spec.intervalSeconds,
                  schedule: spec.schedule, timeoutSeconds: spec.timeoutSeconds, limit: spec.limit)
    }
}

/// Probe secrets, one login-Keychain item per secret name that the listener may read
/// (`TriggerSecretStore`). Values are written here and read only by the daemon at poll time;
/// nothing reads one back into the app, a prompt or MCP.
enum TriggerProbeSecretStore {
    static func save(_ value: String, name: String, store: TriggerSecretStore = .shared) throws {
        guard SecretName.isValid(name), !value.isEmpty else {
            throw TriggerStore.StoreError.invalidRecord("secret name or value")
        }
        try store.save(value, service: .probeSecret, account: name)
    }

    /// Whether a value is stored, without reading it.
    static func exists(_ name: String) -> Bool {
        TriggerSecretStore.shared.exists(service: .probeSecret, account: name)
    }

    static func deleteAll() throws {
        try TriggerSecretStore.shared.deleteAll(service: .probeSecret)
    }
}

/// Connected sources' credentials, by `credentialReference`, where the listener may read them.
enum TriggerSourceCredentialStore {
    static func save(_ secret: String, reference: String) throws {
        try TriggerSecretStore.shared.save(secret, service: .sourceCredential, account: reference)
    }

    static func deleteAll() throws {
        try TriggerSecretStore.shared.deleteAll(service: .sourceCredential)
    }

    static func delete(reference: String) throws {
        try TriggerSecretStore.shared.delete(service: .sourceCredential, account: reference)
    }
}

struct TriggerDaemonSourceStatus: Codable, Equatable, Sendable {
    let sourceInstallationID: TriggerSourceInstallationID
    let health: TriggerSourceHealth
    let lastCheckedAt: Date
    let lastEventAt: Date?
    let boundedDiagnostic: String?
}

enum TriggerDaemonStatusStore {
    static var directory: URL {
        TriggerDaemonLocations.directory.appendingPathComponent("Source Status", isDirectory: true)
    }

    static func statuses() throws -> [TriggerSourceInstallationID: TriggerDaemonSourceStatus] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [:] }
        let files = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.prefix(256)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try files.reduce(into: [:]) { result, file in
            let status = try decoder.decode(
                TriggerDaemonSourceStatus.self,
                from: Data(contentsOf: file)
            )
            result[status.sourceInstallationID] = status
        }
    }
}

struct TriggerDaemonInboxItem: Sendable {
    let file: URL
    let event: TriggerEvent
}

enum TriggerDaemonInbox {
    static func load(limit: Int = 100) throws -> [TriggerDaemonInboxItem] {
        let manager = FileManager.default
        try manager.createDirectory(
            at: TriggerDaemonLocations.inbox,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let files = try manager.contentsOfDirectory(
            at: TriggerDaemonLocations.inbox,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(max(1, min(limit, 100)))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try files.map { file in
            TriggerDaemonInboxItem(
                file: file,
                event: try decoder.decode(TriggerEvent.self, from: Data(contentsOf: file))
            )
        }
    }

    static func acknowledge(_ item: TriggerDaemonInboxItem) throws {
        try FileManager.default.removeItem(at: item.file)
    }
}

@MainActor
final class TriggerDaemonInboxMonitor {
    static let shared = TriggerDaemonInboxMonitor()
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: TriggerDaemonLocations.notification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await TriggerRuntime.shared.drainDaemonInbox() }
        }
    }
}

enum TriggerDaemonRegistrationDefaults {
    static let plistName = "codes.threading.triggerd.plist"
    static let helperName = "threading-triggerd"
    /// The launchd label in that property list.
    static let label = "codes.threading.triggerd"
}

enum TriggerDaemonRegistrationStatus: String, Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case missingHelper
    case unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }
}

@MainActor
final class TriggerDaemonRegistrationCoordinator {
    static let shared = TriggerDaemonRegistrationCoordinator()
    private let queue = DispatchQueue(label: "codes.threading.triggerd.registration")

    nonisolated static var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(TriggerDaemonRegistrationDefaults.helperName)
    }

    /// ServiceManagement is an XPC boundary. Call this from a bounded worker, never a UI path.
    nonisolated static func currentStatus() -> TriggerDaemonRegistrationStatus {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return .missingHelper
        }
        return TriggerDaemonRegistrationStatus(SMAppService.agent(
            plistName: TriggerDaemonRegistrationDefaults.plistName
        ).status)
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Registers the listener again, which makes launchd start it afresh: for a registration that
    /// is enabled while its process has stopped reporting. A spawn macOS refuses is not helped by
    /// this, and the Sources page does not offer it then.
    func restart() {
        guard !AutomatedRun.isUnderway, !RecoveryMode.isActive,
              FileManager.default.isExecutableFile(atPath: Self.helperURL.path) else { return }
        queue.async {
            let service = SMAppService.agent(plistName: TriggerDaemonRegistrationDefaults.plistName)
            do {
                if service.status == .enabled { try service.unregister() }
                try service.register()
            } catch {
                ThreadingLogger.app.error(
                    "Trigger daemon restart failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    func reconcile(shouldRun: Bool) {
        guard !AutomatedRun.isUnderway, !RecoveryMode.isActive else { return }
        let helper = Self.helperURL
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            ThreadingLogger.app.notice("Trigger daemon helper is not present in this bundle")
            return
        }
        queue.async {
            let service = SMAppService.agent(
                plistName: TriggerDaemonRegistrationDefaults.plistName
            )
            do {
                if shouldRun {
                    guard service.status != .enabled,
                          service.status != .requiresApproval else { return }
                    try service.register()
                } else if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            } catch {
                ThreadingLogger.app.error(
                    "Trigger daemon registration failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }
}
