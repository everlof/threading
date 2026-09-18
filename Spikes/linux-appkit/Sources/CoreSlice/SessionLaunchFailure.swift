import Foundation

// MARK: - Session Launch Failure

/// What a launch that died on the way up left behind.
///
/// A session whose agent exits after a long working run is *finished*; a session whose agent
/// exits a second after starting has **failed**, and the two are told apart here rather than at
/// every place that reacts to an exit. Only the second kind produces a record.
///
/// The distinction is not cosmetic. Threading's answer to an ordinary exit is to tear the
/// terminal down and offer the conversation back — which, for a failure, destroys the only
/// account of what went wrong. A resume that Codex refuses prints its reason to the terminal,
/// exits 1, and is gone from the screen inside a hundred milliseconds; the exit code was already
/// stored (`AgentSession.lastExitCode`) and read by nothing. This record is what makes that
/// moment survivable: it keeps the words, so the pane can say them, the user can copy them, a
/// report can carry them, and a recovery agent can be briefed with them.
///
/// It is provider-neutral by construction. Nothing here names a runtime — a missing executable,
/// a refused identifier, an expired login and a corrupt transcript all arrive as the same shape,
/// because the handling they need is the same and only the words differ.
struct SessionLaunchFailure: Codable, Equatable {

    // MARK: - Types

    /// Whether the process said this, or Threading knew before starting one.
    enum Origin: String, Codable {
        /// A process launched and exited without ever becoming useful.
        case processExit
        /// A preflight check refused the launch, so no process was started.
        ///
        /// Worth its own case rather than a synthetic exit code: "we did not try" and "we tried
        /// and it died" lead to different words and different offers, and a preflight refusal
        /// has no captured screen to show.
        case preflight
    }

    // MARK: - Properties

    let origin: Origin

    /// The process's exit status, when there was a process. Nil for a preflight refusal and for
    /// a process that ended without one — a signal, or a PTY that closed first.
    let exitCode: Int32?

    /// How long the process lived. Nil for a preflight refusal.
    ///
    /// Kept rather than recomputed because the threshold that classified this failure may move,
    /// and a stored record must still say what was actually measured.
    let ranFor: TimeInterval?

    let detectedAt: Date

    /// One line for the band: what happened, in the user's terms.
    let summary: String

    /// The captured evidence, already bounded and stripped of blank rows.
    ///
    /// For a process exit this is the tail of the terminal screen — whatever the agent printed
    /// on its way out. It is arbitrary program output, so it is never sent anywhere on its own:
    /// it is shown to the user, and every route off this machine puts it in front of them first.
    let detail: [String]

    /// The conversation file a recovery attempt would work on, when one is known.
    ///
    /// Stored as a path rather than resolved later because the account that owns it can be
    /// re-routed, and a record must keep naming the file that actually failed.
    let transcriptPath: String?

    /// A stable slug for a cause Threading recognises, or nil for one it does not.
    ///
    /// Recognising a cause only ever *adds* — a better sentence, a more specific offer. Nothing
    /// branches on this being nil, because the unrecognised case is the common one and must
    /// stay fully handled.
    let knownCause: String?

    // MARK: - Initialization

    init(
        origin: Origin,
        exitCode: Int32? = nil,
        ranFor: TimeInterval? = nil,
        detectedAt: Date = Date(),
        summary: String,
        detail: [String] = [],
        transcriptPath: String? = nil,
        knownCause: String? = nil
    ) {
        self.origin = origin
        self.exitCode = exitCode
        self.ranFor = ranFor
        self.detectedAt = detectedAt
        self.summary = summary
        self.detail = SessionLaunchFailure.bounded(detail)
        self.transcriptPath = transcriptPath
        self.knownCause = knownCause
    }

    // MARK: - Public Methods

    /// Whether an exit looks like a failure to launch rather than an agent finishing.
    ///
    /// Two facts, both required. A non-zero status alone would catch every agent the user quits
    /// with a signal or a non-zero `/exit`; a short life alone would catch a session opened and
    /// closed on purpose. Together they describe the thing that has no other explanation: a
    /// process that was asked to start, said something, and was gone before it could be used.
    static func looksLikeLaunchFailure(exitCode: Int32?, ranFor: TimeInterval) -> Bool {
        guard let exitCode, exitCode != 0 else { return false }
        return ranFor < SessionLaunchFailureDefaults.youngProcessWindow
    }

    /// The record as text, for Copy Details and for anything that has to read it as prose.
    var report: String {
        var lines = [summary]
        if let exitCode {
            lines.append(L10n.format("Exit code: %@", String(exitCode)))
        }
        if let transcriptPath {
            lines.append(L10n.format("Conversation file: %@", transcriptPath))
        }
        if !detail.isEmpty {
            lines.append("")
            lines.append(contentsOf: detail)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private Methods

    /// Keeps the tail, drops the blanks, and clips a line no reader benefits from.
    ///
    /// The tail rather than the head: a program that prints a banner and then fails puts the
    /// reason last, and the banner is the part already visible everywhere else. Clipping is per
    /// line as well as per record because one wrapped 400-column error would otherwise spend the
    /// whole budget saying one thing.
    private static func bounded(_ lines: [String]) -> [String] {
        let meaningful = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line -> String in
                guard line.count > SessionLaunchFailureDefaults.capturedLineLength else { return line }
                return String(line.prefix(SessionLaunchFailureDefaults.capturedLineLength))
                    + SessionLaunchFailureDefaults.clipMarker
            }

        guard meaningful.count > SessionLaunchFailureDefaults.capturedLineCount else {
            return meaningful
        }
        return Array(meaningful.suffix(SessionLaunchFailureDefaults.capturedLineCount))
    }
}

// MARK: - Defaults

enum SessionLaunchFailureDefaults {

    /// How briefly a process must live for its non-zero exit to read as a failed launch.
    ///
    /// Generous on purpose. The failures this catches are decided in milliseconds — a refused
    /// identifier, a missing executable, a transcript the runtime will not open — while the
    /// nearest false positive is a user quitting an agent they only just started, which costs
    /// them one dismissible band. The asymmetry says to be generous.
    static let youngProcessWindow: TimeInterval = 5

    /// How many screen lines a captured failure keeps.
    static let capturedLineCount = 40

    /// How wide one of them may be before it is clipped.
    static let capturedLineLength = 400

    static let clipMarker = "…"
}
