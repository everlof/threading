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

    /// Two writers, one journal, no lost lines.
    ///
    /// A hosted XCTest bundle runs inside the real application, so a test run journals into the
    /// developer's own directory while the app is running: two `EventLog`s, one file. Held at an
    /// offset each remembers, the second writer's records land on top of the first's — the
    /// journal for 5 August 2026 had 23 unparseable lines and lost a quit's own record that way,
    /// which is what made a working feature look like it had never run.
    ///
    /// The interleaving matters: the second log opens its handle while the first has already
    /// written, and both then keep writing.
    func testTwoLogsWritingOneJournalLoseNothing() throws {
        let first = EventLog(directory: testDirectory)
        let second = EventLog(directory: testDirectory)

        first.record(.app, "first-opens")
        second.record(.app, "second-opens")
        for index in 0..<50 {
            first.record(.session, "first-\(index)", ["writer": "first"])
            second.record(.session, "second-\(index)", ["writer": "second"])
        }

        let messages = try journalRecords().compactMap { $0["message"] as? String }
        XCTAssertEqual(
            messages.count,
            102,
            "every line must parse: a clobbered record is a line neither writer can read back"
        )
        for index in 0..<50 {
            XCTAssertTrue(messages.contains("first-\(index)"))
            XCTAssertTrue(messages.contains("second-\(index)"))
        }
    }

    // MARK: - Who Owns the Marker

    /// The second-instance shape: a process that never began a launch quits without disturbing
    /// the marker of the one that did.
    ///
    /// The app is single-instance by an `flock` that fails open, so a second process reaching its
    /// quit path is ordinary — it puts up "already running" and terminates. If that path removed
    /// the marker, the running instance's next crash would be reported as a clean quit, which is
    /// the one thing this file exists to catch.
    func testAProcessThatNeverBeganALaunchRemovesNothingOnItsWayOut() throws {
        let running = EventLog(directory: testDirectory)
        running.beginLaunch()

        let secondInstance = EventLog(directory: testDirectory)
        secondInstance.endLaunch()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerPath),
            "an instance that never launched must not be able to close someone else's launch"
        )
        let next = EventLog(directory: testDirectory)
        next.beginLaunch()
        guard case .unclean = next.previousLaunchOutcome else {
            return XCTFail("the running instance's death is still what the next launch reports")
        }
    }

    /// And it says nothing either: a `Quit` record from a process with no `Launched` record reads
    /// as the running instance having quit, in the same journal that instance is still writing to.
    func testAProcessThatNeverBeganALaunchJournalsNoQuit() throws {
        EventLog(directory: testDirectory).beginLaunch()

        EventLog(directory: testDirectory).endLaunch()

        let messages = try journalRecords().compactMap { $0["message"] as? String }
        XCTAssertFalse(messages.contains(EventLogDefaults.quitMessage))
    }

    /// Ownership is per launch, not per file: once another launch has written the marker, the
    /// earlier one's quit leaves it alone. Otherwise the sequence "A starts, B starts, A quits"
    /// ends with B running and no marker on disk.
    func testAQuitDoesNotRemoveAMarkerAnotherLaunchHasSinceWritten() throws {
        let first = EventLog(directory: testDirectory)
        first.beginLaunch()

        let second = EventLog(directory: testDirectory)
        second.beginLaunch()

        first.endLaunch()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerPath),
            "the marker on disk belongs to the second launch, which has not quit"
        )
    }

    /// The ordinary case, unchanged: the launch that wrote the marker is the one that takes it
    /// away again.
    func testTheLaunchThatWroteTheMarkerRemovesIt() {
        let log = EventLog(directory: testDirectory)
        log.beginLaunch()
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath))

        log.endLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }

    /// Beginning twice in one process is a no-op rather than a second launch. The marker it would
    /// read back is the one it wrote a moment earlier, so a re-entered launch would report the
    /// process it is running in as having crashed.
    func testBeginningTwiceInOneProcessDoesNotReportItselfAsACrash() throws {
        let log = EventLog(directory: testDirectory)
        log.beginLaunch()
        log.beginLaunch()

        let messages = try journalRecords().compactMap { $0["message"] as? String }
        XCTAssertEqual(messages.filter { $0 == EventLogDefaults.uncleanExitMessage }.count, 0)
        XCTAssertEqual(messages.filter { $0 == EventLogDefaults.launchedMessage }.count, 1)
        XCTAssertEqual(log.previousLaunchOutcome, .unknown)
    }

    // MARK: - The Typed Outcome

    /// The fact the window's own notice acts on. It has to be *kept*, because the marker it is
    /// derived from is consumed a few lines into the same `beginLaunch` — by the time anything
    /// asks, there is nothing left on disk to re-derive it from.
    func testALaunchThatNeverQuitIsReportedToTheNextOneAsUnclean() {
        EventLog(directory: testDirectory).beginLaunch()

        let next = EventLog(directory: testDirectory)
        next.beginLaunch()

        guard case .unclean = next.previousLaunchOutcome else {
            return XCTFail("a marker left lying there is the definition of an unclean exit")
        }
        XCTAssertEqual(next.previousLaunchEndedCleanly, false)
    }

    func testADeliberateQuitIsReportedToTheNextLaunchAsClean() {
        let first = EventLog(directory: testDirectory)
        first.beginLaunch()
        first.endLaunch()

        let next = EventLog(directory: testDirectory)
        next.beginLaunch()

        XCTAssertEqual(next.previousLaunchOutcome, .clean)
        XCTAssertEqual(next.previousLaunchEndedCleanly, true)
    }

    /// **The reset relaunch, which is neither a quit nor a crash.**
    ///
    /// The reset flows have to `exit` rather than terminate — a polite quit would write the state
    /// they just moved aside straight back — so the marker survives the restart. Reset Settings
    /// leaves the support directory alone, so for it the marker was still lying there on the next
    /// launch and read as a crash: the workspace was held back and a crash notice went up over a
    /// window the user had pressed a button to get back.
    func testAResetRelaunchIsReportedAsDeliberateRatherThanAsACrash() throws {
        let first = EventLog(directory: testDirectory)
        first.beginLaunch()
        first.recordIntentionalExit(.reset)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerPath),
            "the marker is stamped, not removed: removing it would say the app quit"
        )

        let next = EventLog(directory: testDirectory)
        next.beginLaunch()

        XCTAssertEqual(next.previousLaunchOutcome, .intentional(reason: .reset))
        XCTAssertEqual(
            LaunchRestorationPlan(previousLaunch: next.previousLaunchOutcome),
            .restoresEverything,
            "a restart the user asked for must not hold their workspace back"
        )

        let messages = try journalRecords().compactMap { $0["message"] as? String }
        XCTAssertFalse(
            messages.contains(EventLogDefaults.uncleanExitMessage),
            "a deliberate restart was journalled as a launch that never came back"
        )
        XCTAssertTrue(messages.contains(EventLogDefaults.intentionalExitMessage))
    }

    /// The stamp is consumed exactly as the marker always was, so a reset is reported once rather
    /// than at every launch after it.
    func testTheDeliberateStampIsConsumedLikeAnyOtherMarker() {
        let first = EventLog(directory: testDirectory)
        first.beginLaunch()
        first.recordIntentionalExit(.reset)

        let second = EventLog(directory: testDirectory)
        second.beginLaunch()
        second.endLaunch()

        let third = EventLog(directory: testDirectory)
        third.beginLaunch()

        XCTAssertEqual(third.previousLaunchOutcome, .clean)
    }

    /// A process that never began a launch has no marker of its own to stamp, and stamping
    /// someone else's would hand a running launch a verdict it has not earned.
    func testStampingWithoutHavingBegunALaunchDoesNothing() {
        EventLog(directory: testDirectory).recordIntentionalExit(.reset)

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }

    /// The ledger files its records under the marker's own token. One id shared by the two is the
    /// whole reason the ledger can be *told* how a launch ended rather than deriving a second
    /// answer that could disagree.
    func testTheLaunchTokenIsReadableWhileALaunchIsOpen() {
        let log = EventLog(directory: testDirectory)
        XCTAssertNil(log.currentLaunchID)

        log.beginLaunch()

        XCTAssertNotNil(log.currentLaunchID)
    }

    /// Not a quit and not a crash: there is no previous launch to judge. The distinction is the
    /// whole reason the outcome is a type — `nil` used to stand for this *and* for "quit
    /// cleanly", and a caller had to guess which it had been handed.
    func testAMachineTheAppHasNeverRunOnReportsUnknownRatherThanClean() {
        let first = EventLog(directory: testDirectory)
        first.beginLaunch()

        XCTAssertEqual(first.previousLaunchOutcome, .unknown)
        XCTAssertNil(first.previousLaunchEndedCleanly)
    }

    /// **The order inside `beginLaunch`.** A missing marker means either "quit cleanly" or
    /// "never ran here", and the only thing separating the two is whether a journal survives —
    /// so the question has to be put before the retention sweep deletes the answer. Pruning
    /// first, a machine left alone for longer than the retention window came back reporting that
    /// the app had never run on it.
    func testTheOutcomeIsDecidedBeforeTheRetentionSweepRemovesTheEvidence() throws {
        let expired = testDirectory.appendingPathComponent(
            "\(EventLogDefaults.filePrefix)2020-01-01.\(EventLogDefaults.fileExtension)"
        )
        try Data("{}\n".utf8).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-EventLogDefaults.retention * 2)],
            ofItemAtPath: expired.path
        )

        let log = EventLog(directory: testDirectory)
        log.beginLaunch()

        XCTAssertEqual(
            log.previousLaunchOutcome, .clean,
            "a fortnight of not being opened is not the same as never having run here"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expired.path),
            "the fixture proves nothing unless the sweep actually removed the journal"
        )
    }

    /// The outcome is one-shot for the same reason the journal record is: the marker is spent
    /// when it is read, so the launch after the one that reported the crash is an ordinary one.
    func testTheLaunchAfterTheOneThatReportedACrashIsOrdinary() {
        EventLog(directory: testDirectory).beginLaunch()

        let reporting = EventLog(directory: testDirectory)
        reporting.beginLaunch()
        reporting.endLaunch()

        let next = EventLog(directory: testDirectory)
        next.beginLaunch()

        XCTAssertEqual(next.previousLaunchOutcome, .clean)
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

    private var markerPath: String {
        testDirectory.appendingPathComponent(EventLogDefaults.markerFileName).path
    }

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
