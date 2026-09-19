import Foundation
import XCTest
@testable import Threading

final class CodexTurnBoundaryMonitorTests: XCTestCase {
    private var directory: URL!
    private var transcript: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-turn-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transcript = directory.appendingPathComponent("rollout.jsonl")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testGoalStartBehindLargeToolOutputIsRecoveredWithoutPublishingOldCompletion() throws {
        let data = record("task_complete", turn: "old")
            + record("task_started", turn: "goal")
            + output(bytes: 3 * CodexTurnBoundaryDefaults.scanBytes)
        try data.write(to: transcript)
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTranscriptBoundarySourceAdopted()
        let monitor = CodexTurnBoundaryMonitor()
        let recovered = expectation(description: "current goal start recovered")
        monitor.revalidate(at: transcript) { boundary in
            XCTAssertEqual(boundary, .started(turnID: "goal"))
            if case .started(let id) = boundary {
                XCTAssertTrue(tracker.noteTurnStartedFromTranscript(turnID: id))
            }
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 3)
        XCTAssertTrue(tracker.runtimeSnapshot.hasPendingOutcome)
    }

    func testCursorKeepsStartAcrossOutputAndReadsSplitCompletionExactlyOnce() throws {
        try (record("task_started", turn: "goal") + output(bytes: 200_000)).write(to: transcript)
        var cursor = CodexTurnBoundaryCursor()
        drain(&cursor)
        XCTAssertEqual(cursor.boundary, .started(turnID: "goal"))
        let previousOffset = cursor.offset
        XCTAssertFalse(cursor.readPass(at: transcript))
        XCTAssertEqual(cursor.offset, previousOffset, "An unchanged file does no record work")

        let completion = record("task_complete", turn: "goal")
        let split = completion.count / 2
        try append(completion.prefix(split))
        XCTAssertFalse(cursor.readPass(at: transcript))
        XCTAssertEqual(cursor.offset, previousOffset, "An incomplete record remains unread")
        XCTAssertEqual(cursor.boundary, .started(turnID: "goal"))
        try append(completion.suffix(from: split))
        drain(&cursor)
        XCTAssertEqual(cursor.boundary, .completed(turnID: "goal"))
    }

    func testReplacementAndTruncationDiscardTheOldFileBoundary() throws {
        try (record("task_started", turn: "old") + output(bytes: 150_000)).write(to: transcript)
        var cursor = CodexTurnBoundaryCursor()
        drain(&cursor)
        try record("task_complete", turn: "new").write(to: transcript, options: .atomic)
        drain(&cursor)
        XCTAssertEqual(cursor.boundary, .completed(turnID: "new"))

        try Data("{}\n".utf8).write(to: transcript)
        drain(&cursor)
        XCTAssertNil(cursor.boundary)
    }

    func testUnknownAbortDoesNotLeaveThePreviousStartActive() throws {
        try (record("task_started", turn: "goal")
             + record("turn_aborted", turn: "goal")).write(to: transcript)
        var cursor = CodexTurnBoundaryCursor()
        drain(&cursor)
        XCTAssertNil(cursor.boundary)
    }

    func testLargeHistoryUsesBoundedPassesAndOnlyAppendedBytesAfterHydration() throws {
        let stress = ProcessInfo.processInfo.environment["THREADING_CODEX_BOUNDARY_STRESS"] == "1"
        let bytes = stress ? 100 * 1024 * 1024 : 2 * 1024 * 1024
        try (output(bytes: bytes) + record("task_started", turn: "goal")).write(to: transcript)
        var cursor = CodexTurnBoundaryCursor()
        let start = Date()
        let passes = drain(&cursor)
        XCTAssertGreaterThan(passes, bytes / CodexTurnBoundaryDefaults.scanBytes)
        XCTAssertEqual(cursor.boundary, .started(turnID: "goal"))
        let hydratedOffset = cursor.offset
        try append(record("task_complete", turn: "goal"))
        XCTAssertEqual(drain(&cursor), 1)
        XCTAssertGreaterThan(cursor.offset, hydratedOffset)
        XCTAssertEqual(cursor.boundary, .completed(turnID: "goal"))
        if stress {
            print("THREADING_PERF codex.boundary bytes=\(bytes) passes=\(passes) seconds=\(Date().timeIntervalSince(start))")
        }
    }

    @discardableResult
    private func drain(_ cursor: inout CodexTurnBoundaryCursor) -> Int {
        var passes = 0
        var hasMore: Bool
        repeat {
            let before = cursor.offset
            hasMore = cursor.readPass(at: transcript)
            XCTAssertLessThanOrEqual(cursor.offset - min(cursor.offset, before),
                                     UInt64(CodexTurnBoundaryDefaults.scanBytes))
            passes += 1
        } while hasMore && passes < 2_000
        XCTAssertFalse(hasMore, "The cursor must terminate even for oversized or partial records")
        return passes
    }

    private func record(_ type: String, turn: String) -> Data {
        Data((#"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turn)"}}"# + "\n").utf8)
    }

    private func output(bytes: Int) -> Data {
        Data((#"{"type":"response_item","payload":{"text":""#
              + String(repeating: "x", count: bytes) + #""}}"# + "\n").utf8)
    }

    private func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
