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
        case userMessage(ConversationUserMessage)
        case assistant(markdown: String)
        case thinking(String)
        case toolCall(ToolCall)

        /// Neither said nor tool output: a truncation note, a failed turn, an orphan result.
        case notice(String, kind: NoticeKind)

        /// Keeps existing fixtures and provider adapters terse while the associated value carries
        /// structured context for the paths that have it.
        static func userMessage(_ text: String) -> Row {
            .userMessage(ConversationUserMessage(text: text))
        }
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

            /// Settled once, when the result attaches — `isError` plus the text sniff, so the
            /// view never re-derives it and live and replay cannot disagree.
            let outcome: ToolOutcome
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

        /// Index of the last row belonging to this turn — the row before the next user
        /// message, or the newest row for the turn still in flight.
        let endIndex: Int

        /// Index of the final assistant message — the row a fold keeps visible. Nil for a
        /// turn that produced no text reply.
        let finalAssistantIndex: Int?

        let userText: String

        /// The *last* assistant message before the next user turn — the conclusion rather than
        /// the thinking-aloud on the way there. Nil while a turn is still in flight.
        let assistantText: String?

        /// How long the turn ran, retained from its terminal event. Nil while in flight, and
        /// for replayed transcripts whose records carried no usable timestamps.
        let duration: TimeInterval?
    }

    /// What the composer reports. Distinct from the row list: it describes the session, not
    /// the conversation, and nothing in the transcript records it.
    enum Status: Equatable {
        case loading
        case ready(model: String?, lastTurn: TurnMetrics?)

        /// A turn in flight, carrying the word the status line shows for it. The word is drawn
        /// by whoever starts the turn and travels with the status so it cannot be re-drawn on
        /// the way to being displayed — see `WorkingWords` for why it must not change mid-turn.
        case working(word: String)

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

        /// The latest plan reported during the turn, reduced to its current position. Nil
        /// clears a plan whose provider explicitly replaced it with an empty list.
        case runProgress(RunProgress?)

        /// The turn that opened at this row index finished. `interrupted` marks one that was
        /// stopped or failed rather than completed — the view folds a settled turn, but an
        /// interrupted one stays expanded so the user keeps their place; the next turn folds it.
        case turnSettled(startIndex: Int, interrupted: Bool)

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

    /// Stateful because current Claude releases create and update one task at a time. Codex and
    /// legacy Claude snapshots pass through the same reducer, so replay cannot diverge from live.
    private var runProgressReducer = RunProgressReducer()

    /// Durations reported by each turn's terminal event, keyed by the row index of the user
    /// message that opened the turn. Kept beside `rows` rather than on a parallel turn list —
    /// a duration is a fact only the event stream carries, and row indices never move.
    private var turnDurations: [Int: TimeInterval] = [:]

    /// Stable turn identities and their one-line preview text. Rows never move, and message text
    /// never changes after append, so compacting the same historical Markdown on every minimap
    /// refresh is pure duplicate work. The turn's extent remains derived from `rows`; these
    /// mirrors cache only the immutable identity/text transformation.
    private var turnStartIndices: [Int] = []
    private var compactedUserTextByRow: [Int: String] = [:]
    private var compactedAssistantTextByRow: [Int: String] = [:]

    /// Row index of the user message that opened the turn currently in flight, so its
    /// terminal event can be attributed to it.
    private var currentTurnStartIndex: Int?

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
            // A transport can restate the active thread while resuming or reconnecting, so this
            // may fire mid-conversation too. Only a reported model promotes the status — calling
            // it Ready unconditionally would overwrite Working while the model is still running.
            if let model {
                changes.append(.status(.ready(model: model, lastTurn: nil)))
            }
            return changes

        case .userMessage(let text):
            let message = ConversationPrompt.replaying(text)
            let change = append(.userMessage(message))
            let index = rows.count - 1
            turnStartIndices.append(index)
            compactedUserTextByRow[index] = Self.compact(message.text)
            currentTurnStartIndex = index
            return [change]

        case .transcriptNotice(let text):
            return [append(.notice(text, kind: .muted))]

        case .textDelta(let text):
            streamingText += text
            return [.streaming(streamingText)]

        case .thinkingDelta:
            // Reasoning is streamed but not shown as it arrives: it needs a fold to sit behind,
            // and it lands complete in the finished message anyway.
            //
            // It no longer moves the status either. Providers do not all stream these at the
            // same cadence, so a status raised here described the same wait differently per
            // transport; the turn already said it was working when it started, and it still is.
            return []

        case .assistantMessage(let blocks):
            var changes: [Change] = clearStreaming()
            for block in blocks {
                changes.append(contentsOf: apply(block))
            }
            return changes

        case .toolResults(let results):
            var changes: [Change] = []
            for result in results {
                changes.append(attach(result))
                append(runProgressReducer.apply(result: result), to: &changes)
            }
            return changes

        case .runPlanUpdated(let steps):
            var changes: [Change] = []
            append(runProgressReducer.apply(plan: steps), to: &changes)
            return changes

        case .turnFinished(let text, let isError, let metrics):
            var changes = clearStreaming()
            changes.append(contentsOf: settleUnansweredToolCalls())
            if let text, !text.isEmpty {
                if isError {
                    changes.append(append(.notice(text, kind: .error)))
                } else if !hasAssistantMessageInCurrentTurn {
                    // Session commands such as Claude's /context return their useful output only
                    // on the terminal result event. Ordinary model turns already emitted an
                    // assistant message, so this fills the command-only shape without repeating
                    // a normal answer.
                    changes.append(append(.assistant(markdown: text)))
                    compactedAssistantTextByRow[rows.count - 1] = Self.compact(text)
                }
            }
            if let startIndex = currentTurnStartIndex {
                if let duration = metrics.duration {
                    turnDurations[startIndex] = duration
                }
                changes.append(.turnSettled(startIndex: startIndex, interrupted: isError))
                currentTurnStartIndex = nil
            }
            changes.append(.status(.ready(
                model: nil,
                lastTurn: metrics.isEmpty ? nil : metrics
            )))
            return changes

        case .backgroundWork:
            // Nothing to draw. It says whether the *session* has finished, which is the
            // sidebar's question and the notification's, not a row in the conversation.
            return []

        case .unknown:
            return []
        }
    }

    /// The conversation's exchanges, in order. Stable user-row identities and compacted preview
    /// strings are cached when their immutable source arrives; extent, conclusion and duration
    /// remain derived from the canonical rows so result attachment has no parallel turn model to
    /// keep in step.
    var turns: [Turn] {
        turnStartIndices.compactMap { turn(startingAt: $0) }
    }

    /// Derives one known turn without rebuilding every earlier exchange. A settle change already
    /// carries its opening row, so replay folding should pay for that turn's rows only.
    func turn(startingAt index: Int) -> Turn? {
        guard rows.indices.contains(index),
              case .userMessage = rows[index] else { return nil }
        let compacted = compactedUserTextByRow[index] ?? ""
        guard !compacted.isEmpty else { return nil }

        let conclusion = finalAssistant(after: index)
        return Turn(
            rowIndex: index,
            endIndex: conclusion.endIndex,
            finalAssistantIndex: conclusion.index,
            userText: compacted,
            assistantText: conclusion.text,
            duration: turnDurations[index]
        )
    }

    /// The last assistant message between this user turn and the next, with where the turn's
    /// rows end. Any user row is a boundary, even one whose text compacts to nothing.
    private func finalAssistant(
        after userIndex: Int
    ) -> (index: Int?, text: String?, endIndex: Int) {
        var latest: (index: Int?, text: String?) = (nil, nil)
        var endIndex = userIndex

        for index in rows.indices[rows.index(after: userIndex)...] {
            switch rows[index] {
            case .userMessage:
                return (latest.index, latest.text, endIndex)
            case .assistant(let markdown):
                let compacted = compactedAssistantTextByRow[index] ?? Self.compact(markdown)
                if !compacted.isEmpty { latest = (index, compacted) }
                endIndex = index
            default:
                endIndex = index
            }
        }

        return (latest.index, latest.text, endIndex)
    }

    private var hasAssistantMessageInCurrentTurn: Bool {
        guard let start = currentTurnStartIndex, start + 1 < rows.count else { return false }
        return rows[(start + 1)...].contains { row in
            if case .assistant = row { return true }
            return false
        }
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

    /// Local turns already have their typed context, so they enter without a serialize/parse
    /// round-trip. Replayed provider text takes the `StreamEvent.userMessage` path above.
    mutating func appendUserMessage(_ message: ConversationUserMessage) -> Change {
        let change = append(.userMessage(message))
        let index = rows.count - 1
        turnStartIndices.append(index)
        compactedUserTextByRow[index] = Self.compact(message.text)
        currentTurnStartIndex = index
        return change
    }

    // MARK: - Private Methods

    private mutating func apply(_ block: ContentBlock) -> [Change] {
        switch block {
        case .text(let text) where !text.isEmpty:
            let change = append(.assistant(markdown: text))
            compactedAssistantTextByRow[rows.count - 1] = Self.compact(text)
            return [change]

        case .thinking(let text) where !text.isEmpty:
            return [append(.thinking(text))]

        case .toolUse(let id, let tool, let input):
            let foundationInput = input.mapValues(\.foundationValue)
            let request = PermissionRequest(
                sessionID: sessionID,
                tool: tool,
                input: input
            )
            let call = ToolCall(
                id: id,
                tool: tool,
                summary: request.oneLineSummary,
                diff: EditDiff.lines(forTool: tool.rawName, input: foundationInput),
                result: nil
            )
            let change = append(.toolCall(call))
            pendingToolRows[id] = rows.count - 1
            var changes = [change]
            append(
                runProgressReducer.apply(toolUseID: id, tool: tool, input: foundationInput),
                to: &changes
            )
            return changes

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

        call.result = ToolCall.Result(
            text: text,
            isError: result.isError,
            isTruncated: isTruncated,
            outcome: ToolOutcome.classify(text: text, isError: result.isError, tool: call.tool)
        )
        rows[index] = .toolCall(call)
        return .resultAttached(index: index)
    }

    /// A turn that ends with calls still unanswered would leave them reading "running…"
    /// forever — ambiguity is temporary, not permanent. They settle as interrupted, but stay
    /// in the pending map: a result that does arrive late still attaches over the placeholder.
    private mutating func settleUnansweredToolCalls() -> [Change] {
        var changes: [Change] = []
        for index in pendingToolRows.values.sorted() {
            guard case .toolCall(var call) = rows[index], call.result == nil else { continue }
            call.result = ToolCall.Result(
                text: "",
                isError: false,
                isTruncated: false,
                outcome: .interrupted
            )
            rows[index] = .toolCall(call)
            changes.append(.resultAttached(index: index))
        }
        return changes
    }

    private func append(
        _ update: RunProgressReducer.Update,
        to changes: inout [Change]
    ) {
        guard case .changed(let progress) = update else { return }
        changes.append(.runProgress(progress))
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
