import Foundation

// MARK: - Handoff Budget

/// What a cross-provider handoff keeps of a conversation, in characters.
///
/// The budget is dialogue-first, and every number here was set against one real handoff. A Codex
/// session of 21 user turns and 302 tool calls was continued with Claude; the snapshot held the
/// newest 400 events — every one a tool call or its output — in 992k characters, and not one
/// user message. The destination read all 24 pages before answering: 626k tokens of context at
/// the peak and 12.5 million cache-read tokens over five minutes, on a 1M-context model that was
/// the only reason it finished. The same conversation's whole dialogue was 26k characters.
///
/// So the dialogue is kept whole until it alone would not fit, tool calls survive as the one-line
/// subject the collapsed row shows, and tool output is kept only for the turns the destination
/// is about to continue. The whole snapshot fits in three `ConversationHistoryPage` pages.
enum ConversationHandoffBudget {
    /// The whole snapshot, about 32k tokens. Also bounds a prior snapshot prepended on a repeated
    /// handoff and a legacy snapshot read through `TranscriptReplay`.
    static let snapshotCharacterLimit = 128_000

    /// User and assistant text plus transcript notices, newest kept when over.
    static let dialogueCharacterLimit = 96_000

    /// One tool call becomes one line: its tool name and subject, cut with an ellipsis.
    static let toolCallSummaryCharacterLimit = 200
    static let toolCallSummaryBudget = 20_000

    /// Tool output is kept only for the newest turns, and each result is cut to this.
    static let toolResultCharacterLimit = 2_000
    static let toolResultBudget = 12_000
    static let toolResultTurns = 2

    /// The bootstrap that opens a continued session. Recognised on a second handoff so the
    /// transport that carried the first one is not copied along as conversation.
    static let bootstrapMarker = "Threading cross-provider continuation bootstrap"
}

// MARK: - Handoff Reducer

/// Reduces a conversation's events to the segments a handoff snapshot stores, inside
/// `ConversationHandoffBudget`, in one pass and bounded memory.
///
/// Events arrive in order and segments leave in order; budgets are enforced as items arrive by
/// evicting the oldest item of the same kind, so the reducer never holds more than the budget
/// plus one item per kind however long the transcript is. Tool results also leave when their
/// turn falls out of the retained window, which happens as soon as a newer user turn begins.
struct ConversationHandoffReducer {

    // MARK: - Types

    enum SegmentKind: Hashable {
        case dialogue
        case toolCall
        case toolResult

        var budget: Int {
            switch self {
            case .dialogue: return ConversationHandoffBudget.dialogueCharacterLimit
            case .toolCall: return ConversationHandoffBudget.toolCallSummaryBudget
            case .toolResult: return ConversationHandoffBudget.toolResultBudget
            }
        }
    }

    private struct Item {
        let kind: SegmentKind
        let turn: Int
        let text: String
    }

    // MARK: - Properties

    private var items: [Item] = []
    private var characters: [SegmentKind: Int] = [:]
    private var turn = 0
    private var didDropDialogue = false
    private var handoffToolUseIDs: Set<String> = []
    private let dropsHandoffTransport: Bool

    private(set) var userMessageCount = 0
    private(set) var assistantMessageCount = 0

    /// The retained segments, oldest first.
    var segments: [String] { items.map(\.text) }

    /// Whether dialogue was dropped to fit. Trimmed tool context is the design, not a truncation,
    /// so it does not set this; the page payload's `replay_window_truncated` means what it says.
    var wasTruncated: Bool { didDropDialogue }

    var hasDialogue: Bool { userMessageCount + assistantMessageCount > 0 }

    // MARK: - Initialization

    /// `dropsHandoffTransport` is true when the source is itself a continuation: its opening
    /// bootstrap and the `conversation_history` exchange that answered it are transport, and the
    /// prior snapshot they carried is prepended separately by the capture.
    init(dropsHandoffTransport: Bool) {
        self.dropsHandoffTransport = dropsHandoffTransport
    }

    // MARK: - Public Methods

    mutating func consume(_ event: StreamEvent) {
        switch event {
        case .userMessage(let text):
            if dropsHandoffTransport,
               text.localizedCaseInsensitiveContains(ConversationHandoffBudget.bootstrapMarker) {
                return
            }
            beginTurn()
            userMessageCount += 1
            append(.dialogue, ConversationHistoryPage.segments(label: "[USER]", content: text))

        case .assistantMessage(let blocks):
            for block in blocks {
                switch block {
                case .text(let text):
                    assistantMessageCount += 1
                    append(
                        .dialogue,
                        ConversationHistoryPage.segments(label: "[ASSISTANT]", content: text)
                    )

                case .thinking:
                    // Private reasoning is neither visible dialogue nor portable context.
                    continue

                case .toolUse(let id, let tool, let input):
                    if dropsHandoffTransport,
                       tool.rawName.localizedCaseInsensitiveContains(
                           MCPBuiltInTool.conversationHistory.rawValue
                       ) {
                        handoffToolUseIDs.insert(id)
                        continue
                    }
                    append(.toolCall, [Self.toolCallSummary(tool: tool, input: input)])
                }
            }

        case .toolResults(let results):
            for result in results where !handoffToolUseIDs.contains(result.toolUseID) {
                append(.toolResult, ConversationHistoryPage.segments(
                    label: result.isError ? "[TOOL RESULT: ERROR]" : "[TOOL RESULT]",
                    content: ConversationHistoryPage.bounded(
                        result.text,
                        limit: ConversationHandoffBudget.toolResultCharacterLimit
                    )
                ))
            }

        case .transcriptNotice(let text):
            append(
                .dialogue,
                ConversationHistoryPage.segments(label: "[TRANSCRIPT NOTICE]", content: text)
            )

        case .initialised, .textDelta, .thinkingDelta, .runPlanUpdated, .backgroundWork,
             .turnFinished, .unknown:
            return
        }
    }

    /// One line per call: the tool's own subject line — the same one the collapsed row and the
    /// search index show — under the label the page format has always used for a call.
    static func toolCallSummary(tool: ToolIdentity, input: [String: JSONValue]) -> String {
        let summary = PermissionRequest(sessionID: SessionID(), tool: tool, input: input)
            .oneLineSummary
        let line = summary.isEmpty
            ? ConversationHistoryPage.jsonString(input.mapValues(\.foundationValue))
            : summary
        return "[ASSISTANT TOOL CALL: \(tool.rawName)]\n"
            + excerpt(line, limit: ConversationHandoffBudget.toolCallSummaryCharacterLimit)
    }

    // MARK: - Private Methods

    private mutating func beginTurn() {
        turn += 1
        let oldestRetainedTurn = turn - ConversationHandoffBudget.toolResultTurns + 1
        evict { $0.kind == .toolResult && $0.turn < oldestRetainedTurn }
    }

    private mutating func append(_ kind: SegmentKind, _ segments: [String]) {
        for text in segments {
            items.append(Item(kind: kind, turn: turn, text: text))
            characters[kind, default: 0] += text.count
        }
        trim(kind)
    }

    /// Drops the oldest items of one kind until that kind is inside its budget. The newest item
    /// always survives, so one oversized segment cannot empty its own kind.
    private mutating func trim(_ kind: SegmentKind) {
        while characters[kind, default: 0] > kind.budget,
              let oldest = items.firstIndex(where: { $0.kind == kind }),
              oldest != items.lastIndex(where: { $0.kind == kind }) {
            characters[kind, default: 0] -= items[oldest].text.count
            items.remove(at: oldest)
            if kind == .dialogue { didDropDialogue = true }
        }
    }

    private mutating func evict(where predicate: (Item) -> Bool) {
        items.removeAll { item in
            guard predicate(item) else { return false }
            characters[item.kind, default: 0] -= item.text.count
            return true
        }
    }

    private static func excerpt(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }
}
