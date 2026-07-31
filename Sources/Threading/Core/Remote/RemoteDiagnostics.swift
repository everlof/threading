import CryptoKit
import Foundation
import ThreadingRemoteKit

/// The Mac half of the privacy-bounded remote diagnostics contract.
///
/// This journal deliberately stays separate from `EventLog`: the latter is an owner-local
/// post-mortem and has historically recorded commands, prompts and paths. A file intended to
/// leave the machine must be safe by construction rather than depend on a best-effort scrub.
enum MacRemoteDiagnostics {
    static let journal = RemoteDiagnosticJournal(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent("Diagnostics", isDirectory: true),
        source: .macOSHost
    )

    static func record(
        _ event: RemoteDiagnosticEvent,
        level: RemoteDiagnosticLevel = .info,
        fields: [RemoteDiagnosticField: String] = [:]
    ) {
        journal.record(event, level: level, fields: fields)
    }

    /// Stable enough to join events inside one report without exposing the underlying id.
    static func pseudonym(_ value: String, prefix: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let short = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(short)"
    }

    static func supportReport(
        additionalDetails: [RemoteDiagnosticExtraField: String] = [:]
    ) throws -> URL {
        let info = Bundle.main.infoDictionary
        return try journal.writeSupportReport(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info?["CFBundleVersion"] as? String ?? "?",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            protocolVersion: RemoteProtocol.current,
            minimumProtocolVersion: RemoteProtocol.minimumSupported,
            additionalDetails: additionalDetails
        )
    }

    /// Imports one explicitly shared client batch into the Mac's already share-safe journal.
    ///
    /// The authenticated device id replaces any client-supplied peer value. That both prevents
    /// spoofed grouping and makes the imported half join the Mac events that already pseudonymise
    /// this same remote device.
    static func receive(
        _ records: [RemoteDiagnosticRecord],
        source: RemoteDiagnosticSource,
        deviceID: String
    ) -> Bool {
        let peer = pseudonym(deviceID, prefix: "device")
        let attributed = records.map { record in
            var fields = record.fields
            fields[RemoteDiagnosticField.peer.rawValue] = peer
            return RemoteDiagnosticRecord(
                timestamp: record.timestamp,
                source: record.source,
                level: record.level,
                event: record.event,
                fields: fields
            )
        }
        guard journal.importRecords(attributed, from: source) else {
            return false
        }
        record(.diagnosticUploadReceived, fields: [
            .peer: peer,
            .surface: source.rawValue,
            .recordCount: String(records.count),
        ])
        return true
    }
}
