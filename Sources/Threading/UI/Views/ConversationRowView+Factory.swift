import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

// MARK: - Conversation Row Presentation

/// The chronological units a compact transcript draws.
///
/// The timeline deliberately retains every tool call as a first-class row. Compact surfaces
/// can reduce only adjacent calls into a disclosure without losing their position among the
/// agent's prose or changing the canonical conversation model.
enum ConversationRowPresentation {
    enum Item: Equatable {
        case row(ConversationTimeline.Row)
        case toolCalls([ConversationTimeline.ToolCall])
    }

    static func compact(_ rows: [ConversationTimeline.Row]) -> [Item] {
        var result: [Item] = []
        var calls: [ConversationTimeline.ToolCall] = []

        func flushCalls() {
            guard !calls.isEmpty else { return }
            result.append(.toolCalls(calls))
            calls.removeAll(keepingCapacity: true)
        }

        for row in rows {
            if case .toolCall(let call) = row {
                calls.append(call)
            } else {
                flushCalls()
                result.append(.row(row))
            }
        }
        flushCalls()
        return result
    }
}

// MARK: - Tool Run Summary

/// What a run of tool calls did, in the words a reader would use: "Read 3 files, ran 1 command".
///
/// A count of calls says only that something happened. Grouped by what each call is rather than
/// by what its command says, so a shell command mentioning tests is a command and not a test run.
struct ToolRunSummary {
    /// One kind of work. Compared by case, in the order the run first did each kind.
    private enum Activity: Equatable {
        case read, edit, search, command, fetch, agent, plan, other

        init(_ tool: ToolIdentity) {
            switch tool {
            case .read, .notebookRead: self = .read
            case .write, .edit, .multiEdit, .notebookEdit: self = .edit
            case .glob, .grep, .webSearch: self = .search
            case .bash: self = .command
            case .webFetch: self = .fetch
            case .task: self = .agent
            case .todoWrite, .todoRead, .taskCreate, .taskUpdate, .taskList, .taskGet, .plan:
                self = .plan
            case .toolSearch, .mcp, .unknown: self = .other
            }
        }

        /// Reading one file twice is still one file read, so these count their distinct subjects.
        var countsSubjects: Bool { self == .read || self == .edit }

        func label(count: Int) -> String {
            let number = Int64(count)
            switch self {
            case .read:
                return count == 1 ? L10n.string("Read 1 file") : L10n.format("Read %lld files", number)
            case .edit:
                return count == 1 ? L10n.string("Edited 1 file") : L10n.format("Edited %lld files", number)
            case .search:
                return count == 1 ? L10n.string("Searched once") : L10n.format("Searched %lld times", number)
            case .command:
                return count == 1 ? L10n.string("Ran 1 command") : L10n.format("Ran %lld commands", number)
            case .fetch:
                return count == 1 ? L10n.string("Fetched 1 page") : L10n.format("Fetched %lld pages", number)
            case .agent:
                return count == 1 ? L10n.string("Started 1 agent") : L10n.format("Started %lld agents", number)
            case .plan:
                return L10n.string("Updated the plan")
            case .other:
                return count == 1 ? L10n.string("Used 1 tool") : L10n.format("Used %lld tools", number)
            }
        }
    }

    /// The whole run as one phrase. Later clauses are lowercased so it reads as one sentence; none
    /// of these strings holds a name a lowercase would damage.
    let text: String

    /// How many of the calls failed, worded, or nil when none did. A fold hides its rows, so this
    /// is the only place a failure inside one can be seen.
    let attention: String?

    init<Calls: Sequence>(calls: Calls) where Calls.Element == ConversationTimeline.ToolCall {
        var order: [Activity] = []
        var counts: [Int] = []
        var subjects: [Set<String>] = []
        var failures = 0
        for call in calls {
            let activity = Activity(call.tool)
            let slot: Int
            if let existing = order.firstIndex(of: activity) {
                slot = existing
            } else {
                slot = order.count
                order.append(activity)
                counts.append(0)
                subjects.append([])
            }
            counts[slot] += 1
            if activity.countsSubjects, !call.summary.isEmpty { subjects[slot].insert(call.summary) }
            if call.result?.outcome == .failed { failures += 1 }
        }
        let clauses = order.enumerated().map { slot, activity -> String in
            let count = activity.countsSubjects && !subjects[slot].isEmpty
                ? subjects[slot].count
                : counts[slot]
            let label = activity.label(count: count)
            return slot == 0 ? label : label.localizedLowercase
        }
        text = clauses.joined(separator: ", ")
        attention = failures > 0 ? L10n.format("%lld failed", Int64(failures)) : nil
    }
}

// MARK: - Conversation Row Factory

/// Which leaf, or which heavier view, each timeline row kind becomes. Kept apart from the
/// leaf builders so a host without tool cards or charts can link the leaves alone.
extension ConversationRowView {

    /// The view for a row, and whether it opens a new exchange.
    ///
    /// `startsTurn` is the row's own property rather than the caller's guess: what deserves
    /// space above it is a user turn beginning, which only the row kind knows.
    static func make(
        for row: ConversationTimeline.Row,
        preparedPages: [[String]]? = nil
    ) -> (view: NSView, startsTurn: Bool) {
        switch row {
        case .userMessage(let message):
            return (userBubble(message.text), true)

        case .assistant(let markdown):
            let view = preparedPages.map { MarkdownView(preparedPages: $0) }
                ?? MarkdownView(markdown: markdown)
            return (view, false)

        case .thinking(let text):
            let view: NSView
            if let preparedPages { view = MarkdownView(preparedPages: preparedPages, style: .thinking) }
            else { view = thinking(text) }
            return (view, false)

        case .turnOutcome(let outcome):
            return (turnOutcome(outcome), false)

        case .notice(let text, let kind):
            return (notice(text, kind: kind), false)

        case .toolCall(let call):
            // A chart call draws its chart rather than a line saying a chart was drawn. The
            // result still matters when it failed, so a refused call falls back to the ordinary
            // tool row and shows what the panel said about it.
            if let spec = call.chart, call.result?.outcome != .failed {
                #if !os(Linux)
                return (ChartCardView(spec: spec), false)
                #else
                // The Linux host has no chart canvas yet; keep the tool and its result legible.
                _ = spec
                #endif
            }
            let view = ToolCallView(tool: call.tool, summary: call.summary, diff: call.diff)
            if let result = call.result {
                view.setResult(result.text, outcome: result.outcome)
            }
            return (view, false)
        }
    }

    /// A row's vertical rhythm, declared beside its view so the two cannot drift. The table
    /// composes neighbouring rhythms with `Design.Chat.Rhythm.gap(between:and:)`.
    static func rhythm(for row: ConversationTimeline.Row) -> Design.Chat.Rhythm {
        switch row {
        case .userMessage:
            return .exchange
        case .assistant:
            return .answer
        case .thinking:
            // A thought opens a step exactly as a sentence does; only its ink says it is an aside.
            return .answer
        case .toolCall(let call):
            // A chart is part of the answer, and is drawn as one — see `make(for:)`.
            if call.chart != nil, call.result?.outcome != .failed { return .answer }
            return .work
        case .turnOutcome, .notice:
            return .chrome
        }
    }
}
