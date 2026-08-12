import Foundation

/// The deliberately small wire contract accepted by Threading's public report intake.
///
/// This is separate from the paired-Mac remote protocol: a public report contains prose and may
/// contain an explicitly selected screenshot preview, while remote diagnostics are intentionally
/// content-free. Keeping the two contracts apart prevents a future refactor from accidentally
/// allowing report content through a long-lived device capability.
public struct PublicIssueReportSubmissionDTO: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let createdAt: String
    public let trigger: String
    public let description: String
    public let diagnostics: PublicIssueReportDiagnosticsDTO
    public let screenshotPreviewBase64: String?
    public let screenshotMediaType: String?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: String,
        createdAt: String,
        trigger: String,
        description: String,
        diagnostics: PublicIssueReportDiagnosticsDTO,
        screenshotPreviewBase64: String? = nil,
        screenshotMediaType: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.trigger = trigger
        self.description = description
        self.diagnostics = diagnostics
        self.screenshotPreviewBase64 = screenshotPreviewBase64
        self.screenshotMediaType = screenshotMediaType
    }
}

/// A bounded copy of a support report suitable for the private intake.
///
/// The ordinary support file may contain thousands of recent state transitions. Public intake
/// keeps the newest records that fit its budget so retries, stored objects, and reviewed agent
/// handoffs all have a predictable ceiling.
public struct PublicIssueReportDiagnosticsDTO: Codable, Equatable, Sendable {
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

    public init(bounding report: RemoteDiagnosticReport) {
        let maximumRecords = min(
            report.records.count,
            PublicIssueReportPolicy.maximumDiagnosticRecords
        )
        var kept = Array(report.records
            .filter { PublicIssueReportPolicy.recordIsShareSafe($0, reportSource: report.source) }
            .suffix(maximumRecords))
        var candidate = Self(copying: report, records: kept)

        while !kept.isEmpty,
              (try? JSONEncoder().encode(candidate).count) ?? .max
                > PublicIssueReportPolicy.maximumDiagnosticsBytes {
            kept.removeFirst(max(1, kept.count / 4))
            candidate = Self(copying: report, records: kept)
        }
        self = candidate
    }

    private init(copying report: RemoteDiagnosticReport, records: [RemoteDiagnosticRecord]) {
        schemaVersion = report.schemaVersion
        generatedAt = report.generatedAt
        source = report.source
        appVersion = report.appVersion
        appBuild = report.appBuild
        operatingSystem = report.operatingSystem
        protocolVersion = report.protocolVersion
        minimumProtocolVersion = report.minimumProtocolVersion
        additionalDetails = report.additionalDetails
        self.records = records
    }
}

public struct PublicIssueReportReceiptDTO: Codable, Equatable, Sendable {
    public let reportID: String
    public let reference: String
    public let wasAlreadyReceived: Bool

    public init(reportID: String, reference: String, wasAlreadyReceived: Bool) {
        self.reportID = reportID
        self.reference = reference
        self.wasAlreadyReceived = wasAlreadyReceived
    }
}

/// Shared request budgets. The hosted endpoint independently enforces the same values because its
/// input is untrusted; these client-side checks exist for deterministic UI and local-agent prompts.
public enum PublicIssueReportPolicy {
    public static let maximumRequestBytes = 64 * 1_024
    public static let maximumDescriptionBytes = 10 * 1_024
    public static let maximumDiagnosticsBytes = 24 * 1_024
    public static let maximumDiagnosticRecords = 250
    public static let maximumScreenshotPreviewBytes = 12 * 1_024

    public static func accepts(_ submission: PublicIssueReportSubmissionDTO) -> Bool {
        let allowedTriggers = Set(["shake", "diagnostics", "manual", "postCrash"])
        guard submission.schemaVersion == PublicIssueReportSubmissionDTO.currentSchemaVersion,
              UUID(uuidString: submission.id) != nil,
              submission.id == submission.id.lowercased(),
              ISO8601DateFormatter().date(from: submission.createdAt) != nil,
              allowedTriggers.contains(submission.trigger),
              !submission.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              submission.description.utf8.count <= maximumDescriptionBytes,
              submission.diagnostics.schemaVersion == RemoteDiagnosticReport.currentSchemaVersion,
              (submission.diagnostics.source == .iOSClient
                || submission.diagnostics.source == .macOSHost),
              submission.diagnostics.records.count <= maximumDiagnosticRecords,
              diagnosticsAreBounded(submission.diagnostics),
              screenshotIsBounded(submission) else {
            return false
        }
        return ((try? JSONEncoder().encode(submission).count) ?? .max) <= maximumRequestBytes
    }

    /// Decodes one durable outbox item through the same byte budget the endpoint accepts.
    public static func submission(at url: URL) -> PublicIssueReportSubmissionDTO? {
        guard let data = try? RemoteBoundedFileReader.read(
            url,
            maximumBytes: maximumRequestBytes
        ), let submission = try? JSONDecoder().decode(
            PublicIssueReportSubmissionDTO.self,
            from: data
        ), accepts(submission) else { return nil }
        return submission
    }

    private static func diagnosticsAreBounded(
        _ diagnostics: PublicIssueReportDiagnosticsDTO
    ) -> Bool {
        guard ((try? JSONEncoder().encode(diagnostics).count) ?? .max)
                <= maximumDiagnosticsBytes else {
            return false
        }
        let allowedFields = Set(RemoteDiagnosticField.allCases.map(\.rawValue))
        let allowedExtraFields = Set(RemoteDiagnosticExtraField.allCases.map(\.rawValue))
        guard diagnostics.additionalDetails?.allSatisfy({ key, value in
            allowedExtraFields.contains(key)
                && !value.isEmpty
                && value.utf8.count <= 160
                && !value.unicodeScalars.contains(where: {
                    $0.value < 0x20 || $0.value == 0x7f
                })
        }) ?? true else {
            return false
        }
        return diagnostics.records.allSatisfy {
            recordIsShareSafe($0, reportSource: diagnostics.source, allowedFields: allowedFields)
        }
    }

    /// A Mac support journal is a joined timeline and may contain records explicitly imported
    /// from its paired clients. A direct iOS report cannot claim records from another source.
    /// Invalid local records are omitted while constructing the DTO; this same predicate still
    /// makes `accepts` reject a crafted DTO at the public boundary.
    static func recordIsShareSafe(
        _ record: RemoteDiagnosticRecord,
        reportSource: RemoteDiagnosticSource,
        allowedFields: Set<String> = Set(RemoteDiagnosticField.allCases.map(\.rawValue))
    ) -> Bool {
        let sourceIsAllowed: Bool
        switch reportSource {
        case .macOSHost:
            sourceIsAllowed = record.source == .macOSHost
                || record.source == .iOSClient
                || record.source == .browserClient
        case .iOSClient:
            sourceIsAllowed = record.source == .iOSClient
        case .browserClient:
            sourceIsAllowed = false
        }
        return sourceIsAllowed
            && Set(record.fields.keys).isSubset(of: allowedFields)
            && record.timestamp.utf8.count <= 64
            && record.fields.values.allSatisfy {
                !$0.isEmpty
                    && $0.utf8.count <= 160
                    && $0.utf8.allSatisfy { byte in
                        (byte >= 48 && byte <= 57)
                            || (byte >= 65 && byte <= 90)
                            || (byte >= 97 && byte <= 122)
                            || byte == 45 || byte == 46 || byte == 58 || byte == 95
                    }
            }
    }

    private static func screenshotIsBounded(
        _ submission: PublicIssueReportSubmissionDTO
    ) -> Bool {
        switch (submission.screenshotPreviewBase64, submission.screenshotMediaType) {
        case (nil, nil):
            return true
        case (.some(let encoded), .some("image/jpeg")):
            guard let data = Data(base64Encoded: encoded) else { return false }
            return data.count >= 3
                && data.count <= maximumScreenshotPreviewBytes
                && data.starts(with: [0xff, 0xd8, 0xff])
        default:
            return false
        }
    }
}
