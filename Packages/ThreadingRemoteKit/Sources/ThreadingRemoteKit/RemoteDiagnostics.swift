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
    case diagnosticSharingStarted
    case diagnosticSharingStopped
    case diagnosticUploadReceived
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
public enum RemoteDiagnosticField: String, CaseIterable, Sendable {
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
    case recordCount
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

    // The Mac host's own facts. Every one of these is a count, an enum, or a version string —
    // never a name, path, or anything an agent produced. That is the same rule the rest of this
    // file follows, and it is the reason a support report can be handed to someone else without
    // reading it first.
    case accessibilityAuthorization
    case screenRecordingAuthorization
    case remoteAccessEnabled
    case appThemeID
    case projectCount
    case sessionCount
    case extensionCount
    case extensionCompanionCount
    case agentAccountSummary
    case previousLaunchClean
    case automaticUpdateChecks

    // What the app's own launch history says, beside `previousLaunchClean`, which only ever
    // describes the one launch before this one. These describe the run of them: the verdict, the
    // state of the ledger it was read from, and how far the last launch that died actually got.
    // Counts and enum tokens as everywhere else here — a checkpoint is a case name, and the
    // ledger's field says whether damage was moved aside rather than where it went.
    case crashLoopDecision
    case launchLedger
    case lastStartupCheckpoint

    // What Apple's own delayed diagnostics saw, as counts and a covered window rather than the
    // payloads. `metricKitLastCrash` is the exception type, signal, termination reason and app
    // version of the newest crash MetricKit reported — never a call tree, frame, or address.
    case metricKitDiagnostics
    case metricKitWindow
    case metricKitLastCrash
}

public struct RemoteDiagnosticRecord: Codable, Equatable, Sendable {
    public let timestamp: String
    public let source: RemoteDiagnosticSource
    public let level: RemoteDiagnosticLevel
    public let event: RemoteDiagnosticEvent
    public let fields: [String: String]

    public init(
        timestamp: String,
        source: RemoteDiagnosticSource,
        level: RemoteDiagnosticLevel,
        event: RemoteDiagnosticEvent,
        fields: [String: String]
    ) {
        self.timestamp = timestamp
        self.source = source
        self.level = level
        self.event = event
        self.fields = fields
    }
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

/// The only payload a remote client may add to the Mac's share-safe diagnostics journal.
///
/// It intentionally carries records rather than a log string. The receiver validates every
/// source, timestamp and allowlisted field before appending anything.
public struct RemoteDiagnosticUploadRequestDTO: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let source: RemoteDiagnosticSource
    public let records: [RemoteDiagnosticRecord]

    public init(
        schemaVersion: Int = RemoteDiagnosticReport.currentSchemaVersion,
        source: RemoteDiagnosticSource,
        records: [RemoteDiagnosticRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.records = records
    }
}

public struct RemoteDiagnosticUploadResponseDTO: Codable, Equatable, Sendable {
    public let acceptedRecords: Int

    public init(acceptedRecords: Int) {
        self.acceptedRecords = acceptedRecords
    }
}

/// Bounds for an explicitly enabled client-to-Mac diagnostic upload.
///
/// The ordinary HTTP request ceiling remains defence in depth. These smaller limits make the
/// diagnostics route auditable on its own and keep an authenticated but faulty client from
/// turning a support journal into bulk storage.
public enum RemoteDiagnosticUploadPolicy {
    public static let sharingDuration: TimeInterval = 30 * 60
    public static let maximumRecordsPerUpload = 250
    public static let maximumUploadBytes = 256 * 1024

    public static func accepts(
        _ request: RemoteDiagnosticUploadRequestDTO,
        now: Date = Date()
    ) -> Bool {
        guard request.schemaVersion == RemoteDiagnosticReport.currentSchemaVersion,
              request.source == .iOSClient || request.source == .browserClient,
              !request.records.isEmpty,
              request.records.count <= maximumRecordsPerUpload else {
            return false
        }

        let allowedFields = Set(RemoteDiagnosticField.allCases.map(\.rawValue))
        let oldest = now.addingTimeInterval(-(8 * 24 * 60 * 60))
        let newest = now.addingTimeInterval(5 * 60)
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        return request.records.allSatisfy { record in
            guard record.source == request.source,
                  source(request.source, allows: record.event),
                  record.timestamp.utf8.count <= 64,
                  let timestamp = timestampFormatter.date(from: record.timestamp)
                    ?? fallbackFormatter.date(from: record.timestamp),
                  timestamp >= oldest, timestamp <= newest,
                  Set(record.fields.keys).isSubset(of: allowedFields) else {
                return false
            }
            return record.fields.allSatisfy { key, value in
                allowedFieldValue(value, for: key)
            }
        }
    }

    /// Imported values are machine tokens, never prose. Constraining the alphabet at the trust
    /// boundary prevents a compromised or buggy client from putting a prompt, path, URL or
    /// terminal line under an otherwise legitimate field name.
    private static func allowedFieldValue(_ value: String, for key: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 160,
              value.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || byte == 45 || byte == 46 || byte == 58 || byte == 95
              }) else {
            return false
        }

        switch RemoteDiagnosticField(rawValue: key) {
        case .enabledKindCount, .recordCount, .protocolVersion, .minimumProtocolVersion:
            return value.allSatisfy(\.isNumber)
        case .peer:
            return value.hasPrefix("peer-") || value.hasPrefix("device-")
        case .session:
            return value.hasPrefix("session-")
        case .none:
            return false
        default:
            return true
        }
    }

    private static func source(
        _ source: RemoteDiagnosticSource,
        allows event: RemoteDiagnosticEvent
    ) -> Bool {
        switch source {
        case .macOSHost:
            return false
        case .browserClient:
            switch event {
            case .appLaunched,
                 .hostPairingStarted, .hostPairingSucceeded, .hostPairingFailed,
                 .hostRefreshSucceeded, .hostRefreshFailed,
                 .socketConnecting, .socketConnected, .socketEnded, .socketFailed,
                 .diagnosticSharingStarted, .diagnosticSharingStopped:
                return true
            default:
                return false
            }
        case .iOSClient:
            switch event {
            case .appLaunched, .appBecameActive,
                 .hostPairingStarted, .hostPairingSucceeded, .hostPairingFailed, .hostRemoved,
                 .hostRefreshSucceeded, .hostRefreshFailed,
                 .socketConnecting, .socketConnected, .socketEnded, .socketFailed,
                 .permissionDecisionSent,
                 .notificationAuthorization,
                 .apnsRegistrationSucceeded, .apnsRegistrationFailed,
                 .notificationRegistrationStarted, .notificationRegistrationSucceeded,
                 .notificationRegistrationFailed,
                 .notificationReceived, .notificationSuppressed, .notificationPresented,
                 .notificationOpened,
                 .issueReportOpened, .issueReportExported,
                 .diagnosticSharingStarted, .diagnosticSharingStopped:
                return true
            default:
                return false
            }
        }
    }
}

/// A small synchronous journal for post-mortem support reports.
///
/// Remote lifecycle produces a few records per state transition, not per terminal byte. A
/// synchronous append therefore buys crash resilience without becoming a hot-path cost.
public final class RemoteDiagnosticJournal: @unchecked Sendable {
    static let maximumJournalReadBytes = 8 * 1_024 * 1_024
    static let maximumRecordBytes = 64 * 1_024
    static let maximumJournalDirectoryEntries = 256
    public static let maximumSupportReportBytes = 64 * 1_024 * 1_024

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

    private lazy var fallbackTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
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
        precondition(retention >= 0)
        precondition(maximumReportRecords >= 0)
        self.directory = directory
        self.source = source
        self.retention = retention
        self.maximumReportRecords = maximumReportRecords
    }

    @discardableResult
    public func record(
        _ event: RemoteDiagnosticEvent,
        level: RemoteDiagnosticLevel = .info,
        fields: [RemoteDiagnosticField: String] = [:]
    ) -> RemoteDiagnosticRecord {
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
            return record
        }
    }

    /// Adds already-sanitized records from a remote client while preserving its timestamps.
    ///
    /// Imported events share the Mac report's file so the report is already a joined timeline.
    /// Validation is repeated here even when the HTTP boundary checked first; this public method
    /// must remain safe if another transport uses it later.
    @discardableResult
    public func importRecords(
        _ records: [RemoteDiagnosticRecord],
        from source: RemoteDiagnosticSource,
        now: Date = Date()
    ) -> Bool {
        let request = RemoteDiagnosticUploadRequestDTO(source: source, records: records)
        guard RemoteDiagnosticUploadPolicy.accepts(request, now: now) else { return false }

        queue.sync {
            if !didPrune {
                pruneExpiredJournals()
                didPrune = true
            }
            for record in records {
                append(record)
            }
        }
        return true
    }

    public func records() -> [RemoteDiagnosticRecord] {
        queue.sync {
            if !didPrune {
                pruneExpiredJournals()
                didPrune = true
            }
            let urls = journalURLs()
            let decoded = urls.flatMap { url -> [RemoteDiagnosticRecord] in
                guard let data = Self.boundedJournalSuffix(at: url) else { return [] }
                return data.split(separator: 0x0A).compactMap {
                    guard $0.count <= Self.maximumRecordBytes else { return nil }
                    return try? JSONDecoder().decode(
                        RemoteDiagnosticRecord.self,
                        from: Data($0)
                    )
                }
            }
            let ordered = decoded.enumerated().sorted { lhs, rhs in
                let lhsDate = timestampFormatter.date(from: lhs.element.timestamp)
                    ?? fallbackTimestampFormatter.date(from: lhs.element.timestamp)
                let rhsDate = timestampFormatter.date(from: rhs.element.timestamp)
                    ?? fallbackTimestampFormatter.date(from: rhs.element.timestamp)
                if lhsDate == rhsDate { return lhs.offset < rhs.offset }
                return (lhsDate ?? .distantPast) < (rhsDate ?? .distantPast)
            }.map(\.element)
            return Array(ordered.suffix(maximumReportRecords))
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
        guard data.count <= Self.maximumSupportReportBytes else {
            throw RemoteDiagnosticJournalError.reportTooLarge
        }
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

    public static func readSupportReport(at url: URL) throws -> RemoteDiagnosticReport {
        let data = try RemoteBoundedFileReader.read(
            url,
            maximumBytes: maximumSupportReportBytes
        )
        return try JSONDecoder().decode(RemoteDiagnosticReport.self, from: data)
    }

    private func append(_ record: RemoteDiagnosticRecord) {
        guard let data = try? JSONEncoder().encode(record),
              data.count <= Self.maximumRecordBytes,
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
        guard let urls = try? RemoteBoundedDirectoryReader.shallowContents(
            of: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            maximumEntries: Self.maximumJournalDirectoryEntries
        ) else { return [] }
        return urls
            .filter {
                let values = try? $0.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true else { return false }
                let name = $0.deletingPathExtension().lastPathComponent
                let prefix = "remote-diagnostics-"
                guard $0.pathExtension == "jsonl", name.hasPrefix(prefix) else { return false }
                let day = name.dropFirst(prefix.count)
                guard day.utf8.count == 10 else { return false }
                return day.enumerated().allSatisfy { offset, character in
                    (offset == 4 || offset == 7) ? character == "-" : character.isNumber
                }
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func journalURL(day: String) -> URL {
        directory.appendingPathComponent("remote-diagnostics-\(day).jsonl")
    }

    /// Reads only the newest bounded suffix. Reports retain their newest records, so walking a
    /// multi-day journal from byte zero did unbounded work for data the final `suffix` discarded
    /// anyway. If the read begins mid-record, that fragment is dropped before JSON decoding.
    private static func boundedJournalSuffix(at url: URL) -> Data? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            let end = try handle.seekToEnd()
            let allowance = UInt64(maximumJournalReadBytes)
            let start = end > allowance ? end - allowance : 0
            try handle.seek(toOffset: start)
            guard var data = try handle.read(upToCount: maximumJournalReadBytes) else {
                return nil
            }
            if start > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
                data.removeSubrange(data.startIndex...newline)
            }
            return data
        } catch {
            return nil
        }
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

public enum RemoteDiagnosticJournalError: LocalizedError {
    case reportTooLarge

    public var errorDescription: String? {
        switch self {
        case .reportTooLarge:
            return "The remote diagnostics report is too large to export safely."
        }
    }
}

/// The package-local allocation boundary shared by remote persistence APIs.
enum RemoteBoundedFileReader {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        precondition(maximumBytes >= 0 && maximumBytes < Int.max)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        return data
    }
}

/// A shallow, allocation-bounded alternative to `FileManager.contentsOfDirectory` for support
/// directories whose contents can outlive or be modified independently of the current process.
///
/// The limit applies to every visible entry, not only the entries a caller later recognizes. A
/// directory filled with malformed names must therefore fail closed instead of making validation
/// itself unbounded or hiding valid entries beyond an attacker-controlled prefix.
public enum RemoteBoundedDirectoryReader {
    public static func shallowContents(
        of directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey] = [],
        maximumEntries: Int
    ) throws -> [URL] {
        precondition(maximumEntries >= 0 && maximumEntries < Int.max)

        var enumerationError: Swift.Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw enumerationError ?? CocoaError(.fileReadNoSuchFile)
        }

        var urls: [URL] = []
        urls.reserveCapacity(min(maximumEntries, 64))
        while let entry = enumerator.nextObject() {
            guard let url = entry as? URL else { continue }
            guard urls.count < maximumEntries else {
                throw RemoteDirectoryEnumerationError.entryLimitExceeded(
                    maximumEntries: maximumEntries
                )
            }
            urls.append(url)
        }
        if let enumerationError { throw enumerationError }
        return urls
    }
}

public enum RemoteDirectoryEnumerationError: Error, Equatable, Sendable {
    case entryLimitExceeded(maximumEntries: Int)
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
