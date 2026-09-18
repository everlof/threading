import Foundation
import ThreadingRemoteKit

/// One chat opening, from the tap to a surface a person can use, as `sessionOpen*` records.
///
/// Every stage of an opening already had its own record — the catalogue refresh, the resume, the
/// socket hello, the host's attach — but no record said how long the person waited, so a chat that
/// "felt slow" had to be reconstructed by hand from three traces (2026-09-18: a Codex chat whose
/// socket answered in 301 ms). This span is that missing total. It starts when the detail screen
/// begins opening, marks each fixed stage with its time since the tap, and ends exactly once: when
/// the surface is revealed, when the opening fails before a socket exists, or when the person
/// leaves first. A socket that fails and retries stays inside the same opening, because the person
/// is still looking at the same loader.
///
/// Records are written off the main actor, like the connection's own interaction diagnostics.
@MainActor
final class MobileSessionOpenSpan {
    /// The fixed stages an opening can pass through, in the order they can occur.
    enum Stage: String {
        /// The authoritative catalogue row was in hand, after joining any host recovery.
        case catalogue
        /// A dormant session was asked to start and the Mac accepted.
        case wake
        /// A socket began dialling, or a parked socket began reattaching.
        case socket
        /// A socket attempt failed and the opening continues on the next one.
        case retry
        /// The host's hello arrived.
        case hello
    }

    /// How the opening reached its socket.
    enum Path: String {
        /// A parked warm socket was reattached.
        case pooled
        /// A new socket was dialled to a running session.
        case fresh
        /// The session had to be started first.
        case woken
    }

    /// What revealed the surface.
    enum Reveal: String {
        /// A surface with no terminal hydration is usable at its hello.
        case hello
        /// The host's ordered `terminalReady` boundary.
        case boundary
        /// An older host: the phone's own quiet window after output.
        case quiet
        /// The phone's own ceiling ended the hold.
        case ceiling
    }

    private enum Result: String {
        case succeeded
        case failed
        case abandoned
        case superseded
    }

    // MARK: - Properties

    var path: Path = .fresh
    private(set) var isFinished = false
    private let startedAt = MobileDiagnostics.monotonicNow()
    private let baseFields: [RemoteDiagnosticField: String]

    private static let queue = DispatchQueue(
        label: "codes.threading.mobile.session-open-diagnostics",
        qos: .utility
    )

    // MARK: - Initialization

    init(session: RemoteSessionSummaryDTO) {
        baseFields = [
            .trace: MobileDiagnostics.connectivityTrace(),
            .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
            .surface: session.surface.rawValue,
            .detail: MobileAgentIdentity.resolve(session.agentKind).diagnosticToken,
        ]
        write(.sessionOpenStarted, fields: [.result: "started"])
    }

    // MARK: - Public Methods

    func reached(_ stage: Stage) {
        guard !isFinished else { return }
        write(.sessionOpenProgress, fields: [
            .phase: stage.rawValue,
            .result: "stage",
            .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
        ])
    }

    func revealed(by reveal: Reveal, transport: String? = nil, origin: String? = nil) {
        var fields: [RemoteDiagnosticField: String] = [.phase: reveal.rawValue]
        if let transport { fields[.transport] = transport }
        if let origin { fields[.origin] = origin }
        finish(.succeeded, fields: fields)
    }

    func failed(code: String) {
        finish(.failed, fields: [.code: code])
    }

    func abandoned() {
        finish(.abandoned, fields: [:])
    }

    /// A newer opening of the same connection took over before this one was usable.
    func superseded() {
        finish(.superseded, fields: [:])
    }

#if DEBUG
    /// Lets a test cross the asynchronous writer boundary once, rather than re-reading the
    /// journal until the record appears, which starves the writer it is waiting on.
    static func waitForWritesForTesting() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
#endif

    // MARK: - Private Methods

    private func finish(_ result: Result, fields: [RemoteDiagnosticField: String]) {
        guard !isFinished else { return }
        isFinished = true
        write(
            .sessionOpenEnded,
            level: result == .failed ? .warning : .info,
            fields: fields.merging([
                .result: result.rawValue,
                .reason: path.rawValue,
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
            ]) { current, _ in current }
        )
    }

    private func write(
        _ event: RemoteDiagnosticEvent,
        level: RemoteDiagnosticLevel = .info,
        fields: [RemoteDiagnosticField: String]
    ) {
        let merged = baseFields.merging(fields) { _, new in new }
        Self.queue.async {
            MobileDiagnostics.recordConnectivity(event, level: level, fields: merged)
        }
    }
}
