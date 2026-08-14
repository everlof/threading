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

    // MARK: - Fixtures

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
