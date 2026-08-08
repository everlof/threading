import XCTest
@testable import Threading

// MARK: - Conversation Steps

/// A turn's interior: the tool calls it ran, and which one a given row sits under.
///
/// The rail indexes the conversation by exchange, deliberately, so a turn that ran forty tool
/// calls is one mark and has no interior the rail can reach. These derivations are what the
/// sticky header and the step commands navigate by, and they are pure functions of the row list,
/// so they are tested here rather than through a view tree.
final class ConversationStepTests: XCTestCase {

    private func timeline(_ events: [StreamEvent]) -> ConversationTimeline {
        var timeline = ConversationTimeline(sessionID: SessionID())
        for event in events { _ = timeline.apply(event) }
        return timeline
    }

    private func toolUse(_ id: String, _ tool: ToolIdentity, _ input: [String: JSONValue]) -> StreamEvent {
        .assistantMessage(blocks: [.toolUse(id: id, tool: tool, input: input)])
    }

    // MARK: - Step Index

    func testATurnKnowsTheToolCallsItRanInOrder() {
        let timeline = self.timeline([
            .userMessage("Fix the parser"),
            toolUse("1", .read, ["file_path": .string("/tmp/Parser.swift")]),
            .assistantMessage(blocks: [.text("Found it.")]),
            toolUse("2", .edit, [
                "file_path": .string("/tmp/Parser.swift"),
                "old_string": .string("a"),
                "new_string": .string("b")
            ]),
            toolUse("3", .bash, ["command": .string("swift build")])
        ])

        XCTAssertEqual(timeline.steps(inTurnStartingAt: 0), [1, 3, 4])
    }

    func testStepsBelongToTheTurnThatWasRunningWhenTheyHappened() {
        // The rail's own boundary rule, one level down: a call belongs to the exchange it was
        // made during, and a second exchange starts a second list rather than extending the first.
        let timeline = self.timeline([
            .userMessage("First"),
            toolUse("1", .bash, ["command": .string("ls")]),
            .turnFinished(text: "Done.", outcome: .completed, metrics: TurnMetrics()),
            .userMessage("Second"),
            toolUse("2", .bash, ["command": .string("pwd")])
        ])

        let starts: [Int] = timeline.turns.map { $0.rowIndex }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(timeline.steps(inTurnStartingAt: starts[0]).count, 1)
        XCTAssertEqual(timeline.steps(inTurnStartingAt: starts[1]).count, 1)
        XCTAssertNotEqual(
            timeline.steps(inTurnStartingAt: starts[0]),
            timeline.steps(inTurnStartingAt: starts[1])
        )
    }

    func testATurnThatOnlyTalkedHasNoInteriorToNavigate() {
        let timeline = self.timeline([
            .userMessage("What does this do?"),
            .assistantMessage(blocks: [.text("It parses the file.")])
        ])

        XCTAssertTrue(timeline.steps(inTurnStartingAt: 0).isEmpty)
    }

    func testTheStepIndexAgreesWithAFullScanOfARealConversation() {
        // The cache is written as calls append; this is the scan it is standing in for. They are
        // allowed to differ only if the incremental path has a bug, which is the whole risk of
        // caching a derivation rather than computing it.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts/claude-edit-heavy.jsonl")
        try? XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let (events, _) = TranscriptReplay.read(at: url, kind: .claude)
        let timeline = self.timeline(events)
        let starts: [Int] = timeline.turns.map { $0.rowIndex }

        var scanned: [Int: [Int]] = [:]
        var currentTurn: Int?
        for (index, row) in timeline.rows.enumerated() {
            switch row {
            case .userMessage:
                if starts.contains(index) { currentTurn = index }
            case .toolCall:
                if let currentTurn { scanned[currentTurn, default: []].append(index) }
            default:
                break
            }
        }

        XCTAssertFalse(scanned.isEmpty, "The fixture ran no tool calls, so this proves nothing")
        for start in starts {
            XCTAssertEqual(
                timeline.steps(inTurnStartingAt: start), scanned[start] ?? [],
                "The cached step index disagreed with a scan for the turn at row \(start)"
            )
        }
    }

    // MARK: - Current Step

    func testARowInsideATurnResolvesToTheCallItSitsUnder() {
        let timeline = self.timeline([
            .userMessage("Build it"),
            toolUse("1", .bash, ["command": .string("swift build")]),
            .assistantMessage(blocks: [.text("Compiling.")]),
            toolUse("2", .bash, ["command": .string("swift test")]),
            .assistantMessage(blocks: [.text("Green.")])
        ])

        XCTAssertEqual(timeline.currentStep(atOrBefore: 1), 1, "The call did not resolve to itself")
        XCTAssertEqual(timeline.currentStep(atOrBefore: 2), 1, "Narration lost the call above it")
        XCTAssertEqual(timeline.currentStep(atOrBefore: 3), 3)
        XCTAssertEqual(timeline.currentStep(atOrBefore: 4), 3)
    }

    func testTheTopOfATurnNamesNoStepRatherThanTheLastTurnsLastCall() {
        // The rule that keeps the header honest at a boundary: nothing has been done in this turn
        // yet, and reaching back past the question into the previous exchange would name a step
        // that has nothing to do with what the reader is looking at.
        let timeline = self.timeline([
            .userMessage("First"),
            toolUse("1", .bash, ["command": .string("ls")]),
            .userMessage("Second"),
            .assistantMessage(blocks: [.text("Thinking about it.")])
        ])

        XCTAssertNil(timeline.currentStep(atOrBefore: 2), "The user row resolved to a step")
        XCTAssertNil(
            timeline.currentStep(atOrBefore: 3),
            "A row in a turn that has run nothing borrowed the previous turn's last call"
        )
    }

    func testATurnWithNoToolCallsResolvesToNothingThroughout() {
        let timeline = self.timeline([
            .userMessage("Explain"),
            .assistantMessage(blocks: [.text("One.")]),
            .assistantMessage(blocks: [.text("Two.")])
        ])

        for index in timeline.rows.indices {
            XCTAssertNil(timeline.currentStep(atOrBefore: index), "Row \(index) invented a step")
        }
    }

    func testAnOutOfRangeRowResolvesToNothingRatherThanTrapping() {
        let timeline = self.timeline([.userMessage("Hello")])

        XCTAssertNil(timeline.currentStep(atOrBefore: 99))
        XCTAssertNil(timeline.currentStep(atOrBefore: -1))
    }

    // MARK: - Commands

    func testTheTurnAndStepCommandsExistWithTheirStatedChords() {
        // The chords are an argument from this app's own layers — ⌃⌘ is the window-structure
        // layer that already carries Go Back/Forward on the horizontal arrows, and ⌥⌘ is the
        // refinement layer Group by Branch uses. Pinned so a later binding cannot quietly take
        // one without the argument being revisited.
        func command(_ id: String) throws -> AppCommand {
            try XCTUnwrap(AppCommands.editable.first { $0.id == id }, "\(id) is not a command")
        }

        let previousTurn = try! command(AppCommands.ID.previousTurn)
        let nextTurn = try! command(AppCommands.ID.nextTurn)
        let previousStep = try! command(AppCommands.ID.previousStep)
        let nextStep = try! command(AppCommands.ID.nextStep)

        XCTAssertEqual(previousTurn.defaultShortcut?.modifiers, [.command, .control])
        XCTAssertEqual(nextTurn.defaultShortcut?.modifiers, [.command, .control])
        XCTAssertEqual(previousStep.defaultShortcut?.modifiers, [.command, .option])
        XCTAssertEqual(nextStep.defaultShortcut?.modifiers, [.command, .option])

        XCTAssertEqual(previousTurn.defaultShortcut?.key, "\u{F700}")
        XCTAssertEqual(nextTurn.defaultShortcut?.key, "\u{F701}")
        XCTAssertEqual(previousStep.defaultShortcut?.key, "\u{F700}")
        XCTAssertEqual(nextStep.defaultShortcut?.key, "\u{F701}")

        XCTAssertTrue(
            [previousTurn, nextTurn, previousStep, nextStep].allSatisfy(\.isEditable),
            "A chord this opinionated must be reboundable"
        )
    }

    func testTheNewCommandsDoNotCollideWithAnExistingBinding() {
        // ⌃⌘←/→ are Go Back/Forward and must stay that way; nothing else may already hold the
        // four chords these take.
        var seen: [String: String] = [:]
        for command in AppCommands.editable {
            guard let shortcut = command.defaultShortcut else { continue }
            let chord = "\(shortcut.modifiers.rawValue):\(shortcut.key)"
            XCTAssertNil(
                seen[chord],
                "\(command.id) and \(seen[chord] ?? "") both default to the same chord"
            )
            seen[chord] = command.id
        }
    }
}
