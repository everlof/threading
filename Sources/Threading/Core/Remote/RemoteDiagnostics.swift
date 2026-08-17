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
        source: .macOSHost,
        storageEventHandler: { event in
            reportMacRemoteDiagnosticStorageEvent(event)
        }
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

    /// The address this Mac advertised, as a value a report can carry.
    ///
    /// `Remote access started {port}` recorded the loopback port and nothing about the public
    /// origin, so a report could not say whether a phone had been given the address it was
    /// failing against. The origin itself is a routable location of someone's machine and never
    /// belongs in a file meant to leave it, so only its scheme, host and port are hashed. Two
    /// events naming the same origin therefore match, and neither one names it.
    static func originDigest(_ origin: URL) -> String {
        pseudonym(RemoteOriginIdentity.canonical(origin), prefix: "origin")
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

    static func report(
        additionalDetails: [RemoteDiagnosticExtraField: String] = [:]
    ) -> RemoteDiagnosticReport {
        let info = Bundle.main.infoDictionary
        return journal.supportReport(
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

private func reportMacRemoteDiagnosticStorageEvent(
    _ event: RemoteDiagnosticJournalStorageEvent
) {
    if event.outcome == .recovered {
        ThreadingLogger.remote.notice(
            "Share-safe diagnostic journal storage recovered stage=\(event.stage.rawValue, privacy: .public)"
        )
        return
    }

    switch event.stage {
    case .encoding:
        ThreadingLogger.remote.fault(
            "Share-safe diagnostic journal storage failed stage=\(event.stage.rawValue, privacy: .public) domain=\(event.errorDomain.rawValue, privacy: .public) code=\(event.errorCode, privacy: .public) affected=\(event.affectedCount, privacy: .public)"
        )
    case .directory, .fileCreation, .fileOpen, .seek, .write, .read:
        ThreadingLogger.remote.error(
            "Share-safe diagnostic journal storage failed stage=\(event.stage.rawValue, privacy: .public) domain=\(event.errorDomain.rawValue, privacy: .public) code=\(event.errorCode, privacy: .public) affected=\(event.affectedCount, privacy: .public)"
        )
    case .recordTooLarge, .close, .enumerate, .metadata, .decode, .retention:
        ThreadingLogger.remote.warning(
            "Share-safe diagnostic journal storage failed stage=\(event.stage.rawValue, privacy: .public) domain=\(event.errorDomain.rawValue, privacy: .public) code=\(event.errorCode, privacy: .public) affected=\(event.affectedCount, privacy: .public)"
        )
    }
}

/// The part of an address two diagnostic events must agree on to be talking about one origin.
///
/// Paths, queries and fragments are excluded deliberately: a fragment is where a pairing bearer
/// lives, and a hash of a URL that includes one would still be a hash *of a credential*.
enum RemoteOriginIdentity {
    static func canonical(_ origin: URL) -> String {
        let scheme = origin.scheme?.lowercased() ?? "none"
        let host = origin.host?.lowercased() ?? "none"
        let port = origin.port.map(String.init) ?? "default"
        return "\(scheme)://\(host):\(port)"
    }
}
