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
            return .work
        case .toolCall(let call):
            // A chart is part of the answer, and is drawn as one — see `make(for:)`.
            if call.chart != nil, call.result?.outcome != .failed { return .answer }
            return .work
        case .turnOutcome, .notice:
            return .chrome
        }
    }
}
