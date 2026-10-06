#if os(Linux)
import AppKit
import Foundation
@testable import CoreSlice

/// Feeds the shared conversation rows from a live child speaking stream-json.
///
/// The child, the production `AgentStreamTransport`, `StreamEvent.parse` and
/// `ConversationTimeline` are the real path; what is diagnostic is the projection. Assistant
/// Markdown blocks, the streaming tail and successful edit diffs become rows. User messages,
/// other tool calls and turn outcomes stay in the timeline without a mounted row, because the
/// production transcript row kinds for them are not compiled for Linux yet.
@MainActor
final class StreamConversationDriver {
    private enum Defaults {
        static let maximumErrorBytes = 64 * 1_024
        static let exitDeadline: TimeInterval = 5
    }

    private let process = Process()
    /// Set once in `init`, after every other property, so its callbacks can hold `self` weakly.
    private var transport: AgentStreamTransport<StreamLineParseResult>!
    private var timeline = ConversationTimeline(sessionID: SessionID(), chartDecoder: { _, _ in nil })
    private let rows: DocumentRowSource
    private let table: NSTableView

    /// Advances whenever anything visible or reported changed; the window repaints on it.
    private(set) var revision = 0
    private(set) var lines = 0
    private(set) var malformedLines = 0
    private(set) var settledTurns = 0
    private(set) var streamingUpdates = 0
    private(set) var longestStreamingText = 0
    private(set) var lastOutcome: String?
    private(set) var model: String?
    private(set) var failure: String?
    private(set) var exitStatus: Int32?
    private(set) var diagnostic: String?
    var timelineRows: Int { timeline.rows.count }
    var isStreaming: Bool { rows.streamingIndex != nil }

    init(arguments: [String], rows: DocumentRowSource, table: NSTableView) throws {
        guard let executable = arguments.first else {
            throw WindowFailure("usage: WindowHarness --stream-ui-fixture OUTPUT AGENT [ARGUMENTS...]")
        }
        self.rows = rows
        self.table = table
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        transport = AgentStreamTransport(
            label: "codes.threading.linux.stream-fixture",
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            error: error.fileHandleForReading,
            maximumErrorBytes: Defaults.maximumErrorBytes,
            parser: { StreamEvent.parse(String(decoding: $0, as: UTF8.self)) },
            onLine: { [weak self] in self?.receive($0) },
            onMalformedLine: { [weak self] in
                self?.malformedLines += 1
                self?.revision += 1
            },
            onFailure: { [weak self] in
                self?.failure = $0.userFacingDescription
                self?.revision += 1
            })
        transport.start()
        try process.run()
    }

    /// Sends one user turn in the CLI's stream-json input shape.
    func send(_ prompt: String) {
        apply(timeline.apply(.userMessage(prompt)))
        let accepted = transport.writeJSONObject([
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": prompt]]],
        ])
        if !accepted { failure = "the agent transport refused a turn" }
        revision += 1
    }

    /// Closes stdin, waits for the child to leave, and keeps the bounded stderr diagnostic.
    func close() async {
        transport.closeInput()
        let deadline = Date().addingTimeInterval(Defaults.exitDeadline)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if process.isRunning { process.terminate() }
        while process.isRunning { try? await Task.sleep(nanoseconds: 10_000_000) }
        exitStatus = process.terminationStatus
        var captured: String?
        transport.finish { captured = $0 }
        while captured == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        diagnostic = captured
        transport.detach()
    }

    private func receive(_ result: StreamLineParseResult) {
        lines += 1
        guard case .events(let events) = result else {
            malformedLines += 1
            revision += 1
            return
        }
        for event in events {
            if case .initialised(_, let reported) = event { model = reported }
            apply(timeline.apply(event))
        }
        revision += 1
    }

    private func apply(_ changes: [ConversationTimeline.Change]) {
        for change in changes {
            switch change {
            case .streaming(let text):
                let visible = text.flatMap { $0.isEmpty ? nil : $0 }
                if let visible {
                    streamingUpdates += 1
                    longestStreamingText = max(longestStreamingText, visible.count)
                }
                rows.setStreaming(visible, in: table)
            case .appended(let index):
                guard timeline.rows.indices.contains(index) else { continue }
                if case .assistant(let markdown) = timeline.rows[index] {
                    rows.appendBlocks(Markdown.sourceBlocks(markdown), in: table)
                }
            case .resultAttached(let index):
                guard timeline.rows.indices.contains(index),
                      case .toolCall(let call) = timeline.rows[index],
                      call.result?.outcome == .succeeded, let diff = call.diff else { continue }
                rows.appendDiff(diff, in: table)
            case .turnSettled(_, let outcome):
                settledTurns += 1
                lastOutcome = String(describing: outcome)
            default:
                continue
            }
        }
    }
}
#endif
