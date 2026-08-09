import Foundation

// MARK: - Codex Transcript Interruption

/// The structured record Codex writes when the user interrupts a terminal turn.
///
/// Codex 0.147.0 does not raise its `Stop` hook on this path. It does append an `event_msg`
/// carrying `turn_aborted`, the turn id and `reason: "interrupted"`, then redraws its prompt.
/// That record is the missing terminal lifecycle edge; presentation text such as
/// "Conversation interrupted" is deliberately not parsed.
struct CodexTurnInterruption: Equatable, Sendable {
    let turnID: String
}

/// Reads whether the newest lifecycle boundary in a Codex rollout is an interrupted turn.
///
/// The shared `TranscriptFactReader` makes a quiet-edge refresh one background `stat`, scanning
/// only when the rollout grew and calling back only when the answer changed. The backwards scan
/// is capped at one chunk. This path therefore stays O(changed) as both turn count and terminal
/// output frequency grow; a boundary hidden behind an exceptional record larger than the cap is
/// left to the ordinary hook rather than turning a UI callback into a whole-transcript read.
@MainActor
enum CodexTranscriptInterruption {

    // MARK: - Properties

    private static let reader = TranscriptFactReader<CodexTurnInterruption> { url in
        newestInterruption(at: url)
    }

    // MARK: - Public Methods

    static func revalidate(
        at url: URL,
        completion: @escaping @MainActor @Sendable (CodexTurnInterruption?) -> Void
    ) {
        reader.revalidate(at: url, completion: completion)
    }

    static func forgetAll() {
        reader.forgetAll()
    }

    /// Returns an interruption only when it is the rollout's newest turn boundary.
    ///
    /// `task_started` and `task_complete` stop the backwards walk too. Without that rule, a
    /// historical interruption would remain discoverable underneath a newer active or completed
    /// turn and a delayed read could stop the wrong work.
    nonisolated static func newestInterruption(at url: URL) -> CodexTurnInterruption? {
        var newest: CodexTurnInterruption?

        JSONLReader.forEachRecordFromEnd(
            at: url,
            limit: CodexInterruptionDefaults.scanBytes
        ) { record in
            guard let payload = lifecyclePayload(in: record),
                  let type = payload[CodexInterruptionDefaults.typeKey] as? String else {
                return true
            }

            switch type {
            case CodexInterruptionDefaults.abortedType:
                newest = interruptionPayload(payload)
                return false
            case CodexInterruptionDefaults.startedType,
                 CodexInterruptionDefaults.completedType:
                return false
            default:
                return true
            }
        }

        return newest
    }

    /// Parses only Codex's structured abort payload. Kept visible to focused wire tests.
    nonisolated static func interruption(
        in record: [String: Any]
    ) -> CodexTurnInterruption? {
        guard let payload = lifecyclePayload(in: record) else { return nil }
        return interruptionPayload(payload)
    }

    // MARK: - Private Methods

    private nonisolated static func lifecyclePayload(
        in record: [String: Any]
    ) -> [String: Any]? {
        guard record[CodexInterruptionDefaults.typeKey] as? String
                == CodexInterruptionDefaults.eventMessageType else {
            return nil
        }
        return record[CodexInterruptionDefaults.payloadKey] as? [String: Any]
    }

    private nonisolated static func interruptionPayload(
        _ payload: [String: Any]
    ) -> CodexTurnInterruption? {
        guard payload[CodexInterruptionDefaults.typeKey] as? String
                == CodexInterruptionDefaults.abortedType,
              payload[CodexInterruptionDefaults.reasonKey] as? String
                == CodexInterruptionDefaults.interruptedReason,
              let turnID = payload[CodexInterruptionDefaults.turnIDKey] as? String,
              !turnID.isEmpty else {
            return nil
        }
        return CodexTurnInterruption(turnID: turnID)
    }
}

// MARK: - Defaults

enum CodexInterruptionDefaults {
    static let quietDelay: TimeInterval = 0.5
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
}
