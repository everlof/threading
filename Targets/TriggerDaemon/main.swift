import AppKit
import Foundation
import Security

private struct SourceConfiguration: Decodable {
    let id: UUID
    let sourceType: String
    let baseURL: URL
    let credentialReference: String
    let enabled: Bool
}

private struct DaemonConfiguration: Decodable {
    let schemaVersion: Int
    let sources: [SourceConfiguration]
}

private struct SondaFeed: Decodable {
    let schemaVersion: Int
    let nextCursor: Int64
    let events: [SondaEvent]
}

private struct SondaEvent: Decodable {
    let cursor: Int64
    let caseID: String
    let reviewCycle: Int64
    let occurredAt: Date
    let title: String
    let portalURL: URL?
    let projectID: String?
    let reportID: String?
    let uploadID: String?
}

private enum AttributeValue: Encodable {
    case string(String)
    case integer(Int64)

    private enum CodingKeys: String, CodingKey { case type, string, integer }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode("string", forKey: .type)
            try container.encode(value, forKey: .string)
        case .integer(let value):
            try container.encode("integer", forKey: .type)
            try container.encode(value, forKey: .integer)
        }
    }
}

private struct InboxEvent: Encodable {
    let sourceInstallationID: UUID
    let externalID: String
    let revision: String
    let kind: String
    let occurredAt: Date
    let receivedAt: Date
    let title: String
    let attributes: [String: AttributeValue]
    let deepLink: URL?
    let resources: [Resource]

    struct Resource: Encodable {
        let kind: String
        let identifier: String
        let displayName: String
        let byteCount: Int64?
    }
}

private enum Locations {
    static let notification = Notification.Name("codes.threading.triggerd.inbox-changed")

    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Threading/Triggers", isDirectory: true)
    }

    static var configuration: URL? {
        directory?.appendingPathComponent("sources.json", isDirectory: false)
    }

    static var inbox: URL? {
        directory?.appendingPathComponent("Inbox", isDirectory: true)
    }

    static var cursorFile: URL? {
        directory?.appendingPathComponent("cursors.json", isDirectory: false)
    }

    static var statusDirectory: URL? {
        directory?.appendingPathComponent("Source Status", isDirectory: true)
    }
}

private struct SourceStatus: Encodable {
    let sourceInstallationID: UUID
    let health: String
    let lastCheckedAt: Date
    let lastEventAt: Date?
    let boundedDiagnostic: String?
}

private enum StatusWriter {
    static func write(_ status: SourceStatus) throws {
        guard let directory = Locations.statusDirectory else {
            throw DaemonFailure.noSupportDirectory
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent(
            "\(status.sourceInstallationID.uuidString.lowercased()).json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(status).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
    }
}

private actor CursorStore {
    private var values: [String: Int64] = [:]

    init() {
        guard let file = Locations.cursorFile,
              let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) else {
            return
        }
        values = decoded
    }

    func cursor(for sourceID: UUID) -> Int64 { values[sourceID.uuidString] ?? 0 }

    func commit(_ cursor: Int64, for sourceID: UUID) throws {
        guard let file = Locations.cursorFile else { throw DaemonFailure.noSupportDirectory }
        values[sourceID.uuidString] = cursor
        let data = try JSONEncoder().encode(values)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
    }
}

private enum DaemonFailure: LocalizedError {
    case noSupportDirectory
    case unsupportedConfiguration
    case missingCredential
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .noSupportDirectory: return "Application Support is unavailable."
        case .unsupportedConfiguration: return "The source configuration is unsupported."
        case .missingCredential: return "The source credential is unavailable."
        case .invalidResponse: return "The source returned an invalid response."
        case .server(let status): return "The source returned HTTP \(status)."
        }
    }

    var requiresAuthentication: Bool {
        switch self {
        case .missingCredential, .server(401), .server(403): return true
        default: return false
        }
    }
}

private enum CredentialReader {
    private static var accessGroup: String? {
        #if DEBUG
        nil
        #else
        "SMQ3E8Y57T.codes.threading.triggers"
        #endif
    }

    static func read(reference: String) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "codes.threading.trigger-source",
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { throw DaemonFailure.missingCredential }
        return value
    }
}

private enum ConfigurationReader {
    static func read() throws -> DaemonConfiguration {
        guard let file = Locations.configuration else { throw DaemonFailure.noSupportDirectory }
        let configuration = try JSONDecoder().decode(
            DaemonConfiguration.self,
            from: Data(contentsOf: file)
        )
        guard configuration.schemaVersion == 1 else {
            throw DaemonFailure.unsupportedConfiguration
        }
        return configuration
    }
}

private enum InboxWriter {
    static func write(_ event: InboxEvent, cursor: Int64) throws {
        guard let inbox = Locations.inbox else { throw DaemonFailure.noSupportDirectory }
        try FileManager.default.createDirectory(
            at: inbox,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = inbox.appendingPathComponent(
            String(format: "%020lld-%@.json", cursor, UUID().uuidString.lowercased()),
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(event).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
    }
}

private enum AppWake {
    static func notify() {
        DistributedNotificationCenter.default().postNotificationName(
            Locations.notification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "codes.threading"
        ).isEmpty else { return }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let app = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard app.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in
            DistributedNotificationCenter.default().postNotificationName(
                Locations.notification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }
}

private struct SourcePollResult: Sendable {
    let sourceID: UUID
    let succeeded: Bool
}

private actor SourceBackoff {
    private struct Hold {
        var delay: UInt64
        var retryAt: Date
    }

    private var holds: [UUID: Hold] = [:]

    func canPoll(_ sourceID: UUID, at now: Date = Date()) -> Bool {
        guard let hold = holds[sourceID] else { return true }
        return now >= hold.retryAt
    }

    func noteSuccess(_ sourceID: UUID) {
        holds.removeValue(forKey: sourceID)
    }

    func noteFailure(_ sourceID: UUID, at now: Date = Date()) {
        let delay = min((holds[sourceID]?.delay ?? 1) * 2, 300)
        holds[sourceID] = Hold(
            delay: delay,
            retryAt: now.addingTimeInterval(TimeInterval(delay))
        )
    }
}

private enum SondaSource {
    static func poll(_ source: SourceConfiguration, after cursor: Int64) async throws -> SondaFeed {
        guard source.enabled, source.sourceType == "sonda" else {
            throw DaemonFailure.unsupportedConfiguration
        }
        let credential = try CredentialReader.read(reference: source.credentialReference)
        var components = URLComponents(
            url: source.baseURL.appendingPathComponent(
                "api/automation/review-required-events",
                isDirectory: false
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "after", value: String(cursor)),
            URLQueryItem(name: "wait_seconds", value: "25"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        guard let url = components?.url else { throw DaemonFailure.unsupportedConfiguration }
        var request = URLRequest(url: url, timeoutInterval: 35)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DaemonFailure.invalidResponse }
        guard response.statusCode == 200 else { throw DaemonFailure.server(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC 3339 timestamp."
                )
            }
            return date
        }
        let feed = try decoder.decode(SondaFeed.self, from: data)
        var previousCursor = cursor
        for event in feed.events {
            guard event.cursor > previousCursor, event.cursor <= feed.nextCursor else {
                throw DaemonFailure.invalidResponse
            }
            previousCursor = event.cursor
        }
        guard feed.schemaVersion == 1,
              feed.nextCursor >= previousCursor,
              feed.events.count <= 100 else {
            throw DaemonFailure.invalidResponse
        }
        return feed
    }

    static func inboxEvent(_ event: SondaEvent, sourceID: UUID) -> InboxEvent {
        var attributes: [String: AttributeValue] = [
            "status": .string("needs_review"),
            "cursor": .integer(event.cursor),
            "review_cycle": .integer(event.reviewCycle),
        ]
        if let projectID = event.projectID { attributes["project_id"] = .string(projectID) }
        if let reportID = event.reportID { attributes["report_id"] = .string(reportID) }
        if let uploadID = event.uploadID { attributes["upload_id"] = .string(uploadID) }
        return InboxEvent(
            sourceInstallationID: sourceID,
            externalID: event.caseID,
            revision: String(event.reviewCycle),
            kind: "case.review-required",
            occurredAt: event.occurredAt,
            receivedAt: Date(),
            title: event.title,
            attributes: attributes,
            deepLink: event.portalURL,
            resources: []
        )
    }
}

@main
private enum TriggerDaemon {
    static func main() async {
        guard let directory = Locations.directory else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let cursors = CursorStore()
        let sourceBackoff = SourceBackoff()
        var failureDelay: UInt64 = 2

        while !Task.isCancelled {
            do {
                let configuration = try ConfigurationReader.read()
                let configuredSources = configuration.sources.filter(\.enabled)
                var sources: [SourceConfiguration] = []
                for source in configuredSources where await sourceBackoff.canPoll(source.id) {
                    sources.append(source)
                }
                if configuredSources.isEmpty {
                    try await Task.sleep(for: .seconds(30))
                    continue
                }
                if sources.isEmpty {
                    try await Task.sleep(for: .seconds(2))
                    continue
                }

                await withTaskGroup(of: SourcePollResult.self) { group in
                    for source in sources {
                        group.addTask {
                            do {
                                let cursor = await cursors.cursor(for: source.id)
                                let feed = try await SondaSource.poll(source, after: cursor)
                                for event in feed.events {
                                    try InboxWriter.write(
                                        SondaSource.inboxEvent(event, sourceID: source.id),
                                        cursor: event.cursor
                                    )
                                }
                                try await cursors.commit(feed.nextCursor, for: source.id)
                                try StatusWriter.write(SourceStatus(
                                    sourceInstallationID: source.id,
                                    health: "healthy",
                                    lastCheckedAt: Date(),
                                    lastEventAt: feed.events.last?.occurredAt,
                                    boundedDiagnostic: nil
                                ))
                                if !feed.events.isEmpty { AppWake.notify() }
                                return SourcePollResult(sourceID: source.id, succeeded: true)
                            } catch {
                                let health: String
                                if let failure = error as? DaemonFailure,
                                   failure.requiresAuthentication {
                                    health = "authenticationRequired"
                                } else {
                                    health = "backingOff"
                                }
                                try? StatusWriter.write(SourceStatus(
                                    sourceInstallationID: source.id,
                                    health: health,
                                    lastCheckedAt: Date(),
                                    lastEventAt: nil,
                                    boundedDiagnostic: String(
                                        error.localizedDescription.prefix(1_024)
                                    )
                                ))
                                NSLog(
                                    "threading-triggerd source %@: %@",
                                    source.id.uuidString,
                                    error.localizedDescription
                                )
                                return SourcePollResult(sourceID: source.id, succeeded: false)
                            }
                        }
                    }
                    for await result in group {
                        if result.succeeded {
                            await sourceBackoff.noteSuccess(result.sourceID)
                        } else {
                            await sourceBackoff.noteFailure(result.sourceID)
                        }
                    }
                }
                failureDelay = 2
            } catch {
                NSLog("threading-triggerd: %@", error.localizedDescription)
                try? await Task.sleep(for: .seconds(failureDelay))
                failureDelay = min(failureDelay * 2, 300)
            }
        }
    }
}
