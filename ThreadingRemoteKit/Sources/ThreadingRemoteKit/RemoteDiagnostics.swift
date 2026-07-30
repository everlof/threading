import Foundation

/// A deliberately content-free diagnostic vocabulary shared by the Mac and its clients.
///
/// Events describe transport state, never what a person or agent wrote. Field names are an
/// allowlist so a convenient `[String: Any]` cannot quietly turn a support report into a copy of
/// prompts, paths, notification text, bearer tokens, or invitation URLs.
public enum RemoteDiagnosticEvent: String, Codable, Sendable {
    case appLaunched
    case appBecameActive
    case hostPairingStarted
    case hostPairingSucceeded
    case hostPairingFailed
    case hostRemoved
    case hostRefreshSucceeded
    case hostRefreshFailed
    case hostListenerStarted
    case hostListenerFailed
    case relayConnected
    case relayFailed
    case authenticationRefused
    case socketConnecting
    case socketConnected
    case socketEnded
    case socketFailed
    case permissionDecisionSent
    case permissionDecisionReceived
    case notificationAuthorization
    case apnsRegistrationSucceeded
    case apnsRegistrationFailed
    case notificationRegistrationStarted
    case notificationRegistrationSucceeded
    case notificationRegistrationFailed
    case notificationRegistrationReceived
    case notificationReceived
    case notificationSuppressed
    case notificationPresented
    case notificationOpened
    case pushProviderAccepted
    case pushProviderRefused
    case issueReportOpened
    case issueReportExported
}

public enum RemoteDiagnosticLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

public enum RemoteDiagnosticSource: String, Codable, Sendable {
    case macOSHost
    case iOSClient
    case browserClient
}

/// Safe structural facts. Values are still bounded and stripped of controls by the journal.
///
/// `trace` is an opaque event/request identifier minted for correlation, never an auth token.
/// `peer` and `session` must be locally pseudonymised before they are passed here.
public enum RemoteDiagnosticField: String, Sendable {
    case trace
    case providerTrace
    case peer
    case session
    case kind
    case transport
    case result
    case code
    case status
    case environment
    case protocolVersion
    case minimumProtocolVersion
    case capability
    case surface
    case enabledKindCount
    case reason
}

/// Optional device/app context that a reporter explicitly consents to include.
///
/// This is a second allowlist rather than a free-form dictionary so the opt-in cannot quietly
/// grow into device names, stable identifiers, request URLs, or conversation state.
public enum RemoteDiagnosticExtraField: String, Sendable {
    case deviceModel
    case interfaceIdiom
    case locale
    case preferredLanguage
    case timeZone
    case lowPowerMode
    case thermalState
    case physicalMemoryMB
    case availableStorageMB
    case displayPoints
    case displayScale
    case applicationState
    case connectionState
    case pairedHostCount
    case visibleSessionCount
    case activeScope
    case activeCapability
    case notificationAuthorization
    case notificationDelivery
}

public struct RemoteDiagnosticRecord: Codable, Equatable, Sendable {
    public let timestamp: String
    public let source: RemoteDiagnosticSource
    public let level: RemoteDiagnosticLevel
    public let event: RemoteDiagnosticEvent
    public let fields: [String: String]
}

public struct RemoteDiagnosticReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: String
    public let source: RemoteDiagnosticSource
    public let appVersion: String
    public let appBuild: String
    public let operatingSystem: String
    public let protocolVersion: Int
    public let minimumProtocolVersion: Int
    public let additionalDetails: [String: String]?
    public let records: [RemoteDiagnosticRecord]
}

/// A small synchronous journal for post-mortem support reports.
///
/// Remote lifecycle produces a few records per state transition, not per terminal byte. A
/// synchronous append therefore buys crash resilience without becoming a hot-path cost.
public final class RemoteDiagnosticJournal: @unchecked Sendable {
    public let directory: URL
    public let source: RemoteDiagnosticSource

    private let retention: TimeInterval
    private let maximumReportRecords: Int
    private let queue = DispatchQueue(label: "codes.threading.remote-diagnostics")
    private var openDay: String?
    private var openHandle: FileHandle?
    private var didPrune = false

    private lazy var timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private lazy var dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public init(
        directory: URL,
        source: RemoteDiagnosticSource,
        retention: TimeInterval = 7 * 24 * 60 * 60,
        maximumReportRecords: Int = 5_000
    ) {
        self.directory = directory
        self.source = source
        self.retention = retention
        self.maximumReportRecords = maximumReportRecords
    }

    public func record(
        _ event: RemoteDiagnosticEvent,
        level: RemoteDiagnosticLevel = .info,
        fields: [RemoteDiagnosticField: String] = [:]
    ) {
        queue.sync {
            if !didPrune {
                pruneExpiredJournals()
                didPrune = true
            }
            let record = RemoteDiagnosticRecord(
                timestamp: timestampFormatter.string(from: Date()),
                source: source,
                level: level,
                event: event,
                fields: Dictionary(uniqueKeysWithValues: fields.map {
                    ($0.key.rawValue, Self.safeValue($0.value))
                })
            )
            append(record)
        }
    }

    public func records() -> [RemoteDiagnosticRecord] {
        queue.sync {
            let urls = journalURLs()
            let decoded = urls.flatMap { url -> [RemoteDiagnosticRecord] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return data.split(separator: 0x0A).compactMap {
                    try? JSONDecoder().decode(RemoteDiagnosticRecord.self, from: Data($0))
                }
            }
            return Array(decoded.suffix(maximumReportRecords))
        }
    }

    @discardableResult
    public func writeSupportReport(
        appVersion: String,
        appBuild: String,
        operatingSystem: String,
        protocolVersion: Int,
        minimumProtocolVersion: Int,
        additionalDetails: [RemoteDiagnosticExtraField: String] = [:],
        to outputDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let report = RemoteDiagnosticReport(
            schemaVersion: RemoteDiagnosticReport.currentSchemaVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            source: source,
            appVersion: Self.safeValue(appVersion),
            appBuild: Self.safeValue(appBuild),
            operatingSystem: Self.safeValue(operatingSystem),
            protocolVersion: protocolVersion,
            minimumProtocolVersion: minimumProtocolVersion,
            additionalDetails: additionalDetails.isEmpty
                ? nil
                : Dictionary(uniqueKeysWithValues: additionalDetails.map {
                    ($0.key.rawValue, Self.safeValue($0.value))
                }),
            records: records()
        )
        let data = try JSONEncoder.pretty.encode(report)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let url = outputDirectory.appendingPathComponent(
            "threading-support-\(source.rawValue)-\(UUID().uuidString.lowercased()).json"
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    private func append(_ record: RemoteDiagnosticRecord) {
        guard let data = try? JSONEncoder().encode(record),
              let handle = handle(forDay: dayFormatter.string(from: Date())) else {
            return
        }
        do {
            try handle.write(contentsOf: data + Data([0x0A]))
        } catch {
            // Diagnostics must never become a reason for the app itself to fail.
        }
    }

    private func handle(forDay day: String) -> FileHandle? {
        if openDay == day, let openHandle { return openHandle }
        try? openHandle?.close()
        openHandle = nil
        openDay = nil

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = journalURL(day: day)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        openDay = day
        openHandle = handle
        return handle
    }

    private func pruneExpiredJournals() {
        let cutoff = Date().addingTimeInterval(-retention)
        for url in journalURLs() {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < cutoff else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func journalURLs() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls
            .filter {
                $0.lastPathComponent.hasPrefix("remote-diagnostics-")
                    && $0.pathExtension == "jsonl"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func journalURL(day: String) -> URL {
        directory.appendingPathComponent("remote-diagnostics-\(day).jsonl")
    }

    private static func safeValue(_ value: String) -> String {
        let oneLine = value.unicodeScalars.compactMap { scalar -> String? in
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return String(scalar)
        }.joined()

        guard oneLine.utf8.count > 160 else { return oneLine }
        var prefix = oneLine.utf8.prefix(157)
        while String(bytes: prefix, encoding: .utf8) == nil, !prefix.isEmpty {
            prefix = prefix.dropLast()
        }
        return String(decoding: prefix, as: UTF8.self) + "…"
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
