import Foundation
#if os(Linux)
@testable import CoreSlice
#else
@testable import Threading
#endif

private enum ConversationContractFailure: Error { case failed(String) }

private func requireConversation(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ConversationContractFailure.failed(message) }
}

func runConversationContracts() throws {
    let foundation = try JSONSerialization.jsonObject(with: Data(
        #"{"flag":true,"zero":0,"largest":9223372036854775807,"overflow":9223372036854775808}"#.utf8
    )) as! [String: Any]
    let values = JSONValue.convertingObject(from: foundation)
    try requireConversation(values["flag"] == .bool(true), "JSON boolean identity")
    try requireConversation(values["zero"] == .integer(0), "JSON integer zero must not become false")
    try requireConversation(values["largest"] == .integer(Int64.max), "exact Int64 boundary")
    if case .integer = values["overflow"] { throw ConversationContractFailure.failed("overflowing wire integer wrapped") }

    var timeline = ConversationTimeline(sessionID: SessionID(), chartDecoder: { _, _ in nil })
    try requireConversation(timeline.apply(.userMessage("Inspect **Unicode** é 👩🏽‍🚀")) == [.appended(index: 0)],
                "user append identity")
    let streamed = timeline.apply(.textDelta("A partial reply"))
    try requireConversation(streamed == [.streaming("A partial reply")], "incremental streaming change")
    _ = timeline.apply(.assistantMessage(blocks: [
        .toolUse(id: "shell-1", tool: .bash, input: ["command": .string("printf 'hello'\nprintf 'world'")]),
        .toolUse(id: "edit-1", tool: .edit, input: [
            "file_path": .string("/tmp/Example.swift"), "old_string": .string("old"), "new_string": .string("new")
        ])
    ]))
    guard case .toolCall(let shell) = timeline.rows[1], case .toolCall(let edit) = timeline.rows[2] else {
        throw ConversationContractFailure.failed("tool rows lost their identity")
    }
    try requireConversation(shell.summary == "printf 'hello' …", "shared tool subject reduction")
    try requireConversation(edit.fileChanges.count == 1 && edit.diff?.contains { $0.kind == .added } == true,
                "NativeDiffCore edit projection")
    let attached = timeline.apply(.toolResults([.init(toolUseID: "shell-1", text: "hello", isError: false)]))
    try requireConversation(attached.contains(.resultAttached(index: 1)), "result attaches to original tool row")
    _ = timeline.apply(.assistantMessage(blocks: [.text("The **authoritative** reply.")]))
    try requireConversation(timeline.streamingText.isEmpty, "completed message replaces the streaming buffer")
    _ = timeline.apply(.turnFinished(text: nil, outcome: .stopped, metrics: .init(duration: 2)))
    guard case .toolCall(let settledEdit) = timeline.rows[2] else {
        throw ConversationContractFailure.failed("settlement replaced the edit identity")
    }
    try requireConversation(settledEdit.result?.outcome == .interrupted, "unanswered tool settles at the turn boundary")
    try requireConversation(timeline.turn(startingAt: 0)?.duration == 2, "turn receipt remains attributed")
    try requireConversation(timeline.steps(inTurnStartingAt: 0) == [1, 2], "stable turn step index")

    // Provider JSON uses the same production parser and reducer; an unreadable list sibling
    // cannot drop valid assistant prose or its tool call.
    let line = #"{"type":"assistant","message":{"content":[null,{"type":"text","text":"Kept é"},{"type":"tool_use","id":"read-1","name":"Read","input":{"file_path":"/tmp/file.swift"}}]}}"#
    guard case .events(let events) = StreamEvent.parse(line) else {
        throw ConversationContractFailure.failed("production stream parser refused readable siblings")
    }
    var parsed = ConversationTimeline(sessionID: SessionID(), chartDecoder: { _, _ in nil })
    for event in events { _ = parsed.apply(event) }
    try requireConversation(parsed.rows.count == 2, "provider prose/tool sibling recovery")
    try requireConversation(parsed.rows[0] == .assistant(markdown: "Kept é"), "Unicode provider text")
    guard case .malformed = StreamEvent.parse("{broken") else {
        throw ConversationContractFailure.failed("malformed provider line was admitted")
    }
    for depth in [1_000, 10_000] {
        var history = ConversationTimeline(sessionID: SessionID(), chartDecoder: { _, _ in nil })
        for index in 0..<depth {
            _ = history.apply(.userMessage("Question \(index)"))
            _ = history.apply(.assistantMessage(blocks: [.text("Answer \(index)")]))
            _ = history.apply(.turnFinished(text: nil, outcome: .completed, metrics: .empty))
        }
        let first = history.rows.first
        _ = history.apply(.userMessage("Current question"))
        _ = history.apply(.assistantMessage(blocks: [.toolUse(id: "current", tool: .read, input: [:])]))
        let changed = history.apply(.toolResults([.init(toolUseID: "current", text: "Current result", isError: false)]))
        try requireConversation(changed == [.resultAttached(index: depth * 2 + 1)], "history-sized result projection")
        try requireConversation(history.rows.first == first && history.rows.count == depth * 2 + 2,
                                "warm update changed historical rows")
        try requireConversation(history.apply(.textDelta("Current reply")) == [.streaming("Current reply")],
                                "history-sized streaming projection")
    }
    print("PASS production conversation timeline: wire numbers, streaming, tool identity/diff/result, settlement and provider sibling recovery")
    print("PASS 1,000/10,000-turn history: one changed-row receipt and one streaming receipt")
}
