import CryptoKit
import OSLog
import ThreadingRemoteKit
import SwiftUI
import UIKit
import UserNotifications

private let mobileDiagnosticLogger = Logger(
    subsystem: "codes.threading.mobile",
    category: "diagnostics"
)

/// Fixed operation names for the local unified-log fallback.
///
/// The enum prevents a caller from accidentally putting a URL, host name, session title, or
/// other user-controlled value in a public log field. Error values are reduced to the same
/// structural codes used by the share-safe journal.
enum MobileDiagnosticSurface: String {
    case attachmentList = "attachment_list"
    case attachmentMetadata = "attachment_metadata"
    case attachmentContent = "attachment_content"
    case browserTabs = "browser_tabs"
    case browserPreview = "browser_preview"
    case continuityStorage = "continuity_storage"
    case extensionPanelLoad = "extension_panel_load"
    case extensionPanelAction = "extension_panel_action"
    case gitReview = "git_review"
    case gitRepositoryFiles = "git_repository_files"
    case gitRepositoryFile = "git_repository_file"
    case hostStorage = "host_storage"
    case hostTrust = "host_trust"
    case issueReportDelivery = "issue_report_delivery"
    case issueReportExport = "issue_report_export"
    case keyboardStorage = "keyboard_storage"
    case newSessionDefaultsStorage = "new_session_defaults_storage"
    case sessionAction = "session_action"
    case sessionRefusal = "session_refusal"
    case themeSelection = "theme_selection"
}

enum MobileDiagnosticFailureCode: String {
    case decode = "decode"
    case encode = "encode"
    case newerFormat = "newer_format"
    case validation = "validation"
    case writeVerification = "write_verification"
    /// An owner response named an identity that is neither the pinned one nor its announced
    /// successor; the stored pin was kept.
    case pinChangeRefused = "pin_change_refused"
}

enum MobileDiagnosticErrorDomain: String {
    case keychain
}

enum MobileDiagnostics {
    private static let nanosecondsPerMillisecond: UInt64 = 1_000_000
    private static let millisecondsPerSecond: Int64 = 1_000
    private static let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000

    static let journal = RemoteDiagnosticJournal(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true),
        source: .iOSClient,
        storageEventHandler: { event in
            reportMobileDiagnosticStorageEvent(event)
        }
    )
    @MainActor static let sharing = MobileDiagnosticSharingController()

    static func record(
        _ event: RemoteDiagnosticEvent,
        level: RemoteDiagnosticLevel = .info,
        fields: [RemoteDiagnosticField: String] = [:]
    ) {
        let record = journal.record(event, level: level, fields: fields)
        Task { @MainActor in
            sharing.enqueue(record)
            if level == .error {
                MobileDiagnosticsIncidentRecorder.shared.captureIfNeeded()
            }
        }
    }

    /// One opaque id for a complete connectivity operation. It is deliberately unrelated to a
    /// request id, bearer, peer id, or URL and is therefore safe to carry through support logs.
    static func connectivityTrace() -> String {
        UUID().uuidString.lowercased()
    }

    static func monotonicNow() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since startedAt: UInt64) -> String {
        let now = monotonicNow()
        return String(now >= startedAt ? (now - startedAt) / nanosecondsPerMillisecond : 0)
    }

    static func milliseconds(_ interval: TimeInterval) -> String {
        String(max(Int64((interval * 1_000).rounded()), 0))
    }

    static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = components.seconds * millisecondsPerSecond
            + components.attoseconds / attosecondsPerMillisecond
        return String(max(value, 0))
    }

    /// Connectivity records go to both the bounded, share-safe journal and unified logging.
    /// The latter intentionally repeats only the structural allowlist values: no host names,
    /// URLs, error descriptions, invitation data, or user content can reach the public log.
    static func recordConnectivity(
        _ event: RemoteDiagnosticEvent,
        level: RemoteDiagnosticLevel = .info,
        fields: [RemoteDiagnosticField: String]
    ) {
        record(event, level: level, fields: fields)
        let trace = machineToken(fields[.trace] ?? "none")
        let peerToken = machineToken(fields[.peer] ?? "none")
        let peer = isPseudonym(peerToken, prefixes: ["peer-", "device-"])
            ? peerToken : "none"
        let originToken = machineToken(fields[.origin] ?? "none")
        let origin = isPseudonym(originToken, prefixes: ["origin-"])
            ? originToken : "none"
        let phase = machineToken(fields[.phase] ?? "none")
        let transport = machineToken(fields[.transport] ?? "none")
        let surface = machineToken(fields[.surface] ?? "none")
        let result = machineToken(fields[.result] ?? "none")
        let code = machineToken(fields[.code] ?? "none")
        let status = machineToken(fields[.status] ?? "none")
        let duration = machineToken(fields[.durationMS] ?? "none")
        let timeout = machineToken(fields[.timeoutMS] ?? "none")
        let delay = machineToken(fields[.delayMS] ?? "none")
        let networkStage = machineToken(fields[.networkStage] ?? "none")
        let dns = machineToken(fields[.dnsMS] ?? "none")
        let tcp = machineToken(fields[.tcpMS] ?? "none")
        let tls = machineToken(fields[.tlsMS] ?? "none")
        let serverWait = machineToken(fields[.serverWaitMS] ?? "none")
        // Named for its unit, not shortened to `response`: this is a duration, and the logging
        // lint reads a bare `response` as message content and refuses to let it be public.
        let responseMs = machineToken(fields[.responseMS] ?? "none")
        let networkProtocol = machineToken(fields[.networkProtocol] ?? "none")
        let networkPath = machineToken(fields[.networkPath] ?? "none")
        let connectionReused = machineToken(fields[.connectionReused] ?? "none")
        let attempt = machineToken(fields[.attempt] ?? "none")
        let total = machineToken(fields[.total] ?? "none")
        switch level {
        case .info:
            mobileDiagnosticLogger.info(
                "Connectivity event=\(event.rawValue, privacy: .public) trace=\(trace, privacy: .public) peer=\(peer, privacy: .public) origin=\(origin, privacy: .public) phase=\(phase, privacy: .public) transport=\(transport, privacy: .public) surface=\(surface, privacy: .public) result=\(result, privacy: .public) code=\(code, privacy: .public) status=\(status, privacy: .public) duration_ms=\(duration, privacy: .public) timeout_ms=\(timeout, privacy: .public) delay_ms=\(delay, privacy: .public) network_stage=\(networkStage, privacy: .public) dns_ms=\(dns, privacy: .public) tcp_ms=\(tcp, privacy: .public) tls_ms=\(tls, privacy: .public) server_wait_ms=\(serverWait, privacy: .public) response_ms=\(responseMs, privacy: .public) network_protocol=\(networkProtocol, privacy: .public) network_path=\(networkPath, privacy: .public) connection_reused=\(connectionReused, privacy: .public) attempt=\(attempt, privacy: .public) total=\(total, privacy: .public)"
            )
        case .warning:
            mobileDiagnosticLogger.warning(
                "Connectivity event=\(event.rawValue, privacy: .public) trace=\(trace, privacy: .public) peer=\(peer, privacy: .public) origin=\(origin, privacy: .public) phase=\(phase, privacy: .public) transport=\(transport, privacy: .public) surface=\(surface, privacy: .public) result=\(result, privacy: .public) code=\(code, privacy: .public) status=\(status, privacy: .public) duration_ms=\(duration, privacy: .public) timeout_ms=\(timeout, privacy: .public) delay_ms=\(delay, privacy: .public) network_stage=\(networkStage, privacy: .public) dns_ms=\(dns, privacy: .public) tcp_ms=\(tcp, privacy: .public) tls_ms=\(tls, privacy: .public) server_wait_ms=\(serverWait, privacy: .public) response_ms=\(responseMs, privacy: .public) network_protocol=\(networkProtocol, privacy: .public) network_path=\(networkPath, privacy: .public) connection_reused=\(connectionReused, privacy: .public) attempt=\(attempt, privacy: .public) total=\(total, privacy: .public)"
            )
        case .error:
            mobileDiagnosticLogger.error(
                "Connectivity event=\(event.rawValue, privacy: .public) trace=\(trace, privacy: .public) peer=\(peer, privacy: .public) origin=\(origin, privacy: .public) phase=\(phase, privacy: .public) transport=\(transport, privacy: .public) surface=\(surface, privacy: .public) result=\(result, privacy: .public) code=\(code, privacy: .public) status=\(status, privacy: .public) duration_ms=\(duration, privacy: .public) timeout_ms=\(timeout, privacy: .public) delay_ms=\(delay, privacy: .public) network_stage=\(networkStage, privacy: .public) dns_ms=\(dns, privacy: .public) tcp_ms=\(tcp, privacy: .public) tls_ms=\(tls, privacy: .public) server_wait_ms=\(serverWait, privacy: .public) response_ms=\(responseMs, privacy: .public) network_protocol=\(networkProtocol, privacy: .public) network_path=\(networkPath, privacy: .public) connection_reused=\(connectionReused, privacy: .public) attempt=\(attempt, privacy: .public) total=\(total, privacy: .public)"
            )
        }
    }

    /// Stable inside support reports without exposing the original host, session, or device id.
    static func pseudonym(_ value: String, prefix: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let short = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(short)"
    }

    private static func isPseudonym(_ value: String, prefixes: [String]) -> Bool {
        guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else { return false }
        let digest = value.utf8.dropFirst(prefix.utf8.count)
        return digest.count == 12 && digest.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    /// The address this phone aimed at, as a value a report can carry.
    ///
    /// Two events naming the same origin match; neither one names it. A URL's fragment is where
    /// a pairing bearer lives, so only scheme, host and port are hashed. The Mac derives the
    /// same value for the origin it advertised, which is what lets a joined report say whether
    /// the phone was even pointed at the right place.
    static func originDigest(_ origin: URL) -> String {
        let scheme = origin.scheme?.lowercased() ?? "none"
        let host = origin.host?.lowercased() ?? "none"
        let port = origin.port.map(String.init) ?? "default"
        return pseudonym("\(scheme)://\(host):\(port)", prefix: "origin")
    }

    /// Error descriptions can contain a full request URL, whose fragment is a bearer. Reports
    /// therefore store only a bounded, structural code.
    static func errorCode(_ error: Error) -> String {
        if let remote = error as? RemoteClientError {
            switch remote {
            case .invalidResponse: return "remote.invalidResponse"
            case .unauthorized: return "remote.unauthorized"
            case .upgradeRequired: return "remote.upgradeRequired"
            case .server(let status, let code, _):
                guard let code else { return "remote.http.\(status)" }
                return "remote.refusal.\(machineToken(code))"
            }
        }
        if let url = error as? URLError {
            return "url.\(url.code.rawValue)"
        }
        let cocoa = error as NSError
        if cocoa.domain == NSPOSIXErrorDomain {
            return "posix.\(cocoa.code)"
        }
        if cocoa.domain == NSCocoaErrorDomain {
            return "cocoa.\(cocoa.code)"
        }
        return "other.\(cocoa.code)"
    }

    /// Records an operation that failed at its user-visible boundary without logging the
    /// localized error text. Foundation error descriptions frequently contain request URLs,
    /// file paths, host names, or credential-bearing fragments.
    static func logFailure(_ surface: MobileDiagnosticSurface, error: Error) {
        mobileDiagnosticLogger.error(
            "Mobile operation failed surface=\(surface.rawValue, privacy: .public) code=\(errorCode(error), privacy: .public)"
        )
    }

    /// Records a fixed validation or persistence outcome which has no underlying `Error`.
    static func logFailure(
        _ surface: MobileDiagnosticSurface,
        code: MobileDiagnosticFailureCode
    ) {
        mobileDiagnosticLogger.error(
            "Mobile operation failed surface=\(surface.rawValue, privacy: .public) code=\(code.rawValue, privacy: .public)"
        )
    }

    static func logFailure(
        _ surface: MobileDiagnosticSurface,
        domain: MobileDiagnosticErrorDomain,
        code: Int
    ) {
        mobileDiagnosticLogger.error(
            "Mobile operation failed surface=\(surface.rawValue, privacy: .public) domain=\(domain.rawValue, privacy: .public) code=\(code, privacy: .public)"
        )
    }

    /// A recoverable request failure where the screen remains usable and already presents a
    /// retry affordance. This is a warning rather than an error because offline operation is
    /// expected for a remote client.
    static func logDegraded(_ surface: MobileDiagnosticSurface, error: Error) {
        mobileDiagnosticLogger.warning(
            "Mobile operation degraded surface=\(surface.rawValue, privacy: .public) code=\(errorCode(error), privacy: .public)"
        )
    }

    static func logDegraded(
        _ surface: MobileDiagnosticSurface,
        code: MobileDiagnosticFailureCode
    ) {
        mobileDiagnosticLogger.warning(
            "Mobile operation degraded surface=\(surface.rawValue, privacy: .public) code=\(code.rawValue, privacy: .public)"
        )
    }

    /// A refusal the Mac named, kept structural on the way to the log.
    ///
    /// The code and the detail are machine tokens from the wire vocabulary, but they arrive from
    /// another process, so both are reduced to the journal's own alphabet before they reach a
    /// public log field rather than trusted to be well formed.
    static func logDegraded(
        _ surface: MobileDiagnosticSurface,
        code: String,
        detail: String?
    ) {
        let safeCode = machineToken(code)
        let safeDetail = detail.map(machineToken) ?? "none"
        mobileDiagnosticLogger.warning(
            "Mobile operation degraded surface=\(surface.rawValue, privacy: .public) code=\(safeCode, privacy: .public) detail=\(safeDetail, privacy: .public)"
        )
    }

    /// The same alphabet `RemoteDiagnosticUploadPolicy` enforces on an imported field value.
    static func machineToken(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "." || scalar == ":" || scalar == "_"
        }
        let token = String(String.UnicodeScalarView(filtered.prefix(machineTokenLimit)))
        return token.isEmpty ? "unknown" : token
    }

    private static let machineTokenLimit = 64

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

/// What the connection did, not only where it stopped.
///
/// The support report's header carried `connectionState` as one snapshot value, so a phone that
/// never reached the Mac and a phone that connected and dropped produced identical reports and
/// have opposite fixes. This is a ring rather than a log: fixed capacity, one entry per real
/// transition, and ages rendered at read time so a long-lived process cannot grow the value.
@MainActor
enum MobileConnectionStateLog {
    /// Eight transitions is the useful recent past and stays inside the report field's 160-byte
    /// budget even at the longest state name and the widest age.
    static let capacity = 8
    /// Ages are clamped so one old entry cannot widen the whole value without bound.
    static let maximumAgeSeconds = 99_999

    private struct Entry {
        let state: RemoteMobileConnectionState
        let at: Date
    }

    private static var entries: [Entry] = []

    static func record(_ state: RemoteMobileConnectionState, at moment: Date = Date()) {
        guard entries.last?.state != state else { return }
        entries.append(Entry(state: state, at: moment))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// `state-secondsAgo`, oldest first, in the journal's own alphabet.
    static func summary(now: Date = Date()) -> String? {
        guard !entries.isEmpty else { return nil }
        return entries.map { entry in
            let age = max(0, Int(now.timeIntervalSince(entry.at)))
            return "\(entry.state.rawValue)-\(min(age, maximumAgeSeconds))"
        }.joined(separator: ":")
    }

    static func reset() {
        entries.removeAll()
    }
}

/// The recent lifecycle of attachment previews, reduced to a closed, content-free vocabulary.
///
/// A snapshot cannot distinguish a page that never asked from one whose request was cancelled.
/// This ring answers that exact triage question without putting normal preview traffic into the
/// 5,000-record journal. Unlike connection states, repeated values are attempts and must not be
/// coalesced. The five-character kind tokens and six-character outcomes keep every possible
/// eight-entry value inside the public report's 160-byte field ceiling.
@MainActor
enum MobileAttachmentPreviewLog {
    static let capacity = 8
    static let maximumAgeSeconds = 99_999

    enum KindToken: String, CaseIterable {
        case image
        case pdf
        case html
        case arch
        case doc
        case diag
        case video
        case media
        case text
        case unk
    }

    enum Outcome: String, CaseIterable {
        case start
        case ok
        case fail
        case cancel
        case skip
    }

    private struct Entry {
        let kind: KindToken
        let outcome: Outcome
        let at: Date
    }

    private static var entries: [Entry] = []

    static func kindToken(for kind: RemoteAttachmentKind) -> KindToken {
        switch kind {
        case .image: .image
        case .pdf: .pdf
        case .html: .html
        case .archive: .arch
        case .document: .doc
        case .diagram: .diag
        case .video: .video
        case .media: .media
        case .text: .text
        case .unknown: .unk
        }
    }

    static func record(
        kind: RemoteAttachmentKind,
        outcome: Outcome,
        at moment: Date = Date()
    ) {
        entries.append(Entry(kind: kindToken(for: kind), outcome: outcome, at: moment))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// `<kind>.<outcome>-<secondsAgo>`, oldest first.
    static func summary(now: Date = Date()) -> String? {
        guard !entries.isEmpty else { return nil }
        return entries.map { entry in
            let age = max(0, Int(now.timeIntervalSince(entry.at)))
            return "\(entry.kind.rawValue).\(entry.outcome.rawValue)-"
                + "\(min(age, maximumAgeSeconds))"
        }.joined(separator: ":")
    }

    static func reset() {
        entries.removeAll()
    }
}

private func reportMobileDiagnosticStorageEvent(
    _ event: RemoteDiagnosticJournalStorageEvent
) {
    if event.outcome == .recovered {
        mobileDiagnosticLogger.notice(
            "Remote diagnostic journal storage recovered stage=\(event.stage.rawValue, privacy: .public)"
        )
        return
    }

    switch event.stage {
    case .encoding:
        mobileDiagnosticLogger.fault(
            "Remote diagnostic journal storage failed stage=\(event.stage.rawValue, privacy: .public) domain=\(event.errorDomain.rawValue, privacy: .public) code=\(event.errorCode, privacy: .public) affected=\(event.affectedCount, privacy: .public)"
        )
    case .directory, .fileCreation, .fileOpen, .seek, .write, .read:
        mobileDiagnosticLogger.error(
            "Remote diagnostic journal storage failed stage=\(event.stage.rawValue, privacy: .public) domain=\(event.errorDomain.rawValue, privacy: .public) code=\(event.errorCode, privacy: .public) affected=\(event.affectedCount, privacy: .public)"
        )
    case .recordTooLarge, .close, .enumerate, .metadata, .decode, .retention:
        mobileDiagnosticLogger.warning(
            "Remote diagnostic journal storage failed stage=\(event.stage.rawValue, privacy: .public) domain=\(event.errorDomain.rawValue, privacy: .public) code=\(event.errorCode, privacy: .public) affected=\(event.affectedCount, privacy: .public)"
        )
    }
}

/// A short-lived, user-started bridge from the content-free iOS journal to one paired Mac.
///
/// The capability remains in the existing Keychain-backed `RemoteConnectionLink`; this object
/// is memory-only, so relaunching the app always ends sharing early rather than silently
/// restoring consent.
@MainActor
final class MobileDiagnosticSharingController: ObservableObject {
    @Published private(set) var sharingUntil: Date?
    @Published private(set) var destination: URL?

    private var link: RemoteConnectionLink?
    private var pending: [RemoteDiagnosticRecord] = []
    private var isUploading = false
    private var expirationTask: Task<Void, Never>?
    private var generation = 0

    func isSharing(with candidate: RemoteConnectionLink) -> Bool {
        link == candidate && (sharingUntil ?? .distantPast) > Date()
    }

    func beginSharing(with candidate: RemoteConnectionLink) async throws {
        if isSharing(with: candidate) { return }
        await endSharing()

        link = candidate
        destination = candidate.baseURL
        sharingUntil = Date().addingTimeInterval(
            RemoteDiagnosticUploadPolicy.sharingDuration
        )
        MobileDiagnostics.journal.record(.diagnosticSharingStarted, fields: [
            .reason: "user",
        ])
        pending = MobileDiagnostics.journal.records()

        do {
            try await flush()
        } catch {
            clear()
            MobileDiagnostics.journal.record(.diagnosticSharingStopped, fields: [
                .reason: "uploadFailed",
            ])
            throw error
        }

        expirationTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(RemoteDiagnosticUploadPolicy.sharingDuration)
            )
            guard !Task.isCancelled else { return }
            await self?.endSharing(reason: "expired")
        }
    }

    func endSharing(reason: String = "user") async {
        guard link != nil else {
            clear()
            return
        }
        let stopped = MobileDiagnostics.journal.record(
            .diagnosticSharingStopped,
            fields: [.reason: reason]
        )
        pending.append(stopped)
        try? await flush()
        clear()
    }

    func enqueue(_ record: RemoteDiagnosticRecord) {
        guard link != nil, (sharingUntil ?? .distantPast) > Date() else { return }
        pending.append(record)
        Task { [weak self] in
            try? await self?.flush()
        }
    }

    private func flush() async throws {
        guard !isUploading, let link else { return }
        let uploadGeneration = generation
        isUploading = true
        defer {
            if generation == uploadGeneration {
                isUploading = false
            }
        }

        let client = RemoteClient(link: link)
        while !pending.isEmpty {
            let count = min(
                pending.count,
                RemoteDiagnosticUploadPolicy.maximumRecordsPerUpload
            )
            let batch = Array(pending.prefix(count))
            let response = try await client.uploadDiagnostics(batch)
            guard generation == uploadGeneration, self.link == link else { return }
            guard response.acceptedRecords == batch.count else {
                throw RemoteClientError.invalidResponse
            }
            pending.removeFirst(batch.count)
        }
    }

    private func clear() {
        generation &+= 1
        expirationTask?.cancel()
        expirationTask = nil
        sharingUntil = nil
        destination = nil
        link = nil
        pending.removeAll()
        isUploading = false
    }
}

struct RemoteDiagnosticsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var isRunningChecks = false
    @State private var sharePayload: DiagnosticsSharePayload?
    @State private var issueReportRequest: MobileIssueReportRequest?
    @State private var exportError: String?
    @State private var sharingError: String?
    @State private var isChangingSharing = false
    @ObservedObject private var diagnosticSharing = MobileDiagnostics.sharing

    var body: some View {
        NavigationStack {
            List {
                ThemedSettingsSection {
                    diagnosticRow(
                        "Mac",
                        value: model.activeHost?.name ?? MobileL10n.string("None")
                    )
                    diagnosticRow("Status", value: connectionStatus)
                    diagnosticRow(
                        "Remote protocol",
                        value: MobileL10n.string(
                            "%lld · accepts %lld+",
                            Int64(RemoteProtocol.current),
                            Int64(RemoteProtocol.minimumSupported)
                        )
                    )
                } header: {
                    Text("Connection")
                }

                ThemedSettingsSection {
                    diagnosticRow("Permission", value: authorizationStatus)
                    diagnosticRow(
                        "APNs device token",
                        value: MobileL10n.string(
                            notifications.deviceToken == nil ? "Waiting" : "Registered"
                        )
                    )
                    diagnosticRow("Delivery", value: deliveryStatus)
                } header: {
                    Text("Notifications")
                }

                if let host = model.activeHost, host.isOwnerDevice {
                    ThemedSettingsSection {
                        if diagnosticSharing.isSharing(with: host.link),
                           let until = diagnosticSharing.sharingUntil {
                            diagnosticRow(
                                "Sharing",
                                value: MobileL10n.string(
                                    "Until %@",
                                    until.formatted(date: .omitted, time: .shortened)
                                )
                            )
                            Button {
                                isChangingSharing = true
                                Task {
                                    await diagnosticSharing.endSharing()
                                    isChangingSharing = false
                                }
                            } label: {
                                Label(
                                    "Stop sharing diagnostics",
                                    systemImage: "stop.circle"
                                )
                            }
                            .disabled(isChangingSharing)
                        } else {
                            Button {
                                isChangingSharing = true
                                Task {
                                    do {
                                        try await diagnosticSharing.beginSharing(
                                            with: host.link
                                        )
                                    } catch {
                                        sharingError = MobileL10n.string(
                                            "The Mac could not accept diagnostics."
                                        )
                                    }
                                    isChangingSharing = false
                                }
                            } label: {
                                if isChangingSharing {
                                    HStack {
                                        ProgressView().controlSize(.small)
                                        Text("Starting diagnostics sharing…")
                                    }
                                } else {
                                    Label(
                                        "Share diagnostics for 30 minutes",
                                        systemImage: "wave.3.right.circle"
                                    )
                                }
                            }
                            .disabled(isChangingSharing)
                        }
                    } header: {
                        Text("Mac diagnostics")
                    } footer: {
                        Text(
                            "Sends only the connection events listed in this report to your "
                                + "paired Mac. Messages, prompts, terminal output, paths and "
                                + "credentials are never sent."
                        )
                    }
                }

                ThemedSettingsSection {
                    Button {
                        isRunningChecks = true
                        Task {
                            await notifications.refreshAuthorization()
                            await model.refresh()
                            await notifications.sync(hosts: model.hosts)
                            isRunningChecks = false
                        }
                    } label: {
                        if isRunningChecks {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Checking…")
                            }
                        } else {
                            Label("Run connection checks", systemImage: "stethoscope")
                        }
                    }
                    .disabled(isRunningChecks)

                    Button {
                        MobileDiagnostics.record(.issueReportOpened, fields: [
                            .reason: "diagnostics"
                        ])
                        issueReportRequest = MobileIssueReportRequest(
                            trigger: .diagnostics,
                            screenshot: nil,
                            screenshotWasRequested: false
                        )
                    } label: {
                        Label("Report a problem", systemImage: "exclamationmark.bubble")
                    }

                    Button {
                        do {
                            MobileDiagnostics.record(.issueReportExported, fields: [
                                .reason: "diagnostics-only",
                            ])
                            let url = try MobileDiagnostics.supportReport()
                            sharePayload = DiagnosticsSharePayload(items: [url])
                        } catch {
                            exportError = MobileL10n.string(
                                "The support report could not be prepared."
                            )
                        }
                    } label: {
                        Label("Share diagnostics only", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(
                        "Reports contain build, protocol and connection events. They exclude "
                            + "messages, prompts, file paths, notification text and credentials."
                    )
                }
            }
            .themedSettingsPage(theme)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            DiagnosticsActivityView(items: payload.items)
        }
        .sheet(item: $issueReportRequest) { request in
            MobileIssueReportView(request: request)
                .mobileTheme(theme)
        }
        .themedAlert(
            "Couldn’t export diagnostics",
            message: exportError ?? "",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
        .themedAlert(
            "Couldn’t share diagnostics",
            message: sharingError ?? "",
            isPresented: Binding(
                get: { sharingError != nil },
                set: { if !$0 { sharingError = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
        .presentationDetents([.medium, .large])
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack {
            Text(MobileL10n.string(title))
            Spacer()
            Text(value)
                .foregroundStyle(theme.secondaryLabel)
                .multilineTextAlignment(.trailing)
        }
    }

    private var connectionStatus: String {
        switch model.phase {
        case .idle: return MobileL10n.string("Idle")
        case .connecting: return MobileL10n.string("Connecting")
        case .online: return MobileL10n.string("Online")
        case .offline: return MobileL10n.string("Offline")
        }
    }

    private var authorizationStatus: String {
        switch notifications.authorizationStatus {
        case .notDetermined: return MobileL10n.string("Not requested")
        case .denied: return MobileL10n.string("Denied")
        case .authorized: return MobileL10n.string("Allowed")
        case .provisional: return MobileL10n.string("Provisional")
        case .ephemeral: return MobileL10n.string("Temporary")
        @unknown default: return MobileL10n.string("Unknown")
        }
    }

    private var deliveryStatus: String {
        guard let host = model.activeHost else { return MobileL10n.string("No Mac") }
        switch notifications.deliveryByConnection[host.id] {
        case .push: return "APNs"
        case .live: return MobileL10n.string("Live only")
        case .some(let value): return value.rawValue
        case nil: return MobileL10n.string("Not registered")
        }
    }
}

struct DiagnosticsSharePayload: Identifiable {
    let id = UUID()
    let items: [URL]
}

struct DiagnosticsActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
