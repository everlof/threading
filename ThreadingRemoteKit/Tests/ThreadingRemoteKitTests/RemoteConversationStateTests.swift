import XCTest
@testable import ThreadingRemoteKit

final class RemoteConversationStateTests: XCTestCase {
    func testOlderSnapshotDefaultsPaginationMetadata() throws {
        let data = Data(#"{"type":"conversation","rows":[],"canSend":true}"#.utf8)
        let snapshot = try JSONDecoder().decode(RemoteConversationSnapshotDTO.self, from: data)

        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertFalse(snapshot.hasEarlier)
        XCTAssertEqual(snapshot.streamingText, "")
    }

    func testDeltaUpdatesOneRowAndAppendsWithoutReplacingHistory() {
        var state = RemoteConversationState()
        state.apply(RemoteConversationSnapshotDTO(
            rows: [
                .init(id: "8", kind: "user", text: "Run it"),
                .init(id: "9", kind: "tool", toolName: "Bash", summary: "swift test"),
            ],
            streamingText: "Working",
            canSend: false,
            revision: 4,
            hasEarlier: true
        ))

        let result = state.apply(RemoteConversationDeltaDTO(
            baseRevision: 4,
            revision: 5,
            appendedRows: [
                .init(id: "10", kind: "assistant", text: "All green.")
            ],
            updatedRows: [
                .init(
                    id: "9",
                    kind: "tool",
                    toolName: "Bash",
                    summary: "swift test",
                    result: "Passed"
                )
            ],
            streamingText: "",
            canSend: true
        ))

        XCTAssertEqual(
            result,
            .changed(inserted: ["10"], updated: ["9"])
        )
        XCTAssertEqual(state.rows.map(\.id), ["8", "9", "10"])
        XCTAssertEqual(state.rows[1].result, "Passed")
        XCTAssertTrue(state.canSend)
        XCTAssertTrue(state.hasEarlier, "a live delta must not reset the page boundary")
    }

    func testRevisionGapRequestsSnapshotWithoutMutation() {
        var state = RemoteConversationState(revision: 7)
        let result = state.apply(RemoteConversationDeltaDTO(
            baseRevision: 6,
            revision: 8,
            streamingText: "missed",
            canSend: false
        ))

        XCTAssertEqual(result, .requiresSnapshot)
        XCTAssertEqual(state.revision, 7)
        XCTAssertEqual(state.streamingText, "")
    }

    func testHistoryPagesPrependIdempotently() {
        var state = RemoteConversationState(
            rows: [
                .init(id: "2", kind: "assistant", text: "Two"),
                .init(id: "3", kind: "assistant", text: "Three"),
            ],
            hasEarlier: true
        )
        let page = RemoteConversationPageDTO(
            rows: [
                .init(id: "0", kind: "user", text: "Zero"),
                .init(id: "1", kind: "assistant", text: "One"),
                .init(id: "2", kind: "assistant", text: "Two"),
            ],
            beforeRowID: "2",
            hasEarlier: false
        )

        XCTAssertEqual(state.prepend(page), .prepended(["0", "1"]))
        XCTAssertEqual(state.rows.map(\.id), ["0", "1", "2", "3"])
        XCTAssertEqual(state.prepend(page), .unchanged)
        XCTAssertFalse(state.hasEarlier)
    }

    func testTenThousandStreamingDeltasDoNotRebuildRows() {
        let rows = (0..<1_000).map {
            RemoteConversationRowDTO(id: String($0), kind: "assistant", text: "Message \($0)")
        }
        let state = RemoteConversationState(rows: rows, revision: 1)

        measure {
            var measured = state
            for revision in 2...10_001 {
                _ = measured.apply(RemoteConversationDeltaDTO(
                    baseRevision: revision - 1,
                    revision: revision,
                    streamingText: "token \(revision)",
                    canSend: false
                ))
            }
            XCTAssertEqual(measured.rows.count, rows.count)
        }
    }
}
