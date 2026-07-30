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
}
