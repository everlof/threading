import Foundation
import XCTest
@testable import Threading

/// Pins the wake-up that output-triggered transcript scans could not provide: Codex may append
/// its structured completion after the PTY has painted its final byte.
final class CodexTranscriptBoundaryObserverTests: XCTestCase {

    @MainActor
    func testTranscriptAppendEndsDeclaredTurnWithoutMoreTerminalOutput() throws {
        let fixture = try makeFixture(boundary: .started(turnID: "turn-1"))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteTurnStarted(turnID: "turn-1")

        let armed = expectation(description: "initial rollout boundary was read")
        armed.assertForOverFulfill = false
        let completed = expectation(description: "later rollout completion reached the tracker")
        let monitor = CodexTurnBoundaryMonitor()
        let observer = CodexTranscriptBoundaryObserver(url: fixture.transcript) {
            monitor.revalidate(at: fixture.transcript) { boundary in
                switch boundary {
                case .started:
                    armed.fulfill()
                case .completed(let turnID):
                    guard tracker.noteTurnFinishedFromTranscript(turnID: turnID) else { return }
                    completed.fulfill()
                case .interrupted, nil:
                    break
                }
            }
        }
        XCTAssertTrue(observer.start())
        defer { observer.stop() }

        wait(for: [armed], timeout: 3)
        try append(.completed(turnID: "turn-1"), to: fixture.transcript)

        wait(for: [completed], timeout: 3)
        XCTAssertEqual(tracker.activity, .needsAttention)
        XCTAssertFalse(tracker.runtimeSnapshot.hasOpenTurn)
    }

    @MainActor
    func testInitialReadClosesRegistrationRace() throws {
        let fixture = try makeFixture(boundary: .completed(turnID: "turn-1"))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted(turnID: "turn-1")

        let completed = expectation(description: "existing completion was read after arming")
        let monitor = CodexTurnBoundaryMonitor()
        let observer = CodexTranscriptBoundaryObserver(url: fixture.transcript) {
            monitor.revalidate(at: fixture.transcript) { boundary in
                guard case .completed(let turnID) = boundary,
                      tracker.noteTurnFinishedFromTranscript(turnID: turnID) else { return }
                completed.fulfill()
            }
        }
        XCTAssertTrue(observer.start())
        defer { observer.stop() }

        wait(for: [completed], timeout: 3)
        XCTAssertEqual(tracker.activity, .idle)
    }

    func testOnlyTheObservedRolloutOrAnUnreliableDirectoryEventIsRelevant() {
        let directory = "/Users/x/.codex/sessions/2026/09/05"
        let transcript = "\(directory)/rollout-target.jsonl"
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)

        XCTAssertTrue(CodexTranscriptBoundaryObserver.isRelevant(
            path: transcript,
            flags: modified,
            transcriptPath: transcript,
            watchedDirectory: directory
        ))
        XCTAssertFalse(CodexTranscriptBoundaryObserver.isRelevant(
            path: "\(directory)/rollout-sibling.jsonl",
            flags: modified,
            transcriptPath: transcript,
            watchedDirectory: directory
        ))
        XCTAssertTrue(CodexTranscriptBoundaryObserver.isRelevant(
            path: directory,
            flags: dropped,
            transcriptPath: transcript,
            watchedDirectory: directory
        ))
    }

    // MARK: - Fixtures

    private func makeFixture(
        boundary: CodexTurnBoundary
    ) throws -> (directory: URL, transcript: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-codex-boundary-watch-\(UUID().uuidString)")
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(record(for: boundary).utf8).write(to: transcript)
        return (directory, transcript)
    }

    private func append(_ boundary: CodexTurnBoundary, to transcript: URL) throws {
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(record(for: boundary).utf8))
    }

    private func record(for boundary: CodexTurnBoundary) -> String {
        let type: String
        switch boundary {
        case .started: type = CodexTurnBoundaryDefaults.startedType
        case .completed: type = CodexTurnBoundaryDefaults.completedType
        case .interrupted: type = CodexTurnBoundaryDefaults.abortedType
        }
        return #"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(boundary.turnID)"}}"#
            + "\n"
    }
}
