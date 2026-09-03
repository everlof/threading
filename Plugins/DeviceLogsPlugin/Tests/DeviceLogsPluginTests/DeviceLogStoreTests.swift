import XCTest
@testable import DeviceLogsPlugin

/// The store, and whether it can keep up with the thing it is storing.
///
/// A paired iPhone was measured at ~5,800 rows/sec unfiltered. Timber indexes a file that has
/// stopped growing; this indexes a firehose, so the question "does it keep up" has to be answered
/// before anything is built on top of it.
final class DeviceLogStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("device-log-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> DeviceLogStore {
        try DeviceLogStore(url: directory.appendingPathComponent("rows.sqlite"))
    }

    private func rows(_ count: Int, from start: Date = Date(timeIntervalSince1970: 1_756_000_000))
        -> [DeviceLogRow] {
        (0..<count).map { index -> DeviceLogRow in
            let clock: String = "16:21:01." + String(format: "%03d", index % 1000)
            let level: String = index % 50 == 0 ? "Error" : "Debug"
            let process: String = index % 3 == 0 ? "backboardd" : "SpringBoard"
            let message: String = "HF Seq:" + String(index) + ", Sending " + String(index)
                + "+80 of 240 filled. token=0x16f95" + String(index)
            let offset: Double = Double(index) / 5_800
            return DeviceLogRow(
                time: clock,
                level: level,
                process: process,
                subsystem: "com.apple.xpc",
                message: message,
                timestamp: start.addingTimeInterval(offset)
            )
        }
    }

    // MARK: - Behaviour

    func testRowsComeBackAsTheyWentIn() throws {
        let store = try makeStore()
        try store.append(rows(10))
        XCTAssertEqual(try store.count(), 10)
        // Ids start at 1, so row 4 is the fifth line in: index 3, and 3 % 3 == 0.
        let row = try XCTUnwrap(try store.row(4))
        XCTAssertEqual(row.level, "Debug")
        XCTAssertEqual(row.process, "backboardd")
        XCTAssertTrue(row.message.hasPrefix("HF Seq:3,"))
        XCTAssertNotNil(row.timestamp)
    }

    /// Trigram, not the default tokenizer: a log is searched for fragments inside identifiers, and
    /// a word tokenizer finds none of them.
    func testSearchFindsASubstringInsideAnIdentifier() throws {
        let store = try makeStore()
        try store.append(rows(500))
        XCTAssertFalse(try store.search("0x16f95").isEmpty)
        XCTAssertFalse(try store.search("Seq:41").isEmpty)
        XCTAssertTrue(try store.search("nothing like this").isEmpty)
    }

    func testARangeSelectsOnlyTheRowsInsideIt() throws {
        let start = Date(timeIntervalSince1970: 1_756_000_000)
        let store = try makeStore()
        try store.append(rows(5_800, from: start))          // one second's worth
        let ids = try store.ids(from: start, to: start.addingTimeInterval(0.5))
        XCTAssertGreaterThan(ids.count, 2_000)
        XCTAssertLessThan(ids.count, 3_500, "half a second should not return the whole second")
    }

    func testSeverityFilterFindsTheErrors() throws {
        let store = try makeStore()
        try store.append(rows(1_000))
        XCTAssertEqual(try store.ids(atLeast: 3).count, 20)
    }

    /// Retention drops the oldest, and the search index has to follow — an FTS row left behind
    /// would return an id whose row no longer exists.
    func testTrimmingDropsTheOldestAndTheIndexFollows() throws {
        let store = try makeStore()
        try store.append(rows(1_000))
        try store.trim(to: 100)
        XCTAssertEqual(try store.count(), 100)
        XCTAssertNil(try store.row(1), "the oldest row is gone")
        for id in try store.search("Seq:") {
            XCTAssertNotNil(try store.row(id), "the index returned id \(id), which no longer exists")
        }
    }

    // MARK: - Can it keep up

    /// The number that decides the design. Batches are the size one 100 ms drain produces at the
    /// measured device rate, so this is the real arrival shape rather than one big insert.
    func testSustainsMoreThanTheDeviceProduces() throws {
        let store = try makeStore()
        let perTick = 580                       // 5,800 rows/sec at the pane's 100 ms drain
        let ticks = 20                          // two seconds of firehose
        let batches = (0..<ticks).map { tick in
            rows(perTick, from: Date(timeIntervalSince1970: 1_756_000_000 + Double(tick)))
        }
        let started = DispatchTime.now().uptimeNanoseconds
        for batch in batches { try store.append(batch) }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        let rate = Double(perTick * ticks) / seconds
        print(String(format: "STORE insert %.0f rows/sec (%d rows in %.3f s)", rate, perTick * ticks, seconds))
        XCTAssertEqual(try store.count(), perTick * ticks)
        XCTAssertGreaterThan(rate, 5_800, "cannot keep up with a paired device")
    }

    /// Search has to stay usable once there is a lot to search, because that is when it is asked.
    func testSearchStaysFastOnALargeTable() throws {
        let store = try makeStore()
        for tick in 0..<100 {
            try store.append(rows(1_000, from: Date(timeIntervalSince1970: 1_756_000_000 + Double(tick))))
        }
        XCTAssertEqual(try store.count(), 100_000)
        let started = DispatchTime.now().uptimeNanoseconds
        let hits = try store.search("0x16f95")
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print(String(format: "STORE search %d hits in %.1f ms over 100k rows", hits.count, ms))
        XCTAssertFalse(hits.isEmpty)
        XCTAssertLessThan(ms, 250, "search is what an agent waits on")
    }
}
