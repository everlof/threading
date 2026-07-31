import XCTest
@testable import Threading

/// Reading back what a Claude terminal session *ran*, when nothing configured it.
///
/// The card had a session plainly running Opus 5 and could say only its effort, because both
/// sources it consulted describe configuration: `session.model` is what Threading pinned, and
/// `AgentModels.defaultModel` is `"model"` in the account's `settings.json`. A login that leaves
/// the choice to the CLI sets neither. The transcript is the third source and the only one that
/// observed rather than configured, so these hold the two properties that make it usable: the
/// answer is the *newest* one, and looking for it is bounded.
final class ClaudeTranscriptModelTests: XCTestCase {

    // MARK: - Reading backwards

    /// A transcript ends on whatever the last tool wrote, so the model is near the end and
    /// almost never on the final line — which is exactly what `JSONLReader.lastRecord` would
    /// have answered with.
    func testTheNewestRecordedModelWinsPastATailOfToolResults() throws {
        let url = try transcript([
            assistant("claude-sonnet-5"),
            assistant("claude-opus-5"),
            toolResult("read"),
            toolResult("grep"),
            toolResult("bash")
        ])

        XCTAssertEqual(ClaudeTranscriptModel.newestModel(at: url), "claude-opus-5")
    }

    /// The bound is the point: a conversation whose recent tail is nothing but tool output
    /// answers nothing rather than walking a transcript that has grown to hundreds of megabytes
    /// on the way to a card refresh.
    func testAModelBeyondTheScanBudgetIsNotReachedFor() throws {
        let url = try transcript([
            assistant("claude-opus-5"),
            toolResult(String(repeating: "x", count: TranscriptModelDefaults.scanBytes)),
            toolResult("tail")
        ])

        XCTAssertNil(ClaudeTranscriptModel.newestModel(at: url))
    }

    func testAnAbsentTranscriptAnswersNothingRatherThanFailing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("never-written-\(UUID().uuidString).jsonl")

        XCTAssertNil(ClaudeTranscriptModel.newestModel(at: url))
    }

    /// The forward reader's rule, in the other direction: the *scan* is bounded, never the
    /// record. A record larger than one chunk spans the boundary the backwards read walks, and
    /// truncating it would drop it entirely rather than shortening it — it stops being JSON.
    func testRecordsArriveNewestFirstAndSurviveAChunkBoundary() throws {
        let padding = String(repeating: "x", count: JSONLDefaults.chunkBytes + 1_024)
        let url = try write([
            #"{"n":0}"#,
            #"{"n":1,"pad":"\#(padding)"}"#,
            #"{"n":2}"#,
            #"{"n":3}"#
        ])

        var seen: [Int] = []
        JSONLReader.forEachRecordFromEnd(at: url, limit: .max) { record in
            seen.append(record["n"] as? Int ?? -1)
            return true
        }

        XCTAssertEqual(seen, [3, 2, 1, 0])
    }

    func testTheScanStopsAtItsByteBudget() throws {
        let padding = String(repeating: "x", count: JSONLDefaults.chunkBytes)
        let url = try write([
            #"{"n":0}"#,
            #"{"n":1,"pad":"\#(padding)"}"#,
            #"{"n":2}"#
        ])

        var seen: [Int] = []
        JSONLReader.forEachRecordFromEnd(at: url, limit: JSONLDefaults.chunkBytes) { record in
            seen.append(record["n"] as? Int ?? -1)
            return true
        }

        XCTAssertEqual(seen, [2], "the budget was spent before the padded record began")
    }

    // MARK: - Answering the card

    /// The order the card depends on: nothing on the main thread before the paint, the answer
    /// in memory after it.
    @MainActor
    func testTheAnswerIsKnownOnlyAfterTheBackgroundReadLands() throws {
        let url = try transcript([assistant("claude-opus-5"), toolResult("read")])
        ClaudeTranscriptModel.forgetAll()
        defer { ClaudeTranscriptModel.forgetAll() }

        XCTAssertNil(ClaudeTranscriptModel.known(at: url), "the card must not wait on a file read")

        let landed = expectation(description: "transcript read")
        ClaudeTranscriptModel.revalidate(at: url) { model in
            XCTAssertEqual(model, "claude-opus-5")
            landed.fulfill()
        }
        wait(for: [landed], timeout: 5)

        XCTAssertEqual(ClaudeTranscriptModel.known(at: url), "claude-opus-5")
    }

    // MARK: - Naming

    /// The display name behind the row. `claude-opus-5` matched no family and read as its own
    /// identifier, which is the string this feature would have put on the card.
    func testTheCurrentOpusReadsAsItsFamily() {
        XCTAssertEqual(ModelName.display(for: "claude-opus-5"), "Opus 5")
        XCTAssertEqual(ModelName.display(for: "claude-opus-5[1m]"), "Opus 5 · 1M")
        XCTAssertEqual(ModelName.display(for: "claude-opus-4-8"), "Opus 4.8")
    }

    // MARK: - Helpers

    private func assistant(_ model: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","model":"\#(model)"}}"#
    }

    private func toolResult(_ name: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(name)"}}"#
    }

    private func transcript(_ lines: [String]) throws -> URL {
        try write(lines)
    }

    private func write(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
