import XCTest
@testable import Threading

/// Every launch attempt, how far it got, and how it ended.
///
/// The read matrix is the point of most of this. Four outcomes have to stay four — missing, valid,
/// a format from a later build, and damage — because collapsing any pair means either reading a
/// file as empty and writing over it, or confiscating history a downgrade merely cannot parse.
final class LaunchLedgerTests: XCTestCase {

    // MARK: - Fixture

    private var directory = URL(fileURLWithPath: "/")
    private var ledgerURL: URL { directory.appendingPathComponent("launch-ledger.jsonl") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LaunchLedgerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func ledger(_ fileManager: FileManager = .default) -> LaunchLedger {
        LaunchLedger(url: ledgerURL, fileManager: fileManager)
    }

    /// Opening and beginning, as the launch sequence does them.
    ///
    /// The two are separate in production because the `begin` record carries the mode and the
    /// mode is decided from what the opening returns. Every case below that only cares about the
    /// *result* takes both steps through here; the cases about the ordering itself call the two
    /// directly.
    @discardableResult
    private func begin(
        _ ledger: LaunchLedger,
        id: String?,
        previousOutcome: EventLog.PreviousLaunchOutcome,
        mode: LaunchMode = .normal
    ) -> LaunchLedgerRead {
        let opening = ledger.openLaunch(previousOutcome: previousOutcome)
        ledger.beginLaunch(opening, id: id, mode: mode)
        return opening.read
    }

    private func write(_ lines: [String], trailingNewline: Bool = true) throws {
        var text = lines.joined(separator: "\n")
        if trailingNewline { text += "\n" }
        try Data(text.utf8).write(to: ledgerURL)
    }

    /// One record, spelled the way the writer spells it. Built through `JSONSerialization` rather
    /// than by hand so a fixture cannot quietly disagree with the encoder about a type.
    private func line(
        version: Int = LaunchLedgerDefaults.formatVersion,
        kind: String,
        launch: String,
        at: String = "2026-08-07T12:00:00.000+02:00",
        uptime: Double = 100,
        boot: String = "boot-1",
        fingerprint: String? = nil,
        checkpoint: String? = nil,
        disposition: String? = nil
    ) throws -> String {
        var record: [String: Any] = [
            "version": version,
            "kind": kind,
            "launch": launch,
            "at": at,
            "uptime": uptime,
            "boot": boot
        ]
        if let fingerprint { record["fingerprint"] = fingerprint }
        if let checkpoint { record["checkpoint"] = checkpoint }
        if let disposition { record["disposition"] = disposition }

        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func records() throws -> [[String: Any]] {
        let text = try String(contentsOf: ledgerURL, encoding: .utf8)
        return try text
            .split(separator: "\n")
            .map { try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            ) }
    }

    // MARK: - The Read Matrix

    func testAFileThatIsNotThereIsMissingRatherThanEmpty() {
        XCTAssertEqual(ledger().read(), .missing)
    }

    func testACompleteHistoryReadsBackAsTheLaunchesThatMadeIt() throws {
        try write([
            line(kind: "begin", launch: "a", fingerprint: "build-a"),
            line(kind: "checkpoint", launch: "a", checkpoint: "themeRestored"),
            line(kind: "end", launch: "a", disposition: "clean"),
            line(kind: "begin", launch: "b", fingerprint: "build-a")
        ].map { try $0 })

        let history = try XCTUnwrap(ledger().read().history)
        XCTAssertEqual(history.launches.map(\.id), ["a", "b"])
        XCTAssertEqual(history.launches[0].checkpoints, [.themeRestored])
        XCTAssertEqual(history.launches[0].ending?.disposition, .clean)
        XCTAssertNil(history.launches[1].ending)
    }

    /// `O_CREAT` makes the file before the first record reaches it, so zero bytes is the ordinary
    /// state of a ledger nothing has been appended to — not damage.
    func testAnEmptyFileIsValidAndEmptyRatherThanCorrupt() throws {
        try Data().write(to: ledgerURL)

        XCTAssertEqual(ledger().read(), .valid(LaunchLedgerHistory()))
    }

    /// **A torn final line is what dying between two writes looks like.** It is the signature this
    /// file exists to record, so it is dropped and flagged rather than treated as a reason to
    /// distrust everything above it.
    func testATornFinalLineIsDroppedRatherThanTreatedAsDamage() throws {
        let good = try line(kind: "begin", launch: "a", fingerprint: "build-a")
        try write([good, "{\"version\":1,\"kind\":\"check"], trailingNewline: false)

        let history = try XCTUnwrap(ledger().read().history)
        XCTAssertTrue(history.droppedTrailingPartial)
        XCTAssertEqual(history.launches.map(\.id), ["a"])
    }

    /// A line that failed anywhere but the end did not come from a death mid-write, so it is
    /// damage — and damage is moved aside, never read as an empty history and written over.
    func testAnInteriorBadLineIsDamageAndTheFileIsMovedAside() throws {
        try write([
            "{\"version\":1,\"kind\":\"beg",
            try line(kind: "begin", launch: "a", fingerprint: "build-a")
        ])

        let read = ledger().read()
        guard case .corrupt(let quarantined) = read else {
            return XCTFail("an interior bad line has to be corrupt, not \(read)")
        }
        let destination = try XCTUnwrap(quarantined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
        XCTAssertTrue(destination.lastPathComponent.contains(LaunchLedgerDefaults.quarantineInfix))
    }

    /// A store that cannot preserve what it is about to write over has one safe move, and it is to
    /// stop.
    func testQuarantineThatCannotBeDoneBlocksEveryLaterRecord() throws {
        try write(["{\"version\":1,\"kind\":\"beg", try line(kind: "begin", launch: "a")])

        let refusing = RefusingFileManager()
        let ledger = ledger(refusing)

        XCTAssertEqual(ledger.read(), .corrupt(quarantinedAt: nil))
        XCTAssertTrue(ledger.isWriteBlocked)

        begin(ledger, id: "b", previousOutcome: .unknown)
        let after = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertFalse(after.contains("\"launch\":\"b\""), "a blocked ledger still wrote a record")
    }

    /// A record from a *later* Threading is not damage. Quarantining it would mean a downgrade
    /// silently confiscated history it merely cannot parse, so the file is left byte for byte.
    func testARecordFromALaterBuildIsLeftExactlyAsFound() throws {
        try write([
            try line(kind: "begin", launch: "a", fingerprint: "build-a"),
            try line(version: 2, kind: "begin", launch: "b")
        ])
        let before = try Data(contentsOf: ledgerURL)

        XCTAssertEqual(ledger().read(), .unsupportedVersion(newestFormatSeen: 2))
        XCTAssertEqual(try Data(contentsOf: ledgerURL), before)
    }

    /// A later format wins over damage in the same file, for that reason: the cost of being wrong
    /// about damage is a moved file, and the cost of being wrong about a newer build is its history.
    func testALaterFormatBeatsDamageInTheSameFile() throws {
        try write(["{\"version\":1,\"kind\":\"beg", try line(version: 2, kind: "begin", launch: "b")])

        XCTAssertEqual(ledger().read(), .unsupportedVersion(newestFormatSeen: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    /// What Reset Everything leaves when the directory is moved aside under a running app: the
    /// next write recreates the file holding nothing but an ending.
    func testARecordNamingNoBeginIsCountedRatherThanFatal() throws {
        try write([try line(kind: "end", launch: "gone", disposition: "intentional:reset")])

        let history = try XCTUnwrap(ledger().read().history)
        XCTAssertTrue(history.launches.isEmpty)
        XCTAssertEqual(history.unattachedRecordCount, 1)
    }

    /// A checkpoint name from a build that knows one more than this one does is not damage and is
    /// not something this build can reason about, so the launch keeps everything else.
    func testACheckpointNameThisBuildDoesNotKnowIsSkippedNotFatal() throws {
        try write([
            try line(kind: "begin", launch: "a", fingerprint: "build-a"),
            try line(kind: "checkpoint", launch: "a", checkpoint: "quantumTunnelOpened"),
            try line(kind: "checkpoint", launch: "a", checkpoint: "themeRestored")
        ])

        let history = try XCTUnwrap(ledger().read().history)
        XCTAssertEqual(history.launches.first?.checkpoints, [.themeRestored])
    }

    // MARK: - Recording

    func testABeginIsWrittenAndCheckpointsFollowIt() throws {
        let ledger = ledger()
        begin(ledger, id: "a", previousOutcome: .unknown)
        ledger.record(.themeRestored)
        ledger.endLaunch(.clean)

        let kinds = try records().map { $0["kind"] as? String }
        XCTAssertEqual(kinds, ["begin", "checkpoint", "end"])

        let history = try XCTUnwrap(ledger.read().history)
        XCTAssertEqual(history.launches.first?.checkpoints, [.themeRestored])
        XCTAssertEqual(history.launches.first?.ending?.disposition, .clean)
    }

    /// **The gate, and deliberately the same one `EventLog` uses for its marker.** A hosted test
    /// bundle and an instance that lost the single-instance lock both reach code that records
    /// checkpoints and neither ever begins a launch, so the drop belongs here rather than in a
    /// guard at each of the nine call sites.
    func testACheckpointWithoutAnOpenLaunchWritesNothingAtAll() {
        ledger().record(.mainWindowConstructed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testALaunchEndsOnceHoweverManyTimesItIsAsked() throws {
        let ledger = ledger()
        begin(ledger, id: "a", previousOutcome: .unknown)
        ledger.endLaunch(.clean)
        ledger.endLaunch(.intentional(.reset))

        let endings = try records().filter { $0["kind"] as? String == "end" }
        XCTAssertEqual(endings.count, 1)
        XCTAssertEqual(endings.first?["disposition"] as? String, "clean")
    }

    func testBeginningTwiceInOneProcessDoesNotOpenASecondLaunch() throws {
        let ledger = ledger()
        begin(ledger, id: "a", previousOutcome: .unknown)
        begin(ledger, id: "b", previousOutcome: .unknown)

        let begins = try records().filter { $0["kind"] as? String == "begin" }
        XCTAssertEqual(begins.count, 1)
    }

    // MARK: - Opening Before Beginning

    /// **The whole point of the split.** The mode is decided from the history the opening returns,
    /// so the opening has to happen first and the `begin` has to carry the answer.
    func testTheModeDecidedFromTheOpeningIsWhatTheBeginRecords() throws {
        try write([try line(kind: "begin", launch: "a", fingerprint: "build-a")])
        let ledger = ledger()

        let opening = ledger.openLaunch(previousOutcome: .unclean(crashReport: nil))
        // What a launch decides on: the history as the tombstones just written left it.
        XCTAssertEqual(
            try XCTUnwrap(opening.read.history).launches.first?.ending?.disposition,
            .unclean
        )

        ledger.beginLaunch(opening, id: "b", mode: .recovery)

        // The fixture's `begin` is still in the file, so this launch's is the one named "b".
        let ours = try records().filter {
            $0["kind"] as? String == "begin" && $0["launch"] as? String == "b"
        }
        XCTAssertEqual(ours.count, 1)
        XCTAssertEqual(ours.first?["mode"] as? String, "recovery")
    }

    /// Opening writes the tombstones and compacts; it does **not** write a `begin`. A launch that
    /// died between the two steps must read as one that never started, not as one in normal mode.
    func testOpeningAloneTombstonesWithoutClaimingALaunchBegan() throws {
        try write([try line(kind: "begin", launch: "a", fingerprint: "build-a")])

        _ = ledger().openLaunch(previousOutcome: .unclean(crashReport: nil))

        let kinds = try records().map { $0["kind"] as? String }
        XCTAssertEqual(kinds, ["begin", "outcome"], "the only begin is the fixture's")
    }

    /// A second open would tombstone the launch this very process is running.
    func testASecondOpeningIsRefusedAndWritesNothing() throws {
        let ledger = ledger()
        let first = ledger.openLaunch(previousOutcome: .unknown)
        ledger.beginLaunch(first, id: "a")

        let second = ledger.openLaunch(previousOutcome: .unclean(crashReport: nil))
        ledger.beginLaunch(second, id: "b")

        let begins = try records().filter { $0["kind"] as? String == "begin" }
        XCTAssertEqual(begins.map { $0["launch"] as? String }, ["a"])
        XCTAssertEqual(try records().filter { $0["kind"] as? String == "outcome" }.count, 0)
    }

    /// An opening another ledger handed out cannot buy a `begin` here. The ordering is a property
    /// of this instance rather than a convention between call sites — which is what stops a
    /// second writer over one file from appending a record whose mode nobody decided.
    func testABeginWithAnOpeningFromAnotherLedgerWritesNothing() throws {
        let other = LaunchLedger(
            url: directory.appendingPathComponent("other.jsonl"),
            fileManager: .default
        )
        let ledger = ledger()

        // Valid, but this ledger has not opened, so it has no launch of its own to begin.
        ledger.beginLaunch(other.openLaunch(previousOutcome: .unknown), id: "a")
        // And a checkpoint still finds no open launch, which is the observable consequence.
        ledger.record(.themeRestored)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ledgerURL.path),
            "a begin was written for a launch this ledger never opened"
        )
    }

    // MARK: - Tombstones

    /// The marker knows *how* the last launch ended and only the ledger knows how far it got, so
    /// the ledger is told rather than deriving a second answer that could disagree.
    func testTheNewestUnfinishedLaunchTakesTheMarkersAnswer() throws {
        try write([try line(kind: "begin", launch: "a", fingerprint: "build-a")])

        let read = begin(
            ledger(),
            id: "b",
            previousOutcome: .intentional(reason: .reset)
        )

        let history = try XCTUnwrap(read.history)
        XCTAssertEqual(history.launches.first?.ending?.disposition, .intentional(.reset))
        XCTAssertEqual(
            try records().filter { $0["kind"] as? String == "outcome" }.count, 1
        )
    }

    /// **Every unfinished `begin`, not only the newest.** A successor that itself died before it
    /// reached this line wrote no tombstone at all, and without this rule the launch it failed to
    /// account for would never receive one — a crash quietly missing from the history for good.
    /// The older ones are inferred `unclean` from their own missing `end`: that absence is the
    /// evidence, and it needs no marker.
    func testEveryUnfinishedLaunchIsTombstonedAndNotOnlyTheNewest() throws {
        try write([
            try line(kind: "begin", launch: "a", fingerprint: "build-a"),
            try line(kind: "begin", launch: "b", fingerprint: "build-a"),
            try line(kind: "begin", launch: "c", fingerprint: "build-a")
        ])

        let read = begin(ledger(), id: "d", previousOutcome: .clean)

        let history = try XCTUnwrap(read.history)
        XCTAssertEqual(
            history.launches.map(\.ending?.disposition),
            [.unclean, .unclean, .clean],
            "only the newest may take the marker's answer, and none may be left without one"
        )
        XCTAssertEqual(try records().filter { $0["kind"] as? String == "outcome" }.count, 3)
    }

    /// **No target, no tombstone.** Attaching an outcome to a launch that already ended, or
    /// inventing one to hang it on, would make the file say something nobody observed.
    func testAMarkerAnswerWithNothingToAttachItToWritesNoTombstone() throws {
        for outcome in [
            EventLog.PreviousLaunchOutcome.clean,
            .unknown,
            .intentional(reason: .reset)
        ] {
            try write([
                try line(kind: "begin", launch: "a", fingerprint: "build-a"),
                try line(kind: "end", launch: "a", disposition: "clean")
            ])

            begin(ledger(), id: "b", previousOutcome: outcome)

            XCTAssertEqual(
                try records().filter { $0["kind"] as? String == "outcome" }.count, 0,
                "\(outcome) invented a tombstone with nothing unfinished to attach it to"
            )
        }
    }

    /// A launch that already ended keeps the ending it wrote about itself. It is the better
    /// witness: it was there.
    func testAFinishedLaunchIsNotGivenASecondEnding() throws {
        try write([
            try line(kind: "begin", launch: "a", fingerprint: "build-a"),
            try line(kind: "end", launch: "a", disposition: "clean"),
            try line(kind: "begin", launch: "b", fingerprint: "build-a")
        ])

        let read = begin(ledger(), id: "c", previousOutcome: .unclean(crashReport: nil))

        let history = try XCTUnwrap(read.history)
        XCTAssertEqual(history.launches.map(\.ending?.disposition), [.clean, .unclean])
    }

    /// A ledger that outlived the journal directory. The unfinished `begin` is itself the
    /// evidence, so `unknown` becomes `unclean` rather than nothing.
    func testAnUnfinishedLaunchWithNoMarkerToJudgeItIsStillUnclean() throws {
        try write([try line(kind: "begin", launch: "a", fingerprint: "build-a")])

        let read = begin(ledger(), id: "b", previousOutcome: .unknown)

        XCTAssertEqual(try XCTUnwrap(read.history).launches.first?.ending?.disposition, .unclean)
    }

    // MARK: - The Budget

    /// **Eviction is by launch, never by line.** Half a launch reads as a launch that died, so a
    /// line budget alone would manufacture the exact fact this file exists to report.
    func testTheBudgetEvictsWholeLaunchesRatherThanLines() throws {
        var lines: [String] = []
        for index in 0...LaunchLedgerDefaults.maximumLaunches {
            let id = "launch-\(index)"
            lines.append(try line(kind: "begin", launch: id, fingerprint: "build-a"))
            lines.append(try line(kind: "checkpoint", launch: id, checkpoint: "themeRestored"))
            lines.append(try line(kind: "end", launch: id, disposition: "clean"))
        }
        try write(lines)

        begin(ledger(), id: "newest", previousOutcome: .clean)

        let history = try XCTUnwrap(ledger().read().history)
        XCTAssertNil(
            history.launches.first(where: { $0.id == "launch-0" }),
            "the oldest launch should have gone whole"
        )
        for launch in history.launches where launch.id != "newest" {
            XCTAssertEqual(launch.checkpoints, [.themeRestored], "\(launch.id) was cut in half")
            XCTAssertNotNil(launch.ending, "\(launch.id) lost the record of how it ended")
        }
    }

    func testTheKeepSetNeverExceedsEitherBudget() throws {
        var history = LaunchLedgerHistory()
        for index in 0..<(LaunchLedgerDefaults.maximumLaunches * 2) {
            let id = "launch-\(index)"
            history.launches.append(LaunchLedgerLaunch(
                id: id,
                startedAt: Date(),
                uptime: Double(index),
                bootID: "boot-1",
                fingerprint: "build-a",
                mode: .normal
            ))
            history.records.append(LaunchLedgerRecord(
                version: 1, kind: .begin, launch: id, at: "", uptime: 0, boot: "boot-1",
                build: nil, fingerprint: "build-a", mode: nil, writer: nil, pid: nil,
                checkpoint: nil, detail: nil, disposition: nil, systemInitiated: nil
            ))
        }

        let kept = LaunchLedger.recordsToKeep(from: history)
        XCTAssertEqual(kept.count, LaunchLedgerDefaults.maximumLaunches)
        XCTAssertLessThanOrEqual(kept.count, LaunchLedgerDefaults.maximumRecords)
        XCTAssertEqual(kept.last?.launch, "launch-39", "the newest launch must be the one kept")
    }

    // MARK: - The Hosted Bundle

    /// The tests run inside the shipping app, so a test that begins a launch must not append to
    /// the ledger the developer's own next launch decides a crash loop from.
    func testAHostedTestBundleWritesToItsOwnScratchDirectory() {
        XCTAssertTrue(
            LaunchLedgerDefaults.defaultURL.path
                .contains(LaunchLedgerDefaults.hostedTestDirectoryName),
            "a hosted test run is writing into the developer's real launch ledger"
        )
    }

    // MARK: - The Reset Path

    /// The stamp lives inside `AppRelaunch` rather than at the two reset call sites, so a third
    /// caller cannot forget it. What is asserted here is the other half: a process with no launch
    /// of its own — a hosted test bundle, an instance that lost the single-instance lock — writes
    /// nothing when the same helper runs, rather than stamping someone else's launch.
    func testTheResetStampIsInertWithoutALaunchOfItsOwn() {
        AppRelaunch.recordIntentionalExit()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: LaunchLedgerDefaults.defaultURL.path),
            "a process that never began a launch wrote an ending for one"
        )
    }

    // MARK: - Tokens

    func testEveryReadOutcomeHasAStableToken() {
        XCTAssertEqual(LaunchLedgerRead.missing.token, "missing")
        XCTAssertEqual(LaunchLedgerRead.valid(LaunchLedgerHistory()).token, "valid launches=0")
        XCTAssertEqual(
            LaunchLedgerRead.unsupportedVersion(newestFormatSeen: 3).token,
            "unsupported newest=3"
        )
        XCTAssertEqual(
            LaunchLedgerRead.corrupt(quarantinedAt: nil).token,
            "corrupt quarantined=no"
        )
    }

    /// The token is what a support report carries, so it must be counts and enum words. A path is
    /// a user's directory layout and belongs in the log the machine's owner reads.
    func testTheTokenNamesNoPath() {
        let token = LaunchLedgerRead.corrupt(
            quarantinedAt: URL(fileURLWithPath: "/Users/someone/launch-ledger.corrupt.jsonl")
        ).token

        XCTAssertFalse(token.contains("/"))
        XCTAssertEqual(token, "corrupt quarantined=yes")
    }
}

// MARK: - Refusing File Manager

/// Refuses to move anything aside, which is the failure that has to block writes rather than be
/// logged and continued.
private final class RefusingFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
