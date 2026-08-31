import Foundation

// MARK: - Codex Transcript Turn Boundary

/// The newest turn boundary a Codex rollout records.
///
/// Codex writes all three whether or not a hook reports them, and the two that no hook reports
/// are why this is read at all:
///
/// - **`started` is the one Codex opens without being asked.** In goal mode the CLI continues
///   the thread with an internal message (`<codex_internal_context source="goal">`), which
///   submits no user prompt — so `UserPromptSubmit` never fires, and `UserPromptSubmit` is the
///   only turn-start hook the CLI has. Read from here, such a turn is a fact with an id rather
///   than something inferred from repaint bytes.
/// - **`interrupted`** is the boundary omitted when the user presses Escape (CLI 0.147.0):
///   Codex raises no `Stop`, and appends `turn_aborted` with `reason: "interrupted"` instead.
/// - **`completed`** is the boundary the `Stop` hook already reports, exactly and first — Codex
///   writes it about three milliseconds *after* the hook fires. It is carried anyway because it
///   is what tells a lost `Stop` apart from a turn still running, and because a value that
///   changed is how the reader below knows to call back at all.
///
/// Presentation text such as the red "Conversation interrupted" notice is deliberately not
/// parsed; every case here is a structured `event_msg`.
enum CodexTurnBoundary: Equatable, Sendable {
    case started(turnID: String)
    case completed(turnID: String)
    case interrupted(turnID: String)

    /// The turn this boundary is about. Every case names one; Codex's `event_msg` payloads
    /// carry `turn_id` on all three.
    var turnID: String {
        switch self {
        case .started(let turnID), .completed(let turnID), .interrupted(let turnID):
            return turnID
        }
    }

    /// The name this boundary is written under in the log and the journal. Stated rather than
    /// reflected, for the reason `SessionActivity.logName` gives: a rename must not silently
    /// rewrite what every past line meant.
    var logName: String {
        switch self {
        case .started: return "started"
        case .completed: return "completed"
        case .interrupted: return "interrupted"
        }
    }
}

/// Reads the newest lifecycle boundary out of a Codex rollout.
///
/// The shared `TranscriptFactReader` makes a quiet-edge refresh one background `stat`, scanning
/// only when the rollout grew and calling back only when the answer changed. The backwards scan
/// is capped at one chunk. This path therefore stays O(changed) as both turn count and terminal
/// output frequency grow; a boundary hidden behind an exceptional record larger than the cap is
/// left to the ordinary hook rather than turning a UI callback into a whole-transcript read.
@MainActor
enum CodexTranscriptTurnBoundary {

    // MARK: - Properties

    private static let reader = TranscriptFactReader<CodexTurnBoundary> { url in
        newestBoundary(at: url)
    }

    // MARK: - Public Methods

    static func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (CodexTurnBoundary?) -> Void
    ) {
        reader.revalidate(at: url, completion: completion)
    }

    static func forgetAll() {
        reader.forgetAll()
    }

    /// Walks back to the first lifecycle record and answers with that one alone.
    ///
    /// Stopping at the *first* boundary is the whole rule. Without it a historical interruption
    /// would remain discoverable underneath a newer active or completed turn and a delayed read
    /// could stop the wrong work — and, now that starts are admitted too, an old start would be
    /// discoverable under the turn that already ended it.
    ///
    /// An abort whose reason this build does not recognise answers nil rather than falling
    /// through to the boundary below it: it is still a boundary, so nothing older is current,
    /// and it is not one this build knows what to do with.
    nonisolated static func newestBoundary(at url: URL) -> CodexTurnBoundary? {
        var newest: CodexTurnBoundary?

        JSONLReader.forEachRecordFromEnd(
            at: url,
            limit: CodexTurnBoundaryDefaults.scanBytes
        ) { record in
            guard let payload = lifecyclePayload(in: record),
                  let type = payload[CodexTurnBoundaryDefaults.typeKey] as? String,
                  CodexTurnBoundaryDefaults.boundaryTypes.contains(type) else {
                return true
            }

            newest = boundary(inPayload: payload, type: type)
            return false
        }

        return newest
    }

    /// Parses only Codex's structured boundary payloads. Kept visible to focused wire tests.
    nonisolated static func boundary(in record: [String: Any]) -> CodexTurnBoundary? {
        guard let payload = lifecyclePayload(in: record),
              let type = payload[CodexTurnBoundaryDefaults.typeKey] as? String else {
            return nil
        }
        return boundary(inPayload: payload, type: type)
    }

    // MARK: - Private Methods

    private nonisolated static func lifecyclePayload(
        in record: [String: Any]
    ) -> [String: Any]? {
        guard record[CodexTurnBoundaryDefaults.typeKey] as? String
                == CodexTurnBoundaryDefaults.eventMessageType else {
            return nil
        }
        return record[CodexTurnBoundaryDefaults.payloadKey] as? [String: Any]
    }

    private nonisolated static func boundary(
        inPayload payload: [String: Any],
        type: String
    ) -> CodexTurnBoundary? {
        guard let turnID = payload[CodexTurnBoundaryDefaults.turnIDKey] as? String,
              !turnID.isEmpty else {
            return nil
        }

        switch type {
        case CodexTurnBoundaryDefaults.startedType:
            return .started(turnID: turnID)
        case CodexTurnBoundaryDefaults.completedType:
            return .completed(turnID: turnID)
        case CodexTurnBoundaryDefaults.abortedType:
            guard payload[CodexTurnBoundaryDefaults.reasonKey] as? String
                    == CodexTurnBoundaryDefaults.interruptedReason else {
                return nil
            }
            return .interrupted(turnID: turnID)
        default:
            return nil
        }
    }
}

// MARK: - Defaults

enum CodexTurnBoundaryDefaults {
    static let quietDelay: TimeInterval = 0.5
    /// Codex goal mode opened its measured continuation 246 ms after `Stop`. Keep the published
    /// turn open long enough for the rollout's `task_started` record to cross the existing
    /// off-main reader without turning that protocol gap into a false attention episode.
    static let continuationGrace: TimeInterval = 1.0
    /// A reported finish gets one look ahead even if the next turn has not painted the terminal.
    static let continuationProbeDelay: TimeInterval = 0.4
    /// Once output resumes, the rollout has already written `task_started`; read it promptly and
    /// do not let a long output burst keep postponing the ordinary quiet-edge refresh.
    static let continuationOutputProbeDelay: TimeInterval = 0.05
    static let scanBytes = JSONLDefaults.chunkBytes

    static let typeKey = "type"
    static let payloadKey = "payload"
    static let reasonKey = "reason"
    static let turnIDKey = "turn_id"

    static let eventMessageType = "event_msg"
    static let startedType = "task_started"
    static let completedType = "task_complete"
    static let abortedType = "turn_aborted"
    static let interruptedReason = "interrupted"

    /// The records that end the backwards walk. A boundary this build cannot act on still ends
    /// it, because everything under it belongs to a turn that is already over.
    static let boundaryTypes: Set<String> = [startedType, completedType, abortedType]
}
