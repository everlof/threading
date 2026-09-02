import Foundation

// MARK: - Codex Rollout Format

/// The record shapes a Codex rollout uses for dialogue, and the CLI range they were measured on.
///
/// Codex moved its dialogue between releases without changing anything that announces it. Up to
/// 0.146 every user turn was an `event_msg` of type `user_message` and every answer an
/// `agent_message`. 0.147 started writing `item_completed` events whose `item.type` is
/// `UserMessage` or `AgentMessage`; rollouts of 0.147 through 0.149 carry one shape or the other,
/// and from 0.150.1 the old events are gone. Measured over 963 rollouts on one machine:
///
/// | CLI          | `user_message` | `item_completed/UserMessage` |
/// |--------------|----------------|------------------------------|
/// | ≤ 0.146      | every file     | none                         |
/// | 0.147–0.149  | some files     | most files                   |
/// | ≥ 0.150.1    | none           | every parent thread          |
///
/// Threading read only the first column, so every rollout written since 30 August 2026 replayed
/// as tool rows with no conversation, and one cross-provider handoff froze 992k characters of
/// tool output without a single user message. This enum is the one place the vocabulary lives;
/// `CodexRolloutFormatProbe` is the tripwire that says when the vocabulary has stopped matching
/// the files.
enum CodexRolloutFormat {

    /// The newest Codex CLI whose rollouts the reader has been checked against, and the oldest a
    /// committed fixture still exercises. Bump the newest after running the opt-in audit in
    /// `CodexRolloutFormatTests` (`THREADING_CODEX_ROLLOUT_AUDIT=1`) over real rollouts of the new
    /// release and, when a shape changed, regenerating a fixture with `scripts/scrub_transcript.py`.
    static let newestVerifiedCLIVersion = "0.152.0"
    static let oldestVerifiedCLIVersion = "0.142.5"

    enum RecordType {
        static let eventMessage = "event_msg"
        static let responseItem = "response_item"
        static let sessionMeta = CodexDiscoveryDefaults.sessionMetaType
    }

    enum EventType {
        /// The pre-0.147 dialogue events. Still read, because rollouts never change shape once
        /// written and the majority on any machine that has run Codex for a while are this.
        static let legacyUserMessage = CodexDiscoveryDefaults.userMessageType
        static let legacyAgentMessage = "agent_message"
        static let legacyAgentReasoning = "agent_reasoning"
        /// The 0.147+ envelope; the dialogue is the `item` inside it.
        static let itemCompleted = "item_completed"
    }

    enum ItemType {
        static let userMessage = "UserMessage"
        static let agentMessage = "AgentMessage"
        static let reasoning = "Reasoning"
        static let contextCompaction = "ContextCompaction"

        /// Every item type measured so far. The tool-shaped ones replay from their paired
        /// `response_item` records rather than from here, so they map to nothing; being named
        /// keeps them out of the probe's unfamiliar list.
        static let known: Set<String> = [
            userMessage, agentMessage, reasoning, contextCompaction,
            "CommandExecution", "FileChange", "McpToolCall", "Extension",
            "SubAgentActivity", "CollabAgentToolCall", "ImageView",
        ]
    }

    enum ResponseItemType {
        /// The request history the CLI sends back to the model, one record per message. Every
        /// format so far has kept it, which is what makes it the probe's reference.
        static let message = "message"
    }

    enum Role {
        static let user = "user"
        static let assistant = "assistant"
    }

    enum Key {
        static let payload = "payload"
        static let type = "type"
        static let item = "item"
        static let content = "content"
        static let text = "text"
        static let role = "role"
        static let summaryText = "summary_text"
        static let cliVersion = "cli_version"
    }

    /// The visible text of an `item` or `message` content list: the `text` of every block, in
    /// order. Block type tags differ in case between the two shapes (`Text` in an item, `text`
    /// and `output_text` in a message), so blocks are read by what they carry, not what they are
    /// called.
    static func text(of content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { $0[Key.text] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Format Verdict

/// What a transcript's format probe made of the file it read.
enum TranscriptFormatVerdict: Equatable, Sendable {
    /// The reader produced the dialogue the file carries, or the file carries none.
    case recognised
    /// The file holds assistant replies the reader could not turn into dialogue.
    case codexDialogueUnreadable(CodexRolloutFormatDrift)
}

/// A Codex rollout whose dialogue this build cannot read, with what little can be said about it
/// without quoting the conversation.
struct CodexRolloutFormatDrift: Equatable, Sendable {
    let cliVersion: String?
    /// `item_completed` item types this build has never measured that carry content.
    let unfamiliarItemTypes: [String]
    /// Assistant messages in the model-visible history that produced no replayed text.
    let unreadAssistantMessages: Int

    /// The notice drawn where the conversation should have been.
    var notice: String {
        if let cliVersion {
            return L10n.format(
                "Codex %@ wrote this conversation in a format this version of Threading cannot read, so its messages are missing here.",
                cliVersion
            )
        }
        return L10n.string(
            "Codex wrote this conversation in a format this version of Threading cannot read, so its messages are missing here."
        )
    }

    /// Why a handoff was refused rather than made. Not localised, like every other
    /// `ContinuationError` message; the paired iPhone words the code for itself.
    var refusal: String {
        let version = cliVersion.map { "Codex \($0)" } ?? "Codex"
        return "Threading cannot read the conversation in this \(version) transcript: its format "
            + "is newer than this build understands, and the handoff would carry no messages. "
            + "Update Threading to continue this chat with another agent."
    }

    /// The public, content-free description for the log and the journal.
    var logFields: [String: String] {
        [
            "cli_version": cliVersion ?? "unknown",
            "verified_through": CodexRolloutFormat.newestVerifiedCLIVersion,
            "unfamiliar_item_types": unfamiliarItemTypes.sorted().joined(separator: ","),
            "unread_assistant_messages": String(unreadAssistantMessages),
        ]
    }
}

// MARK: - Format Probe

/// Notices when a rollout carries conversation the reader did not produce.
///
/// The check is behavioural rather than a version pin: Codex releases every few days and most
/// releases leave the records alone, so a notice on every conversation after each update would
/// teach people to ignore it. What is compared instead is the model-visible history against
/// what the reader made of it. Every rollout format so far has kept one `response_item`
/// `message` per assistant reply, because that list is the request history the CLI sends back
/// to the model. A rollout with assistant replies in that history and none in the reduction is a
/// format this build cannot read.
///
/// User turns deliberately do not decide the verdict. A spawned sub-agent's rollout carries its
/// brief as a user-role history message and has no `UserMessage` item at all; 18 of the 0.150+
/// rollouts measured were that shape, and each was a correct file.
struct CodexRolloutFormatProbe {

    // MARK: - Properties

    private(set) var cliVersion: String?
    private var historyAssistantMessages = 0
    private var producedAssistantTexts = 0
    private var unfamiliarItemTypes: Set<String> = []

    // MARK: - Public Methods

    /// Observes one record and the event the reader mapped it to.
    mutating func observe(record: [String: Any], event: StreamEvent?) {
        if case .assistantMessage(let blocks)? = event,
           blocks.contains(where: { if case .text = $0 { return true } else { return false } }) {
            producedAssistantTexts += 1
        }

        guard let recordType = record[CodexRolloutFormat.Key.type] as? String,
              let payload = record[CodexRolloutFormat.Key.payload] as? [String: Any] else { return }

        switch recordType {
        case CodexRolloutFormat.RecordType.sessionMeta:
            if let version = payload[CodexRolloutFormat.Key.cliVersion] as? String,
               !version.isEmpty {
                cliVersion = version
            }

        case CodexRolloutFormat.RecordType.responseItem:
            guard payload[CodexRolloutFormat.Key.type] as? String
                    == CodexRolloutFormat.ResponseItemType.message,
                  payload[CodexRolloutFormat.Key.role] as? String
                    == CodexRolloutFormat.Role.assistant,
                  CodexRolloutFormat.text(of: payload[CodexRolloutFormat.Key.content]) != nil
            else { return }
            historyAssistantMessages += 1

        case CodexRolloutFormat.RecordType.eventMessage:
            guard payload[CodexRolloutFormat.Key.type] as? String
                    == CodexRolloutFormat.EventType.itemCompleted,
                  let item = payload[CodexRolloutFormat.Key.item] as? [String: Any],
                  let itemType = item[CodexRolloutFormat.Key.type] as? String,
                  !CodexRolloutFormat.ItemType.known.contains(itemType),
                  item[CodexRolloutFormat.Key.content] != nil
            else { return }
            unfamiliarItemTypes.insert(itemType)

        default:
            return
        }
    }

    var verdict: TranscriptFormatVerdict {
        guard historyAssistantMessages > 0, producedAssistantTexts == 0 else {
            return .recognised
        }
        return .codexDialogueUnreadable(CodexRolloutFormatDrift(
            cliVersion: cliVersion,
            unfamiliarItemTypes: unfamiliarItemTypes.sorted(),
            unreadAssistantMessages: historyAssistantMessages
        ))
    }
}
