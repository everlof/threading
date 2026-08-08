import XCTest
@testable import Threading

final class FileActivityMapTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Universe

    func testUniverseIsSortedDedupedAndTrimmed() {
        let map = FileActivityMap(files: [
            "./b.swift", "a/two.swift", "a/one.swift", "b.swift", "  ", "a/two.swift"
        ])

        XCTAssertEqual(map.entries.map(\.path), ["a/one.swift", "a/two.swift", "b.swift"])
        XCTAssertFalse(map.entries.contains(where: \.isNew))
    }

    func testRunOrdinalsFollowParentDirectories() {
        let map = FileActivityMap(files: [
            "Sources/UI/a.swift", "Sources/UI/b.swift", "Sources/Core/c.swift", "README.md"
        ])

        // Sorted: README.md, Sources/Core/c, Sources/UI/a, Sources/UI/b — root files are one
        // run, and each leaf directory is its own, so regions are directories rather than
        // the giant single run everything under `Sources/` would make.
        XCTAssertEqual(map.entries.map(\.runOrdinal), [0, 1, 2, 2])
    }

    // MARK: - Recording

    func testAbsolutePathsRelativizeAgainstTheRoot() {
        var map = FileActivityMap(files: ["Sources/a.swift"], root: "/repo/project/")

        let index = map.record(.read, path: "/repo/project/Sources/a.swift", at: now)
        XCTAssertEqual(index, 0)
        XCTAssertNotNil(map.entries[0].lastRead)
    }

    func testPathsOutsideTheRootAreIgnoredNotForceFitted() {
        var map = FileActivityMap(files: ["Sources/a.swift"], root: "/repo/project")

        XCTAssertNil(map.record(.read, path: "/etc/hosts", at: now))
        XCTAssertNil(map.record(.edit, path: "/repo/project-other/b.swift", at: now))
        XCTAssertEqual(map.entries.count, 1)
    }

    func testUnknownPathInsertsSortedAndMarkedNew() {
        var map = FileActivityMap(files: ["a.swift", "c.swift"])

        let index = map.record(.edit, path: "b.swift", at: now)
        XCTAssertEqual(index, 1)
        XCTAssertEqual(map.entries.map(\.path), ["a.swift", "b.swift", "c.swift"])
        XCTAssertTrue(map.entries[1].isNew)

        // The index table must follow the shift, or every later mark lights the wrong file.
        XCTAssertEqual(map.record(.read, path: "c.swift", at: now), 2)
    }

    // MARK: - Heat

    func testHeatFadesToTheResidualAndHoldsThere() {
        XCTAssertEqual(FileActivityMap.heat(since: nil, now: now), 0)
        XCTAssertEqual(FileActivityMap.heat(since: now, now: now), 1)

        let atDuration = FileActivityMap.heat(
            since: now.addingTimeInterval(-FileActivityMap.Metrics.glowDuration),
            now: now
        )
        XCTAssertEqual(atDuration, FileActivityMap.Metrics.residualHeat, accuracy: 0.001)

        let longAfter = FileActivityMap.heat(since: now.addingTimeInterval(-9999), now: now)
        XCTAssertEqual(longAfter, FileActivityMap.Metrics.residualHeat, accuracy: 0.001)

        // A touch stamped ahead of the clock reads as fresh rather than as negative age.
        XCTAssertEqual(FileActivityMap.heat(since: now.addingTimeInterval(60), now: now), 1)
    }

    func testActiveGlowEndsWithTheFadeNotWithTheResidual() {
        var map = FileActivityMap(files: ["a.swift"])
        map.record(.read, path: "a.swift", at: now.addingTimeInterval(-10))

        XCTAssertTrue(map.hasActiveGlow(now: now))
        XCTAssertFalse(map.hasActiveGlow(
            now: now.addingTimeInterval(FileActivityMap.Metrics.glowDuration + 10)
        ))
    }

    // MARK: - Classification

    func testClaudeVocabularyClassifies() {
        let read = FileActivityMap.touches(tool: .read, input: ["file_path": "/p/a.swift"])
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.kind, .read)
        XCTAssertEqual(read.first?.path, "/p/a.swift")

        for tool in [ToolIdentity.edit, .multiEdit, .write] {
            let touches = FileActivityMap.touches(tool: tool, input: ["file_path": "/p/a.swift"])
            XCTAssertEqual(touches.first?.kind, .edit, "\(tool) should classify as an edit")
        }

        let notebook = FileActivityMap.touches(
            tool: .notebookEdit, input: ["notebook_path": "/p/n.ipynb"]
        )
        XCTAssertEqual(notebook.first?.path, "/p/n.ipynb")
    }

    func testCodexPatchYieldsEveryFileItTouches() {
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
        let touches = FileActivityMap.touches(tool: .edit, input: ["patch": patch])

        XCTAssertEqual(touches.map(\.path), ["Sources/a.swift", "Sources/b.swift"])
        XCTAssertTrue(touches.allSatisfy { $0.kind == .edit })
    }

    /// A patch written with CRLF endings still names the same files.
    ///
    /// Swift strings are sequences of grapheme clusters and `\r\n` is a **single** one, so
    /// `split(separator: "\n")` finds no separator anywhere in a CRLF patch: the whole envelope
    /// came back as one line, nothing matched a file header, and `paths` returned `[]` — not a
    /// path with a stray carriage return, no path at all. `lines` collapsed the same way, so a
    /// Codex edit rendered as an anonymous row with no diff, which is precisely the bug
    /// `CodexPatch` was written to fix, reappearing for anything CRLF.
    func testACRLFPatchNamesTheSameFilesAsAnLFOne() {
        let patch = [
            "*** Begin Patch",
            "*** Update File: Sources/a.swift",
            "@@",
            "-old",
            "+new",
            "*** Add File: Sources/b.swift",
            "+created",
            "*** End Patch"
        ].joined(separator: "\r\n")

        XCTAssertEqual(
            CodexPatch.paths(in: patch),
            ["Sources/a.swift", "Sources/b.swift"],
            "a carriage return survived onto the path"
        )
        XCTAssertEqual(CodexPatch.firstPath(in: patch), "Sources/a.swift")
    }

    func testDirectoryLevelAndUnparsedToolsStaySilent() {
        // A Grep names a directory, not the files read inside it; a Bash command would need
        // the shell parsed. Guessing marks poisons the true ones.
        XCTAssertTrue(FileActivityMap.touches(tool: .grep, input: ["path": "/p"]).isEmpty)
        XCTAssertTrue(FileActivityMap.touches(tool: .glob, input: ["path": "/p"]).isEmpty)
        XCTAssertTrue(FileActivityMap.touches(tool: .bash, input: ["command": "cat a"]).isEmpty)
        XCTAssertTrue(FileActivityMap.touches(tool: .read, input: [:]).isEmpty)
    }

    // MARK: - Layout

    func testLayoutHoldsEveryMarkInsideEveryPane() {
        let counts = [1, 50, 438, 4966]
        let sizes = [CGSize(width: 56, height: 900),
                     CGSize(width: 300, height: 1000),
                     CGSize(width: 120, height: 600)]

        for count in counts {
            for size in sizes {
                guard let layout = FileActivityMap.Layout.compute(count: count, size: size) else {
                    XCTFail("No layout for \(count) files at \(size)")
                    continue
                }

                XCTAssertLessThanOrEqual(layout.contentWidth, size.width + 0.5)
                XCTAssertGreaterThanOrEqual(
                    layout.columnCount * layout.rowsPerColumn, count,
                    "\(count) files at \(size): grid too small"
                )

                let last = layout.rect(at: count - 1)
                XCTAssertLessThanOrEqual(last.maxX, size.width + 0.5)
                XCTAssertLessThanOrEqual(last.maxY, size.height + 0.5)
                XCTAssertGreaterThan(layout.markHeight, 0)
            }
        }
    }

    func testLayoutPrefersRoomyPitchesWhenTheyFit() {
        // 438 files in 300×1000: pitch 4 gives 250 rows a column, two columns fit easily.
        let layout = FileActivityMap.Layout.compute(
            count: 438, size: CGSize(width: 300, height: 1000)
        )
        XCTAssertEqual(layout?.rowPitch, 4)
        XCTAssertEqual(layout?.columnCount, 2)
    }

    func testLayoutRefusesTheUndrawable() {
        XCTAssertNil(FileActivityMap.Layout.compute(count: 0, size: CGSize(width: 300, height: 1000)))
        XCTAssertNil(FileActivityMap.Layout.compute(count: 10, size: CGSize(width: 4, height: 1000)))
    }

    // MARK: - Agent Work Atlas

    func testRepositoryAtlasBoundsBothProjectionsAndKeepsAStableOverflowBin() {
        let files = (0..<20_000).map { "Sources/Feature\($0 / 100)/file-\($0).swift" }
        let atlas = RepositoryFileAtlas(files: files)

        XCTAssertLessThanOrEqual(atlas.rail.seeds.count, RepositoryFileAtlas.Limits.railBins)
        XCTAssertLessThanOrEqual(atlas.detail.seeds.count, RepositoryFileAtlas.Limits.detailBins)
        XCTAssertEqual(atlas.rail.repositoryFileCount, files.count)
        XCTAssertTrue(atlas.rail.seeds.last?.isOverflow == true)

        let existing = try? XCTUnwrap(atlas.binIndex(for: files[0], detail: false))
        let created = try? XCTUnwrap(atlas.binIndex(for: "Sources/New/file.swift", detail: false))
        XCTAssertNotEqual(existing, created)
        XCTAssertEqual(created, atlas.rail.seeds.indices.last)
    }

    func testSessionProjectionPreservesCountsWhileBoundingDrawWork() {
        let files = (0..<10_000).map { "Sources/Area\($0 / 100)/file-\($0).swift" }
        let atlas = RepositoryFileAtlas(files: files)
        let sessionID = SessionID()
        var trace = AgentSessionWorkTrace()

        for index in stride(from: 0, to: files.count, by: 7) {
            _ = trace.recordFile(.read, path: files[index], root: nil, at: now)
            if index.isMultiple(of: 14) {
                _ = trace.recordFile(.edit, path: files[index], root: nil, at: now)
            }
        }
        _ = trace.recordFile(.edit, path: "Sources/New/file.swift", root: nil, at: now)

        let projection = AgentWorkPresentation.session(
            trace, sessionID: sessionID, atlas: atlas, detailed: false
        )
        XCTAssertLessThanOrEqual(projection.bins.count, RepositoryFileAtlas.Limits.railBins)
        XCTAssertEqual(projection.touchedFileCount, trace.files.count)
        XCTAssertEqual(projection.bins.reduce(0) { $0 + $1.readCount }, trace.files.count - 1)
        XCTAssertEqual(
            projection.bins.reduce(0) { $0 + $1.editCount },
            trace.files.values.reduce(0) { $0 + $1.editCount }
        )
        XCTAssertEqual(projection.bins.last?.touchedFileCount, 1)
    }

    func testProjectProjectionCombinesAgentsWithoutLosingProvenance() {
        let shared = "Sources/Shared.swift"
        let atlas = RepositoryFileAtlas(files: [shared, "Sources/Other.swift"])
        let firstID = SessionID()
        let secondID = SessionID()
        var first = AgentSessionWorkTrace()
        first.sessionTitle = "API agent"
        first.agentLabel = "Codex"
        _ = first.recordFile(.edit, path: shared, root: nil, at: now)
        first.recordAction(category: .shell, operation: "exec", at: now, sessionID: firstID)

        var second = AgentSessionWorkTrace()
        second.sessionTitle = "Tests agent"
        second.agentLabel = "Claude"
        _ = second.recordFile(.read, path: shared, root: nil, at: now)
        second.recordAction(category: .subagent, operation: "Agent", at: now, sessionID: secondID)

        let traces = [firstID: first, secondID: second]
        let aggregate = AgentProjectWorkAggregate(traces: traces)
        let projection = AgentWorkPresentation.project(
            aggregate,
            traces: traces,
            projectID: ProjectID(),
            atlas: atlas,
            detailed: true
        )

        XCTAssertEqual(projection.touchedFileCount, 1)
        XCTAssertEqual(projection.categoryCounts[.shell], 1)
        XCTAssertEqual(projection.categoryCounts[.subagent], 1)
        XCTAssertEqual(
            Set(projection.recentContributors.map(\.sessionID)),
            Set([firstID, secondID])
        )
        XCTAssertEqual(projection.bins.map(\.contributorCount).max(), 2)
    }

    func testProjectAggregateRemovesOnlyTheDepartingAgentsContribution() {
        let shared = "Sources/Shared.swift"
        let firstID = SessionID()
        let secondID = SessionID()
        let older = now.addingTimeInterval(-30)
        var first = AgentSessionWorkTrace()
        _ = first.recordFile(.read, path: shared, root: nil, at: older)
        first.recordAction(category: .shell, operation: "exec", at: older, sessionID: firstID)

        var second = AgentSessionWorkTrace()
        _ = second.recordFile(.read, path: shared, root: nil, at: now)
        _ = second.recordFile(.edit, path: shared, root: nil, at: now)
        second.recordAction(category: .shell, operation: "exec", at: now, sessionID: secondID)

        var traces = [firstID: first, secondID: second]
        var aggregate = AgentProjectWorkAggregate(traces: traces)
        traces.removeValue(forKey: secondID)
        aggregate.remove(second, sessionID: secondID, remainingTraces: traces)

        XCTAssertEqual(aggregate.files[shared]?.work.readCount, 1)
        XCTAssertEqual(aggregate.files[shared]?.work.editCount, 0)
        XCTAssertEqual(aggregate.files[shared]?.work.lastRead, older)
        XCTAssertNil(aggregate.files[shared]?.work.lastEdit)
        XCTAssertEqual(aggregate.files[shared]?.contributors, Set([firstID]))
        XCTAssertEqual(aggregate.categoryCounts[.shell], 1)
        XCTAssertEqual(aggregate.recentActions.map(\.sessionID), [firstID])
        XCTAssertEqual(aggregate.contributingSessionIDs, Set([firstID]))
    }

    @MainActor
    func testTraceStoreLoadsProjectsOffPathAndRestoresPersistedSparseWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWorkTraceStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectID = ProjectID()
        let session = AgentSession(kind: .codex, title: "Map the work")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let target = AgentWorkTarget.session(
            projectID: projectID,
            sessionID: session.id,
            rootPath: root,
            detailed: false
        )
        let event = StreamEvent.assistantMessage(blocks: [
            .toolUse(
                id: "call-1",
                tool: .edit,
                input: ["file_path": .string(root + "/CLAUDE.md")]
            )
        ])
        let providerEvent = ProviderExecutionEvent(
            category: .filesystem,
            phase: .requested,
            operation: "Edit",
            callID: "call-1",
            input: .object(["file_path": .string(root + "/CLAUDE.md")]),
            output: nil,
            fidelity: .exact
        )

        let first = AgentWorkTraceStore(directory: directory)
        _ = first.presentation(for: target)
        first.record(
            providerEvent: providerEvent,
            projectID: projectID,
            session: session,
            rootPath: root,
            at: now
        )
        // The normalized stream carries the same request. It must not double the action or edit.
        first.record(
            streamEvent: event,
            projectID: projectID,
            session: session,
            rootPath: root,
            at: now
        )

        let firstPresentation = try await eventually {
            first.presentation(for: target)
        }
        XCTAssertEqual(firstPresentation.touchedFileCount, 1)
        XCTAssertEqual(firstPresentation.bins.reduce(0) { $0 + $1.editCount }, 1)
        XCTAssertEqual(firstPresentation.totalActionCount, 1)

        // Persistence is trailing-coalesced so active work never clones a large trace on the
        // main actor. Let the quiet edge pass, then prove a fresh store restores it.
        try await Task.sleep(for: .seconds(1.3))
        let second = AgentWorkTraceStore(directory: directory)
        let restored = try await eventually {
            second.presentation(for: target)
        }
        XCTAssertEqual(restored.touchedFileCount, 1)
        XCTAssertEqual(restored.bins.reduce(0) { $0 + $1.editCount }, 1)
    }

    /// Opt-in fixture used by `scripts/profile_threading.sh agent-work-stress`.
    func testAgentWorkProjectionStressBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_AGENT_WORK_STRESS"] == "1",
            "Set THREADING_AGENT_WORK_STRESS=1 to run the 100k-file benchmark"
        )

        let fileCount = 100_000
        let agentCount = 64
        let touchesPerAgent = 1_000
        let files = (0..<fileCount).map {
            "modules/mod-\(String(format: "%03d", $0 / 1_000))/src/file-\(String(format: "%05d", $0)).swift"
        }

        let atlasStarted = DispatchTime.now().uptimeNanoseconds
        let atlas = RepositoryFileAtlas(files: files)
        let atlasEnded = DispatchTime.now().uptimeNanoseconds

        var traces: [SessionID: AgentSessionWorkTrace] = [:]
        let mutationStarted = DispatchTime.now().uptimeNanoseconds
        for agent in 0..<agentCount {
            let sessionID = SessionID()
            var trace = AgentSessionWorkTrace()
            trace.sessionTitle = "Agent \(agent)"
            for touch in 0..<touchesPerAgent {
                // Co-prime strides produce overlap and spread without a random benchmark.
                let index = (agent * 997 + touch * 101) % fileCount
                _ = trace.recordFile(
                    touch.isMultiple(of: 5) ? .edit : .read,
                    path: files[index],
                    root: nil,
                    at: now
                )
            }
            traces[sessionID] = trace
        }
        let mutationEnded = DispatchTime.now().uptimeNanoseconds

        let aggregateStarted = DispatchTime.now().uptimeNanoseconds
        let aggregate = AgentProjectWorkAggregate(traces: traces)
        let aggregateEnded = DispatchTime.now().uptimeNanoseconds

        let projectionStarted = DispatchTime.now().uptimeNanoseconds
        let projection = AgentWorkPresentation.project(
            aggregate,
            traces: traces,
            projectID: ProjectID(),
            atlas: atlas,
            detailed: true
        )
        let projectionEnded = DispatchTime.now().uptimeNanoseconds

        var liveTrace = AgentSessionWorkTrace()
        var liveAggregate = AgentProjectWorkAggregate()
        var liveProjection = projection
        let liveSessionID = SessionID()
        let liveEventCount = 100_000
        let liveStarted = DispatchTime.now().uptimeNanoseconds
        for event in 0..<liveEventCount {
            let path = files[(event * 101) % fileCount]
            let kind: AgentFileActivityKind = event.isMultiple(of: 5) ? .edit : .read
            liveTrace.files[path, default: AgentFileWork()].record(kind, at: now)
            let firstProject = liveAggregate.files[path]?.work.isTouched != true
            liveAggregate.recordFile(
                kind, path: path, sessionID: liveSessionID, at: now
            )
            let bin = try XCTUnwrap(atlas.binIndex(for: path, detail: true))
            liveProjection.bins[bin].record(
                kind, at: now, isFirstTouch: firstProject
            )
        }
        let liveEnded = DispatchTime.now().uptimeNanoseconds

        XCTAssertLessThanOrEqual(projection.bins.count, RepositoryFileAtlas.Limits.detailBins)
        XCTAssertEqual(projection.repositoryFileCount, fileCount)
        XCTAssertEqual(projection.recentContributors.count, 8)

        func milliseconds(_ start: UInt64, _ end: UInt64) -> String {
            String(format: "%.2f", Double(end - start) / 1_000_000)
        }
        print(
            "THREADING_PERF agent-work "
                + "files=\(fileCount) agents=\(agentCount) touches=\(agentCount * touchesPerAgent) "
                + "atlas_ms=\(milliseconds(atlasStarted, atlasEnded)) "
                + "mutations_ms=\(milliseconds(mutationStarted, mutationEnded)) "
                + "aggregate_ms=\(milliseconds(aggregateStarted, aggregateEnded)) "
                + "project_projection_ms=\(milliseconds(projectionStarted, projectionEnded)) "
                + "live_100k_ms=\(milliseconds(liveStarted, liveEnded)) "
                + "rail_bins=\(atlas.rail.seeds.count) detail_bins=\(projection.bins.count)"
        )
    }

    @MainActor
    private func eventually<T>(
        timeout: Duration = .seconds(5),
        _ value: @escaping @MainActor () -> T?
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let result = value() { return result }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "FileActivityMapTests", code: 1)
    }
}
