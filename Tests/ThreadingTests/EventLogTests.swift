import XCTest
@testable import Threading

final class EventLogTests: XCTestCase {

    private var testDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-eventlog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        try super.tearDownWithError()
    }

    func testRecordAppendsOneJSONLineWithItsDetail() throws {
        let log = EventLog(directory: testDirectory)
        log.record(.session, "Launching agent", ["session": "abc"])

        let records = try journalRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["category"] as? String, "session")
        XCTAssertEqual(records[0]["message"] as? String, "Launching agent")
        XCTAssertEqual((records[0]["detail"] as? [String: String])?["session"], "abc")
        XCTAssertNotNil(records[0]["t"] as? String)
    }

    func testRecordsAccumulateInOrder() throws {
        let log = EventLog(directory: testDirectory)
        log.record(.app, "first")
        log.record(.app, "second")

        let messages = try journalRecords().map { $0["message"] as? String }
        XCTAssertEqual(messages, ["first", "second"])
    }

    /// The point of the whole mechanism: a launch that never reached `endLaunch` is reported
    /// by the *next* one, because its marker is still lying there.
    func testLaunchWithoutAQuitIsReportedByTheNextLaunch() throws {
        EventLog(directory: testDirectory).beginLaunch()

        // No endLaunch: this stands in for the process dying.
        EventLog(directory: testDirectory).beginLaunch()

        let messages = try journalRecords().compactMap { $0["message"] as? String }
        XCTAssertEqual(messages.filter { $0 == EventLogDefaults.uncleanExitMessage }.count, 1)
    }

    func testQuittingLeavesNothingForTheNextLaunchToReport() throws {
        let first = EventLog(directory: testDirectory)
        first.beginLaunch()
        first.endLaunch()

        EventLog(directory: testDirectory).beginLaunch()

        let messages = try journalRecords().compactMap { $0["message"] as? String }
        XCTAssertFalse(messages.contains(EventLogDefaults.uncleanExitMessage))
    }

    /// Reported by the *next* launch and not by the one after it: the marker is consumed when
    /// it is read, so one death produces one record rather than a standing complaint.
    func testAnUncleanExitIsReportedOnlyOnce() throws {
        EventLog(directory: testDirectory).beginLaunch()

        let second = EventLog(directory: testDirectory)
        second.beginLaunch()
        second.endLaunch()

        EventLog(directory: testDirectory).beginLaunch()

        let messages = try journalRecords().compactMap { $0["message"] as? String }
        XCTAssertEqual(messages.filter { $0 == EventLogDefaults.uncleanExitMessage }.count, 1)
    }

    func testUncleanExitCarriesThePreviousLaunchesIdentity() throws {
        EventLog(directory: testDirectory).beginLaunch()
        EventLog(directory: testDirectory).beginLaunch()

        let unclean = try XCTUnwrap(try journalRecords().first {
            $0["message"] as? String == EventLogDefaults.uncleanExitMessage
        })

        let detail = try XCTUnwrap(unclean["detail"] as? [String: String])
        XCTAssertEqual(detail["previousPID"], String(ProcessInfo.processInfo.processIdentifier))
        XCTAssertNotNil(detail["startedAt"])
    }

    func testPerformanceTraceExportsCompletedAndActiveSpans() throws {
        var configuration = PerformanceRecorder.Configuration()
        configuration.slowMainThreadMilliseconds = .greatestFiniteMagnitude
        let traceDirectory = testDirectory.appendingPathComponent("traces")
        let recorder = PerformanceRecorder(
            directory: traceDirectory,
            configuration: configuration
        )

        recorder.measure(
            "test.completed",
            category: "test",
            metadata: [
                "files": "500",
                String(repeating: "shared-prefix", count: 8) + "-a": "first",
                String(repeating: "shared-prefix", count: 8) + "-b": "second"
            ]
        ) {}
        let active = recorder.begin("test.active", category: "test")

        let url = try recorder.export(reason: "unit-test")
        active.end()

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let events = try XCTUnwrap(root["traceEvents"] as? [[String: Any]])
        let completed = try XCTUnwrap(events.first { $0["name"] as? String == "test.completed" })
        let inFlight = try XCTUnwrap(events.first { $0["name"] as? String == "test.active" })

        XCTAssertEqual(completed["ph"] as? String, "X")
        XCTAssertEqual((completed["args"] as? [String: String])?["files"], "500")
        XCTAssertEqual((inFlight["args"] as? [String: String])?["incomplete"], "true")
        XCTAssertEqual((root["otherData"] as? [String: String])?["reason"], "unit-test")
    }

    func testPerformanceTraceBoundsEventsAndReports() throws {
        var configuration = PerformanceRecorder.Configuration()
        configuration.eventCapacity = 2
        configuration.reportLimit = 2
        configuration.slowMainThreadMilliseconds = .greatestFiniteMagnitude
        let traceDirectory = testDirectory.appendingPathComponent("bounded-traces")
        let recorder = PerformanceRecorder(
            directory: traceDirectory,
            configuration: configuration
        )

        recorder.measure("test.first", category: "test") {}
        recorder.measure("test.second", category: "test") {}
        recorder.measure("test.third", category: "test") {}

        let firstURL = try recorder.export(reason: "first")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: firstURL)) as? [String: Any]
        )
        let events = try XCTUnwrap(root["traceEvents"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap { $0["name"] as? String }, [
            "test.second",
            "test.third"
        ])

        _ = try recorder.export(reason: "second")
        _ = try recorder.export(reason: "third")
        let reports = try FileManager.default.contentsOfDirectory(
            at: traceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(reports.count, 2)
    }

    // MARK: - Helpers

    private func journalRecords() throws -> [[String: Any]] {
        let log = EventLog(directory: testDirectory)
        let contents = try String(contentsOf: log.currentJournalURL, encoding: .utf8)

        return try contents
            .split(separator: "\n")
            .map { line in
                let data = Data(line.utf8)
                let object = try JSONSerialization.jsonObject(with: data)
                return try XCTUnwrap(object as? [String: Any])
            }
    }
}
