import XCTest
@testable import DeviceLogsPlugin

/// The path the live stream actually takes: batch in on the pane's thread, store written on
/// another, and a reader asking the store rather than holding it.
final class DeviceLogRecorderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recorder-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func row(_ index: Int) -> DeviceLogRow {
        DeviceLogRow(
            time: "16:21:01.000",
            level: "Debug",
            process: "SpringBoard",
            subsystem: nil,
            message: "token=0xf00" + String(index),
            timestamp: Date(timeIntervalSince1970: 1_756_000_000 + Double(index))
        )
    }

    func testRecordedRowsAreThereToSearchAfterwards() throws {
        let recorder = DeviceLogRecorder(directory: directory, name: "chat")
        recorder.record((0..<200).map(row))

        let found = expectation(description: "searched")
        var hits: [Int64] = []
        recorder.read({ try $0.search("0xf0042") }) { result in
            hits = (try? result.get()) ?? []
            found.fulfill()
        }
        wait(for: [found], timeout: 5)
        XCTAssertEqual(hits.count, 1, "the row written a moment ago should be findable")
    }

    /// Recording is best effort by design: a store that will not open must leave the pane exactly
    /// as it was, because the rows are on screen either way and only history is lost.
    func testAnUnusableDirectoryDoesNotTakeTheStreamDown() throws {
        // A path that cannot become a directory — a file sits where the folder would go.
        let blocker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("blocked-\(UUID().uuidString)")
        try Data("no".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let recorder = DeviceLogRecorder(directory: blocker, name: "chat")
        recorder.record((0..<10).map(row))          // must not trap

        let answered = expectation(description: "answered")
        recorder.read({ try $0.count() }) { result in
            if case .success = result { XCTFail("there is no store to have counted") }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }
}
