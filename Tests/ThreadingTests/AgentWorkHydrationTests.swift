import XCTest
@testable import Threading

/// Observed work for a session Threading does not render: the resumable transcript scan under it,
/// and the store rules that keep repeated passes from counting the same call twice.
final class AgentWorkHydrationTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/")

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWorkHydrationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - The resumable scan

    func testClaudeCallsCarryTheRecordsOwnTime() throws {
        let url = try write([
            claudeToolRecord(id: "c1", name: "Read", input: ["file_path": "/repo/a.swift"],
                             at: "2026-08-14T10:00:00.000Z"),
            claudeToolRecord(id: "c2", name: "Edit", input: ["file_path": "/repo/b.swift"],
                             at: "2026-08-14T10:05:00.000Z")
        ])

        let scan = TranscriptReplay.toolCalls(at: url, kind: .claude, from: 0)

        XCTAssertEqual(scan.calls.map(\.callID), ["c1", "c2"])
        XCTAssertEqual(scan.calls.map(\.tool), [.read, .edit])
        // The point of reading records rather than replayed events: a real reading of when, so
        // recency is a fact rather than `distantPast`. It is also what keeps an old conversation
        // from lighting the map — and its glow timer — when it is first folded in.
        XCTAssertEqual(
            scan.calls.last?.date,
            TranscriptTimestamp.date(from: "2026-08-14T10:05:00.000Z")
        )
        XCTAssertEqual(scan.endOffset, try fileSize(url))
    }

    func testAResumedScanReadsOnlyWhatWasAppended() throws {
        let url = try write([
            claudeToolRecord(id: "c1", name: "Read", input: ["file_path": "/repo/a.swift"])
        ])
        let first = TranscriptReplay.toolCalls(at: url, kind: .claude, from: 0)
        XCTAssertEqual(first.calls.count, 1)

        try append(
            claudeToolRecord(id: "c2", name: "Edit", input: ["file_path": "/repo/b.swift"]),
            to: url
        )
        let second = TranscriptReplay.toolCalls(at: url, kind: .claude, from: first.endOffset)

        XCTAssertEqual(second.calls.map(\.callID), ["c2"])
        XCTAssertEqual(second.endOffset, try fileSize(url))
    }

    /// A resumable reader cannot tell a finished record from one the agent is halfway through
    /// writing, so it waits for the newline. Delivering the fragment would either drop its
    /// remainder or count the record twice, depending on where the position was left.
    func testATrailingRecordWaitsForItsNewline() throws {
        let url = try write([
            claudeToolRecord(id: "c1", name: "Read", input: ["file_path": "/repo/a.swift"])
        ])
        let partial = claudeToolRecord(
            id: "c2", name: "Edit", input: ["file_path": "/repo/b.swift"]
        )
        let split = partial.index(partial.startIndex, offsetBy: partial.count / 2)
        try appendRaw(String(partial[..<split]), to: url)

        let first = TranscriptReplay.toolCalls(at: url, kind: .claude, from: 0)
        XCTAssertEqual(first.calls.map(\.callID), ["c1"], "half a record was folded in")

        try appendRaw(String(partial[split...]) + "\n", to: url)
        let second = TranscriptReplay.toolCalls(at: url, kind: .claude, from: first.endOffset)

        XCTAssertEqual(second.calls.map(\.callID), ["c2"])
    }

    /// Not Claude-only, and not by a second parser: the same closed format set replay dispatches
    /// on carries the Codex rollout, patch envelope and all.
    func testCodexRolloutYieldsEveryFileItsPatchTouches() throws {
        let patch = """
        *** Begin Patch
        *** Update File: Sources/a.swift
        @@
        -old
        +new
        *** Add File: Sources/b.swift
        +created
        *** End Patch
        """
        let url = try write([codexPatchRecord(id: "c1", patch: patch)])

        let scan = TranscriptReplay.toolCalls(at: url, kind: .codex, from: 0)
        let signals = scan.calls.flatMap {
            AgentFileActivityClassifier.signals(tool: $0.tool, input: $0.input)
        }

        XCTAssertEqual(signals.map(\.path), ["Sources/a.swift", "Sources/b.swift"])
        XCTAssertTrue(signals.allSatisfy { $0.kind == .edit })
    }

    func testARuntimeWithNoTranscriptFormatReadsNothingAndStaysWhereItWas() throws {
        let url = try write([
            claudeToolRecord(id: "c1", name: "Read", input: ["file_path": "/repo/a.swift"])
        ])

        let scan = TranscriptReplay.toolCalls(at: url, kind: .grok, from: 0)

        XCTAssertTrue(scan.calls.isEmpty)
        XCTAssertEqual(scan.endOffset, 0)
    }

    // MARK: - The store's rules

    @MainActor
    func testHydrationFoldsATerminalSessionsTranscriptInAndResumes() async throws {
        let session = AgentSession(kind: .claude, title: "Terminal work")
        let projectID = ProjectID()
        let store = AgentWorkTraceStore(directory: directory)
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )
        let url = try write([
            claudeToolRecord(
                id: "c1", name: "Edit", input: ["file_path": repositoryRoot + "/CLAUDE.md"]
            )
        ])

        _ = store.presentation(for: target)
        store.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )

        let first = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.totalActionCount == 1 ? presentation : nil
        }
        XCTAssertEqual(first.touchedFileCount, 1)
        XCTAssertEqual(first.bins.reduce(0) { $0 + $1.editCount }, 1)

        // Asking again with nothing appended is the common case — every turn boundary, every
        // time the tab opens. It must change no reading.
        store.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.presentation(for: target)?.totalActionCount, 1)

        try append(
            claudeToolRecord(
                id: "c2", name: "Read", input: ["file_path": repositoryRoot + "/USER_GUIDE.md"]
            ),
            to: url
        )
        store.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )

        let second = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.totalActionCount == 2 ? presentation : nil
        }
        XCTAssertEqual(second.touchedFileCount, 2)
        XCTAssertEqual(second.bins.reduce(0) { $0 + $1.readCount }, 1)
    }

    /// The position survives the process, which the in-memory call-id dedupe cannot: a relaunch
    /// re-reading a transcript from the top would double every count in it.
    @MainActor
    func testAResumePointSurvivesAFreshStore() async throws {
        let session = AgentSession(kind: .claude, title: "Terminal work")
        let projectID = ProjectID()
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )
        let url = try write([
            claudeToolRecord(
                id: "c1", name: "Edit", input: ["file_path": repositoryRoot + "/CLAUDE.md"]
            )
        ])

        let first = AgentWorkTraceStore(directory: directory)
        _ = first.presentation(for: target)
        first.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )
        _ = try await eventually {
            let presentation = first.presentation(for: target)
            return presentation?.totalActionCount == 1 ? presentation : nil
        }

        // Persistence is trailing-coalesced, so let the quiet edge pass before reopening.
        try await Task.sleep(for: .seconds(1.3))
        let second = AgentWorkTraceStore(directory: directory)
        _ = second.presentation(for: target)
        second.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )

        let restored = try await eventually {
            second.presentation(for: target)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(restored.totalActionCount, 1, "the transcript was folded in twice")
        XCTAssertEqual(second.presentation(for: target)?.totalActionCount, 1)
    }

    /// A conversation that was rendered natively and now runs in a terminal already has its calls
    /// recorded exactly. Its transcript is adopted at the end rather than counted from the top.
    @MainActor
    func testATraceWithLiveWorkAdoptsTheTranscriptsEndInsteadOfCountingItAgain() async throws {
        let session = AgentSession(kind: .claude, title: "Was native")
        let projectID = ProjectID()
        let store = AgentWorkTraceStore(directory: directory)
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )
        let file = repositoryRoot + "/CLAUDE.md"
        let url = try write([claudeToolRecord(id: "c1", name: "Edit", input: ["file_path": file])])

        _ = store.presentation(for: target)
        store.record(
            streamEvent: .assistantMessage(blocks: [
                .toolUse(id: "c1", tool: .edit, input: ["file_path": .string(file)])
            ]),
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot
        )
        _ = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.totalActionCount == 1 ? presentation : nil
        }

        store.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.presentation(for: target)?.totalActionCount, 1)

        // Adoption is not deafness: what the terminal writes from here on is still counted.
        try append(
            claudeToolRecord(
                id: "c2", name: "Read", input: ["file_path": repositoryRoot + "/USER_GUIDE.md"]
            ),
            to: url
        )
        store.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )
        let grown = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.totalActionCount == 2 ? presentation : nil
        }
        XCTAssertEqual(grown.touchedFileCount, 2)
    }

    /// A file shorter than the position already consumed is a different conversation — a fork
    /// copied over it, a rewritten rollout. Reading the new file from the old position would mix
    /// the two, so the session starts over.
    @MainActor
    func testAShrunkTranscriptStartsTheSessionOver() async throws {
        let session = AgentSession(kind: .claude, title: "Replaced")
        let projectID = ProjectID()
        let store = AgentWorkTraceStore(directory: directory)
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )
        let url = try write([
            claudeToolRecord(
                id: "c1", name: "Edit", input: ["file_path": repositoryRoot + "/CLAUDE.md"]
            ),
            claudeToolRecord(
                id: "c2", name: "Edit", input: ["file_path": repositoryRoot + "/USER_GUIDE.md"]
            ),
            claudeToolRecord(
                id: "c3", name: "Edit", input: ["file_path": repositoryRoot + "/IMPROVEMENTS.md"]
            )
        ])

        _ = store.presentation(for: target)
        store.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )
        _ = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.totalActionCount == 3 ? presentation : nil
        }

        try write([
            claudeToolRecord(
                id: "d1", name: "Read", input: ["file_path": repositoryRoot + "/CLAUDE.md"]
            )
        ], to: url)
        store.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )

        let restarted = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.totalActionCount == 1 ? presentation : nil
        }
        XCTAssertEqual(restarted.touchedFileCount, 1)
        XCTAssertEqual(restarted.bins.reduce(0) { $0 + $1.editCount }, 0)
    }

    // MARK: - Cost

    /// The scan itself, without a store, a presentation or a repository atlas around it: what one
    /// pass costs, and what a pass with nothing new to read costs.
    func testAResumedPassOverALongTranscriptReadsNothing() throws {
        let calls = 2_000
        let url = try write((0..<calls).map { index in
            claudeToolRecord(
                id: "c\(index)", name: "Read", input: ["file_path": "/repo/file-\(index).swift"]
            )
        })

        let coldStart = DispatchTime.now().uptimeNanoseconds
        let cold = TranscriptReplay.toolCalls(at: url, kind: .claude, from: 0)
        let coldMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000

        let warmStart = DispatchTime.now().uptimeNanoseconds
        let warm = TranscriptReplay.toolCalls(at: url, kind: .claude, from: cold.endOffset)
        let warmMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - warmStart) / 1_000_000

        XCTAssertEqual(cold.calls.count, calls)
        XCTAssertTrue(warm.calls.isEmpty)
        XCTAssertEqual(warm.endOffset, cold.endOffset)
        // The shape, not a threshold: re-reading is what the resume point removes, and the margin
        // between the two is wide enough that a regression to a full re-read cannot hide in it.
        XCTAssertLessThan(warmMilliseconds, coldMilliseconds)
        print("scan: \(calls) calls in \(coldMilliseconds)ms, resumed pass \(warmMilliseconds)ms")
    }

    /// The property the trigger sites rely on: a pass with nothing to read costs a file-size
    /// comparison, so a turn ending, an activity edge and a tab opening can all ask freely.
    @MainActor
    func testALongTranscriptFoldsInOnceAndCostsNothingWhenAskedAgain() async throws {
        let session = AgentSession(kind: .claude, title: "Long")
        let projectID = ProjectID()
        let store = AgentWorkTraceStore(directory: directory)
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )
        let calls = 2_000
        let url = try write((0..<calls).map { index in
            claudeToolRecord(
                id: "c\(index)",
                name: "Read",
                input: ["file_path": repositoryRoot + "/Sources/file-\(index % 200).swift"]
            )
        })

        _ = store.presentation(for: target)
        store.record(
            transcriptAt: url, kind: .claude, projectID: projectID,
            session: session, rootPath: repositoryRoot
        )
        let folded = try await eventually(timeout: .seconds(20)) {
            let presentation = store.presentation(for: target)
            return presentation?.totalActionCount == calls ? presentation : nil
        }
        XCTAssertEqual(folded.totalActionCount, calls)

        // What a trigger costs the main actor, which is the number that decides whether a turn
        // boundary or an activity edge may call this: twenty passes, measured on the caller's
        // side, since every byte of the work itself happens on the store's own queue.
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 {
            store.record(
                transcriptAt: url, kind: .claude, projectID: projectID,
                session: session, rootPath: repositoryRoot
            )
        }
        let mainActorMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertLessThan(mainActorMilliseconds, 20, "a trigger is doing work on the main actor")

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            store.presentation(for: target)?.totalActionCount,
            calls,
            "a repeated pass counted the same transcript again"
        )
        print("hydration: \(calls) calls; 20 further passes cost \(mainActorMilliseconds)ms on main")
    }

    // MARK: - Coalescing

    /// Callers ask bluntly — a turn boundary, an activity edge, every render of the pane — and the
    /// window collapses a burst into one trailing pass rather than dropping the last ask, which is
    /// the one that knows the turn ended.
    func testABurstOfAsksCollapsesIntoOneTrailingPass() {
        var throttle = AgentWorkHydrationThrottle()
        let session = SessionID()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertEqual(throttle.admit(session, now: start), .now)
        // Compared with a tolerance: a `Date` this far from its reference cannot hold a fifth of
        // a second exactly, so the remaining window comes back as 0.79999995.
        guard case .after(let delay) = throttle.admit(
            session, now: start.addingTimeInterval(0.2)
        ) else {
            return XCTFail("an ask inside the window should have been scheduled, not run")
        }
        XCTAssertEqual(delay, AgentWorkHydrationThrottle.quietWindow - 0.2, accuracy: 0.001)
        XCTAssertEqual(throttle.admit(session, now: start.addingTimeInterval(0.3)),
                       .alreadyScheduled)
        XCTAssertEqual(throttle.admit(session, now: start.addingTimeInterval(0.9)),
                       .alreadyScheduled)

        // The scheduled pass fires and is admitted; the window opens again behind it.
        throttle.releaseSchedule(for: session)
        XCTAssertEqual(throttle.admit(session, now: start.addingTimeInterval(1)), .now)
    }

    func testAQuietSessionIsNeverDelayed() {
        var throttle = AgentWorkHydrationThrottle()
        let session = SessionID()
        let other = SessionID()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertEqual(throttle.admit(session, now: start), .now)
        XCTAssertEqual(throttle.admit(session, now: start.addingTimeInterval(5)), .now)
        // One session's burst does not ration another's.
        XCTAssertEqual(throttle.admit(other, now: start.addingTimeInterval(5)), .now)
    }

    // MARK: - The git-observed floor

    /// The floor's whole point: a file a turn changed that no tool ever named. It is counted, but
    /// never as a read or an edit — the tree pair knows the file differs and nothing more.
    @MainActor
    func testAnObservedChangeIsCountedApartFromReadsAndEdits() async throws {
        let session = AgentSession(kind: .grok, title: "Terminal work")
        let projectID = ProjectID()
        let store = AgentWorkTraceStore(directory: directory)
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )

        _ = store.presentation(for: target)
        store.record(
            observedChanges: ["CLAUDE.md", "USER_GUIDE.md"],
            checkpointOrdinal: 1,
            turnStart: turnStart,
            turnEnd: turnEnd,
            claimedPaths: nil,
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot
        )

        let presentation = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.observedChangeCount == 2 ? presentation : nil
        }
        XCTAssertEqual(presentation.touchedFileCount, 2)
        XCTAssertEqual(presentation.bins.reduce(0) { $0 + $1.editCount }, 0, "a delta is not an edit")
        XCTAssertEqual(presentation.bins.reduce(0) { $0 + $1.readCount }, 0, "a delta is not a read")
        XCTAssertEqual(presentation.totalActionCount, 0, "a delta is not a tool call")
    }

    /// A checkpoint's trees are immutable, so a second pass over the same turn would add every
    /// path in it again — the floor's version of re-counting a transcript from the top.
    @MainActor
    func testTheSameCheckpointIsNeverFoldedInTwice() async throws {
        let session = AgentSession(kind: .grok, title: "Terminal work")
        let projectID = ProjectID()
        let store = AgentWorkTraceStore(directory: directory)
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )
        _ = store.presentation(for: target)

        for _ in 0..<3 {
            store.record(
                observedChanges: ["CLAUDE.md"],
                checkpointOrdinal: 1,
                turnStart: turnStart,
                turnEnd: turnEnd,
                claimedPaths: nil,
                projectID: projectID,
                session: session,
                rootPath: repositoryRoot
            )
        }
        let first = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.observedChangeCount == 1 ? presentation : nil
        }
        XCTAssertEqual(first.touchedFileCount, 1)

        // The next turn still lands: the guard is "this ordinal or older", not "any ordinal".
        store.record(
            observedChanges: ["CLAUDE.md"],
            checkpointOrdinal: 2,
            turnStart: turnStart,
            turnEnd: turnEnd,
            claimedPaths: nil,
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot
        )
        let second = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.observedChangeCount == 2 ? presentation : nil
        }
        XCTAssertEqual(second.touchedFileCount, 1, "the same file changed twice is one file")
    }

    /// A path the turn's own edit tools named is already exactly attributed. Recording it again
    /// as an anonymous delta would double a file the panel can describe properly.
    @MainActor
    func testAPathTheTurnClaimedIsLeftToItsExactSignal() async throws {
        let session = AgentSession(kind: .claude, title: "Terminal work")
        let projectID = ProjectID()
        let store = AgentWorkTraceStore(directory: directory)
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )
        _ = store.presentation(for: target)

        store.record(
            observedChanges: ["CLAUDE.md", "USER_GUIDE.md"],
            checkpointOrdinal: 1,
            turnStart: turnStart,
            turnEnd: turnEnd,
            claimedPaths: ["CLAUDE.md"],
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot
        )

        let presentation = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.observedChangeCount == 1 ? presentation : nil
        }
        XCTAssertEqual(presentation.touchedFileCount, 1, "the claimed path was recorded twice")
    }

    /// The same rule for a session whose claims were never tracked: a transcript-fed terminal
    /// chat records its edits exactly, and the delta for that same turn must not say them again.
    /// The window is what tells this turn's exact edit from one in a different turn.
    @MainActor
    func testAnExactEditInsideTheTurnsWindowIsNotSaidTwice() async throws {
        let session = AgentSession(kind: .claude, title: "Terminal work")
        let projectID = ProjectID()
        let store = AgentWorkTraceStore(directory: directory)
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )
        _ = store.presentation(for: target)

        // One edit inside this turn, one before it began.
        store.record(
            streamEvent: edit(of: repositoryRoot + "/CLAUDE.md"),
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot,
            at: turnStart.addingTimeInterval(1)
        )
        store.record(
            streamEvent: edit(of: repositoryRoot + "/USER_GUIDE.md", callID: "older"),
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot,
            at: turnStart.addingTimeInterval(-600)
        )
        _ = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.bins.reduce(0) { $0 + $1.editCount } == 2 ? presentation : nil
        }

        store.record(
            observedChanges: ["CLAUDE.md", "USER_GUIDE.md"],
            checkpointOrdinal: 1,
            turnStart: turnStart,
            turnEnd: turnEnd,
            claimedPaths: nil,
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot
        )

        let presentation = try await eventually {
            let presentation = store.presentation(for: target)
            return presentation?.observedChangeCount == 1 ? presentation : nil
        }
        XCTAssertEqual(
            presentation.bins.reduce(0) { $0 + $1.editCount }, 2,
            "the exact edits are untouched by the floor"
        )
        XCTAssertEqual(presentation.touchedFileCount, 2)
    }

    /// The resume point is persisted for the same reason the transcript's offset is: a relaunch
    /// that re-reads every retained checkpoint would count every path in all of them again.
    @MainActor
    func testTheObservedResumePointSurvivesAFreshStore() async throws {
        let session = AgentSession(kind: .grok, title: "Terminal work")
        let projectID = ProjectID()
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )

        let first = AgentWorkTraceStore(directory: directory)
        _ = first.presentation(for: target)
        first.record(
            observedChanges: ["CLAUDE.md"],
            checkpointOrdinal: 4,
            turnStart: turnStart,
            turnEnd: turnEnd,
            claimedPaths: nil,
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot
        )
        _ = try await eventually {
            let presentation = first.presentation(for: target)
            return presentation?.observedChangeCount == 1 ? presentation : nil
        }

        // Persistence is trailing-coalesced, so let the quiet edge pass before reopening.
        try await Task.sleep(for: .seconds(1.3))
        let second = AgentWorkTraceStore(directory: directory)
        _ = second.presentation(for: target)
        let resumed: Int? = await withCheckedContinuation { continuation in
            second.observedCheckpointOrdinal(sessionID: session.id, projectID: projectID) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(resumed, 4)

        second.record(
            observedChanges: ["CLAUDE.md"],
            checkpointOrdinal: 4,
            turnStart: turnStart,
            turnEnd: turnEnd,
            claimedPaths: nil,
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot
        )
        let reopened = try await eventually { second.presentation(for: target) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            reopened.observedChangeCount, 1,
            "the checkpoint was folded in twice across a relaunch"
        )
    }

    /// A refactoring turn is the floor's stress case: one checkpoint whose tree pair differs on
    /// thousands of paths, folded in while the tab is open. Every path is applied through the same
    /// incremental path a live event takes, and the main actor's share is one enqueue.
    @MainActor
    func testALargeTurnFoldsInOffMainAndCostsTheCallerOneEnqueue() async throws {
        let session = AgentSession(kind: .grok, title: "Refactor everything")
        let projectID = ProjectID()
        let store = AgentWorkTraceStore(directory: directory)
        let target = AgentWorkTarget.session(
            projectID: projectID, sessionID: session.id, rootPath: repositoryRoot, detailed: false
        )
        let paths = (0..<4_000).map { "Sources/Area\($0 / 200)/file-\($0).swift" }
        _ = store.presentation(for: target)

        let start = DispatchTime.now().uptimeNanoseconds
        store.record(
            observedChanges: paths,
            checkpointOrdinal: 1,
            turnStart: turnStart,
            turnEnd: turnEnd,
            claimedPaths: nil,
            projectID: projectID,
            session: session,
            rootPath: repositoryRoot
        )
        let mainActorMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertLessThan(mainActorMilliseconds, 20, "the fold is running on the main actor")

        let folded = try await eventually(timeout: .seconds(30)) {
            let presentation = store.presentation(for: target)
            return presentation?.observedChangeCount == paths.count ? presentation : nil
        }
        XCTAssertEqual(folded.touchedFileCount, paths.count)

        // And the pass that follows it: every later trigger finds this checkpoint consumed and
        // stops at an integer comparison on the store's own queue.
        let repeatStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 {
            store.record(
                observedChanges: paths,
                checkpointOrdinal: 1,
                turnStart: turnStart,
                turnEnd: turnEnd,
                claimedPaths: nil,
                projectID: projectID,
                session: session,
                rootPath: repositoryRoot
            )
        }
        let repeatMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - repeatStart) / 1_000_000
        XCTAssertLessThan(repeatMilliseconds, 20)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(
            store.presentation(for: target)?.observedChangeCount,
            paths.count,
            "a repeated pass counted the same checkpoint again"
        )
        print(
            "floor: \(paths.count) paths; enqueue \(mainActorMilliseconds)ms, "
            + "20 further passes \(repeatMilliseconds)ms on main"
        )
    }

    /// Claims are stored relative to the checkout; the trace and the changed paths are relative
    /// to the session's execution folder. A project added as a subdirectory of a repository makes
    /// those different, and an unshifted comparison would match nothing at all — recording every
    /// file the turn's own tools named a second time, as an anonymous delta.
    @MainActor
    func testClaimedPathsAreMovedOntoTheAxisTheTraceUses() {
        let checkpoint = checkpoint(
            checkout: "/repo",
            claims: ["app/Sources/A.swift", "docs/README.md"]
        )

        XCTAssertEqual(
            AgentWorkHydration.claims(of: checkpoint, relativeTo: "/repo/app"),
            ["Sources/A.swift"],
            "a claim outside the execution folder describes no mark this card can draw"
        )
        // The ordinary case: the execution folder is the checkout, so nothing shifts.
        XCTAssertEqual(
            AgentWorkHydration.claims(of: checkpoint, relativeTo: "/repo"),
            ["app/Sources/A.swift", "docs/README.md"]
        )
    }

    // MARK: - Fixtures

    private func checkpoint(checkout: String, claims: [String]) -> GitTurnCheckpoint {
        GitTurnCheckpoint(
            id: GitTurnCheckpointID(),
            projectID: nil,
            sessionID: SessionID(),
            ordinal: 1,
            userTurnID: "turn",
            assistantTurnID: "turn",
            providerTurnID: nil,
            logicalProjectPath: checkout,
            executionCheckoutPath: checkout,
            repositoryIdentity: "identity",
            worktreeIdentity: "identity",
            beforeRef: nil,
            afterRef: nil,
            beforeTreeHash: nil,
            afterTreeHash: nil,
            status: .complete,
            requestedAt: turnStart,
            beforeCapturedAt: turnStart,
            finalRequestedAt: turnEnd,
            completedAt: turnEnd,
            failureDescription: nil,
            overlappingSessionIDs: nil,
            claimedEditPaths: claims,
            claimedEditsOverflowed: false
        )
    }

    private var turnStart: Date { Date(timeIntervalSinceReferenceDate: 800_000_000) }
    private var turnEnd: Date { turnStart.addingTimeInterval(120) }

    private func edit(of path: String, callID: String = "call-1") -> StreamEvent {
        .assistantMessage(blocks: [
            .toolUse(id: callID, tool: .edit, input: ["file_path": .string(path)])
        ])
    }

    private var repositoryRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private func claudeToolRecord(
        id: String,
        name: String,
        input: [String: String],
        at timestamp: String = "2026-08-14T10:00:00.000Z"
    ) -> String {
        record([
            "type": "assistant",
            "timestamp": timestamp,
            "message": ["content": [
                ["type": "tool_use", "id": id, "name": name, "input": input]
            ]]
        ])
    }

    private func codexPatchRecord(
        id: String,
        patch: String,
        at timestamp: String = "2026-08-14T10:00:00.000Z"
    ) -> String {
        record([
            "type": "response_item",
            "timestamp": timestamp,
            "payload": [
                "type": "function_call",
                "name": "apply_patch",
                "call_id": id,
                "arguments": patch
            ]
        ])
    }

    private func record(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
    }

    @discardableResult
    private func write(_ records: [String], to url: URL? = nil) throws -> URL {
        let destination = url ?? directory.appendingPathComponent("transcript-\(UUID()).jsonl")
        try (records.joined(separator: "\n") + "\n").write(
            to: destination, atomically: true, encoding: .utf8
        )
        return destination
    }

    private func append(_ record: String, to url: URL) throws {
        try appendRaw(record + "\n", to: url)
    }

    private func appendRaw(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func eventually<T>(
        timeout: Duration = .seconds(5),
        _ value: @escaping @MainActor () -> T?
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let result = await value() { return result }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "AgentWorkHydrationTests", code: 1)
    }
}
