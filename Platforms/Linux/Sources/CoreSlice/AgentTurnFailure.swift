import Foundation

// MARK: - Agent Turn Failure

/// Why the provider refused a turn, where it said so in a typed field rather than only in words.
///
/// The words reach the transcript either way; this exists for the readers that must act on the
/// class of failure without parsing prose. The first is an unattended automation run, which used
/// to settle as "ended without reporting a result" when the real answer was a login that had
/// stopped signing in — and the person found out only by looking.
enum AgentTurnFailure: Equatable, Sendable {
    /// The provider rejected the login's credentials: an expired or revoked sign-in, or a
    /// token that is no longer valid. Retrying cannot help; the person has to sign in again.
    case authenticationFailed
}

// MARK: - Claude Stream Wire

extension AgentTurnFailure {

    /// The failure one Claude `stream-json` line states, or nil when it states none.
    ///
    /// Measured on 2026-10-03 against CLI 2.1.288 with a deliberately invalid token. The stream
    /// writes two `system/api_retry` lines, then a synthetic assistant message and a failed
    /// result:
    ///
    /// ```json
    /// {"type":"assistant","error":"authentication_failed","is_api_error_message":true,
    ///  "message":{"model":"<synthetic>","content":[{"type":"text",
    ///  "text":"Failed to authenticate. API Error: 401 OAuth access token is invalid."}]}}
    /// {"type":"result","subtype":"success","is_error":true,"api_error_status":401,
    ///  "terminal_reason":"api_error","result":"Failed to authenticate. …"}
    /// ```
    ///
    /// The class lives on the assistant line only, so that is the line read. `is_api_error_message`
    /// is the fact and `error` its class; the sentence is never consulted, because a CLI that
    /// rewords it still refused the turn. The stream spells the flag in snake case where the
    /// transcript writes `isApiErrorMessage` (`ClaudeTranscriptAPIError`).
    static func claudeStreamLine(_ line: String) -> AgentTurnFailure? {
        guard line.contains("\"\(ClaudeStreamFailureWire.flagKey)\""),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claudeStreamObject(object)
    }

    static func claudeStreamObject(_ object: [String: Any]) -> AgentTurnFailure? {
        guard object[ClaudeStreamFailureWire.typeKey] as? String == ClaudeStreamFailureWire.assistantType,
              object[ClaudeStreamFailureWire.flagKey] as? Bool == true else { return nil }
        switch object[ClaudeStreamFailureWire.classKey] as? String {
        case ClaudeStreamFailureWire.authenticationFailed: return .authenticationFailed
        default: return nil
        }
    }
}

/// The keys and values of Claude's typed API-error fields on the stream.
enum ClaudeStreamFailureWire {
    static let typeKey = "type"
    static let assistantType = "assistant"
    static let flagKey = "is_api_error_message"
    static let classKey = "error"
    static let authenticationFailed = "authentication_failed"
}

// MARK: - Reporting

/// A transport that can say why the provider refused the turn it most recently ran.
///
/// Cleared when a new turn is sent, so at a turn's end it describes that turn and nothing older.
@MainActor
protocol TurnFailureReportingConversation: AnyObject {
    var lastTurnFailure: AgentTurnFailure? { get }
}
