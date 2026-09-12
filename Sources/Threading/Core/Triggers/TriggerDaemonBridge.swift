import AppKit
import Foundation
import Security
import ServiceManagement

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

    @discardableResult
    static func publish(_ installations: [TriggerSourceInstallation]) throws -> Bool {
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
        let payload = TriggerDaemonConfiguration(
            schemaVersion: 1,
            generation: UUID(),
            sources: sources
        )
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
        return !sources.isEmpty
    }
}

enum TriggerSourceCredentialStore {
    private static let service = "codes.threading.trigger-source"
    private static var accessGroup: String? {
        #if DEBUG
        nil
        #else
        "SMQ3E8Y57T.codes.threading.triggers"
        #endif
    }

    static func save(_ secret: String, reference: String) throws {
        let data = Data(secret.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated))
        }
        var insertion = query
        insertion[kSecValueData as String] = data
        let added = SecItemAdd(insertion as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(added))
        }
    }

    static func deleteAll() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(reference: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
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

    func reconcile(shouldRun: Bool) {
        guard !StateManager.isHostedTest, !RecoveryMode.isActive else { return }
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
