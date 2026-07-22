import Foundation

// MARK: - Conversation Timeline

/// What a conversation *is*, separated from how it is drawn.
///
/// `ConversationViewController` used to decide the shape of each row and build its view in the
/// same breath, which left the interesting decisions — which tool calls collapse, what a call's
/// one-line subject is, how a result attaches to the call it belongs to, when a streamed
/// placeholder is thrown away — reachable only by standing up AppKit and inspecting a view
/// tree. They are all pure functions of the event stream, so they live here and are tested
/// directly against real transcripts.
///
/// **Incremental, not a fold.** `apply` takes one event and returns only what changed, because
/// the same type serves a live stream and a replay: recomputing every row per token would make
/// streaming quadratic in the length of the conversation. Replay is just `apply` in a loop.
///
/// The split follows t3code's `MessagesTimeline.logic.ts` / `MessagesTimeline.tsx` pattern,
/// where the derivations are ordinary functions with their own unit tests and the component
/// only draws what they return.
struct ConversationTimeline {

    // MARK: - Model

    /// One thing shown in the conversation, in the order it happened.
    enum Row: Equatable {
        case userMessage(String)
        case assistant(markdown: String)
        case thinking(String)
        case toolCall(ToolCall)

        /// Neither said nor tool output: a truncation note, a failed turn, an orphan result.
        case notice(String, kind: NoticeKind)
    }

    enum NoticeKind: Equatable {
        case error
        case muted
    }

    /// A tool call and, once it arrives, its result. One row rather than two: the call and what
    /// it returned are the same event to a reader, and splitting them puts unrelated rows
    /// between a command and its output whenever an agent fires several at once.
    struct ToolCall: Equatable {
        let id: String
        let tool: ToolIdentity

        var name: String { tool.rawName }

        /// The one-line subject — the command, the path, the query. Shared with the permission
        /// card, because what identifies a call is the same question in both places.
        let summary: String

        /// Present only for tools that change a file. Built from the call's own arguments, so
        /// it is known before the tool runs and the result merely confirms it landed.
        let diff: [DiffLine]?

        var result: Result?

        struct Result: Equatable {
            let text: String
            let isError: Bool

            /// Whether the text was cut to `ConversationDefaults.toolResultLimit`.
            let isTruncated: Bool
        }
    }

    /// One exchange: what was asked, and what the agent finally said about it.
    ///
    /// A conversation's *structure* is its turns, not its rows — the rows in between are how a
    /// turn was carried out. This is what the minimap indexes and what any "jump to the
    /// previous turn" navigation moves between.
    struct Turn: Equatable {
        /// Index into `rows` of the user message that opened it, so a view can scroll to it.
        let rowIndex: Int

        let userText: String

        /// The *last* assistant message before the next user turn — the conclusion rather than
        /// the thinking-aloud on the way there. Nil while a turn is still in flight.
        let assistantText: String?
    }

    /// What the composer reports. Distinct from the row list: it describes the session, not
    /// the conversation, and nothing in the transcript records it.
    enum Status: Equatable {
        case loading
        case ready(model: String?)
        case working
        case thinking
        case ended(code: Int32)
    }

    /// The minimum a view must do to catch up with an event.
    enum Change: Equatable {
        case appended(index: Int)

        /// The row at this index gained its result and should be refreshed in place.
        case resultAttached(index: Int)

        /// The in-progress text, or nil to drop the placeholder because the finished message
        /// that replaces it has arrived.
        case streaming(String?)

        case status(Status)

        /// The identifier the CLI settled on, which for a resume is not necessarily the one we
        /// asked for.
        case adoptedSessionID(TranscriptID)
    }

    // MARK: - Properties

    private(set) var rows: [Row] = []

    /// Text accumulated from deltas since the last finished message.
    private(set) var streamingText: String = ""

    /// Row index of each tool call still waiting for its result, keyed by the provider's id.
    ///
    /// Entries are removed as results land, so a second result for the same id — which Codex
    /// does emit when a command is retried — appends rather than overwriting silently.
    private var pendingToolRows: [String: Int] = [:]

    private let sessionID: SessionID

    // MARK: - Initialization

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }

    // MARK: - Public Methods

    /// Folds one event in, returning what a view must do to match.
    mutating func apply(_ event: StreamEvent) -> [Change] {
        switch event {
        case .initialised(let agentSessionID, let model):
            var changes: [Change] = []
            if let agentSessionID {
                changes.append(.adoptedSessionID(agentSessionID))
            }
            // Codex reports `thread.started` at the head of every one-shot turn, so this fires
            // mid-conversation too. Only a reported model promotes the status — calling it
            // Ready unconditionally would overwrite Working while the model is still running.
            if let model {
                changes.append(.status(.ready(model: model)))
            }
            return changes

        case .userMessage(let text):
            return [append(.userMessage(text))]

        case .textDelta(let text):
            streamingText += text
            return [.streaming(streamingText)]

        case .thinkingDelta:
            // Reasoning is streamed but not shown as it arrives: it needs a fold to sit behind,
            // and it lands complete in the finished message anyway.
            return [.status(.thinking)]

        case .assistantMessage(let blocks):
            var changes: [Change] = clearStreaming()
            for block in blocks {
                changes.append(contentsOf: apply(block))
            }
            return changes

        case .toolResults(let results):
            return results.map { attach($0) }

        case .turnFinished(let text, let isError):
            var changes = clearStreaming()
            // Only a failed turn is reported. A successful one's text is the assistant message
            // already rendered, and showing it twice reads as the agent repeating itself.
            if isError, let text, !text.isEmpty {
                changes.append(append(.notice(text, kind: .error)))
            }
            changes.append(.status(.ready(model: nil)))
            return changes

        case .unknown:
            return []
        }
    }

    /// The conversation's exchanges, in order.
    ///
    /// Derived rather than accumulated: turns are a *view* of the rows, and keeping a second
    /// list in step with the first through every append and result-attachment would be the
    /// bug this type was written to avoid. Conversations are hundreds of rows, not millions.
    var turns: [Turn] {
        var turns: [Turn] = []

        for (index, row) in rows.enumerated() {
            guard case .userMessage(let text) = row else { continue }
            let compacted = Self.compact(text)
            guard !compacted.isEmpty else { continue }

            turns.append(Turn(
                rowIndex: index,
                userText: compacted,
                assistantText: finalAssistantText(after: index)
            ))
        }

        return turns
    }

    /// The last assistant message between this user turn and the next.
    private func finalAssistantText(after userIndex: Int) -> String? {
        var latest: String?

        for row in rows[rows.index(after: userIndex)...] {
            switch row {
            case .userMessage:
                return latest
            case .assistant(let markdown):
                let compacted = Self.compact(markdown)
                if !compacted.isEmpty { latest = compacted }
            default:
                continue
            }
        }

        return latest
    }

    /// Collapses whitespace, so a preview of a markdown message is one readable line rather
    /// than a paragraph with its line breaks still in it.
    private static func compact(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Appends a standalone note — used for the replay truncation banner and for exit reports,
    /// which are the view's to raise rather than the stream's.
    mutating func appendNotice(_ text: String, kind: NoticeKind) -> Change {
        append(.notice(text, kind: kind))
    }

    // MARK: - Private Methods

    private mutating func apply(_ block: ContentBlock) -> [Change] {
        switch block {
        case .text(let text) where !text.isEmpty:
            return [append(.assistant(markdown: text))]

        case .thinking(let text) where !text.isEmpty:
            return [append(.thinking(text))]

        case .toolUse(let id, let tool, let input):
            let request = PermissionRequest(sessionID: sessionID, tool: tool, input: input)
            let call = ToolCall(
                id: id,
                tool: tool,
                summary: request.oneLineSummary,
                diff: EditDiff.lines(forTool: tool.rawName, input: input),
                result: nil
            )
            let change = append(.toolCall(call))
            pendingToolRows[id] = rows.count - 1
            return [change]

        default:
            // An empty text block, which both CLIs emit around tool calls.
            return []
        }
    }

    private mutating func attach(_ result: ToolResult) -> Change {
        let limit = ConversationDefaults.toolResultLimit
        let isTruncated = result.text.count > limit
        let text = isTruncated ? String(result.text.prefix(limit)) + "\n…" : result.text

        guard let index = pendingToolRows.removeValue(forKey: result.toolUseID),
              case .toolCall(var call) = rows[index] else {
            // A result whose call is not in the window — the usual cause is a replay cap that
            // cut between the two — is still shown rather than dropped, quietly.
            return append(.notice(text, kind: .muted))
        }

        call.result = ToolCall.Result(text: text, isError: result.isError, isTruncated: isTruncated)
        rows[index] = .toolCall(call)
        return .resultAttached(index: index)
    }

    private mutating func clearStreaming() -> [Change] {
        guard !streamingText.isEmpty else { return [] }
        streamingText = ""
        return [.streaming(nil)]
    }

    private mutating func append(_ row: Row) -> Change {
        rows.append(row)
        return .appended(index: rows.count - 1)
    }
}

// MARK: - Equatable

extension DiffLine: Equatable {
    static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }
}
