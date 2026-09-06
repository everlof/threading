import XCTest
@testable import Threading

@MainActor
final class ClaudeTranscriptLocationsTests: HostedStoreTestCase {
    private let transcriptID = TranscriptID("11111111-2222-3333-4444-555555555555")

    private func session() -> AgentSession {
        var session = AgentSession(kind: .claude, title: "Moved conversation")
        session.resumeState = .resumable(transcriptID)
        return session
    }

    private func report(
        for session: AgentSession,
        path: String,
        event: HookLifecycleEvent = .turnStarted
    ) throws -> HookLifecycleReport {
        try XCTUnwrap(HookLifecycleReport(sessionID: session.id, event: event, payload: [
            "session_id": transcriptID.rawValue,
            "transcript_path": path
        ]))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptLocationsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testLiveHookFindsTheRefusalBeyondTheStaleCheckoutCopyAndDiscardForgetsIt() async throws {
        let root = try temporaryDirectory()
        let account = AgentAccount(provider: .claude, handle: .standard, configPath: root.path)
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        var session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        session.resumeState = .resumable(transcriptID)
        _ = ProjectStore.shared.update(sessionID: session.id) { $0.resumeState = session.resumeState }

        let stale = try XCTUnwrap(ClaudeTranscript.storageURL(
            sessionID: transcriptID, account: account, in: project
        ))
        let live = root.appendingPathComponent("projects/-original-checkout/\(transcriptID.rawValue).jsonl")
        let oldOutcome = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Working"}],"stop_reason":"tool_use"}}"# + "\n"
        let refusal = #"{"type":"assistant","uuid":"new-refusal","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 11:20am (Europe/Stockholm)"}]}}"# + "\n"
        for file in [stale, live] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try oldOutcome.write(to: stale, atomically: true, encoding: .utf8)
        try (oldOutcome + refusal).write(to: live, atomically: true, encoding: .utf8)

        let initial = try XCTUnwrap(SessionTranscript.readRequest(
            sessionID: transcriptID, for: session, in: project, account: account
        ))
        XCTAssertEqual(initial.resolve()?.path, stale.path)

        let runtime = AgentRuntime(currentSessionProjection: CurrentSessionProjection {
            ProjectStore.shared.session(withID: $0)
        })
        let terminal = AgentSessionViewController(agentSession: session)
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(terminal, for: session.id))
        defer { runtime.discard(sessionID: session.id) }
        runtime.applyLifecycle(try report(for: session, path: live.path))

        let source = try XCTUnwrap(ClaudeTranscriptLocations.shared.url(for: session, account: account))
        XCTAssertEqual(source.path, live.path)
        let request = try XCTUnwrap(SessionTranscript.readRequest(
            sessionID: transcriptID, for: session, in: project, account: account
        ))
        XCTAssertEqual(request.resolve()?.path, live.path)
        let searchSource = try XCTUnwrap(TranscriptSearchProjection.source(
            session: session, in: project, effort: .known, account: { _, _ in account }
        ))
        XCTAssertEqual(searchSource.url.path, live.path)
        XCTAssertEqual(ClaudeTranscript.subagentsDirectory(forRoot: source).path,
                       live.deletingPathExtension().appendingPathComponent("subagents").path)
        XCTAssertNil(ClaudeTranscriptUsageLimit.newestStop(at: stale))
        let detected = expectation(description: "live transcript refusal is read off-main")
        ClaudeTranscriptUsageLimit.revalidate(at: source) { stop in
            XCTAssertEqual(stop?.recordID, "new-refusal")
            XCTAssertEqual(stop?.resetHint, "11:20am (Europe/Stockholm)")
            detected.fulfill()
        }
        await fulfillment(of: [detected], timeout: 3)

        let replayed = expectation(description: "replay reads the same live source on its worker")
        TranscriptReplay.load(request, kind: session.kind) { events, truncated in
            let texts = events.flatMap { event -> [String] in
                guard case .assistantMessage(let blocks) = event else { return [] }
                return blocks.compactMap { block in
                    guard case .text(let text) = block else { return nil }
                    return text
                }
            }
            XCTAssertTrue(texts.contains { $0.contains("You've hit your session limit") })
            XCTAssertFalse(truncated)
            replayed.fulfill()
        }
        await fulfillment(of: [replayed], timeout: 3)

        runtime.discard(sessionID: session.id)
        XCTAssertNil(ClaudeTranscriptLocations.shared.url(for: session, account: account))
    }

    func testBackgroundObservationsLoseAuthorityWhenSessionOwnershipChanges() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporaryDirectory()))
        var session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        session.resumeState = .resumable(transcriptID)
        _ = ProjectStore.shared.update(sessionID: session.id) { $0.resumeState = session.resumeState }
        let runtime = AgentRuntime(currentSessionProjection: CurrentSessionProjection {
            ProjectStore.shared.session(withID: $0)
        })
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(
            AgentSessionViewController(agentSession: session), for: session.id
        ))
        defer { runtime.discard(sessionID: session.id) }
        let initial = try XCTUnwrap(runtime.transcriptObservation(for: session.id))
        XCTAssertTrue(runtime.isCurrent(initial))
        _ = ProjectStore.shared.update(sessionID: session.id) {
            $0.accountHandle = AccountHandle(storedName: "destination")
        }
        XCTAssertFalse(runtime.isCurrent(initial), "Old-account refusals cannot park the destination")
        _ = ProjectStore.shared.update(sessionID: session.id) { $0.accountHandle = session.accountHandle }
        let beforeMove = try XCTUnwrap(runtime.transcriptObservation(for: session.id))
        SessionExecutionLocusTracker.shared.forget(sessionID: session.id)
        XCTAssertFalse(runtime.isCurrent(beforeMove), "Checkout ownership revokes an outstanding read")

        let beforeHook = try XCTUnwrap(runtime.transcriptObservation(for: session.id))
        let hook = try report(for: session, path: "/tmp/account/projects/-live/\(transcriptID.rawValue).jsonl")
        runtime.applyLifecycle(hook)
        XCTAssertFalse(runtime.isCurrent(beforeHook), "A corrected source revokes reads of the old path")
        let afterHook = try XCTUnwrap(runtime.transcriptObservation(for: session.id))
        runtime.applyLifecycle(hook)
        XCTAssertTrue(runtime.isCurrent(afterHook), "Identical hook reports do not starve reads")
        runtime.discard(sessionID: session.id)
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(
            AgentSessionViewController(agentSession: session), for: session.id
        ))
        XCTAssertFalse(runtime.isCurrent(afterHook), "The same session ID can own a different runtime")
    }

    func testReadRequestRejectsTheWrongAccountAndKeepsCodexDiscoveryDeferred() throws {
        let session = session()
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/project"))
        XCTAssertNil(SessionTranscript.readRequest(
            sessionID: transcriptID, for: session, in: project,
            account: AgentAccount(provider: .claude, handle: AccountHandle(storedName: "wrong"), configPath: "/tmp/account")
        ))
        var codex = AgentSession(kind: .codex, title: "Codex")
        codex.resumeState = .resumable(transcriptID)
        let account = AgentAccount(provider: .codex, handle: codex.accountHandle, configPath: "/tmp/missing-\(UUID().uuidString)")
        let request = try XCTUnwrap(SessionTranscript.readRequest(
            sessionID: transcriptID, for: codex, in: project, account: account
        ))
        guard case .codexRollout(let id, let requestedAccount) = request else {
            return XCTFail("Capturing the source must not walk Codex's sessions tree")
        }
        XCTAssertEqual(id, transcriptID)
        XCTAssertEqual(requestedAccount.configPath, account.configPath)
        XCTAssertNil(request.resolve(effort: .known))
    }

    func testMigrationInstallsTheCompleteLiveTranscriptAtTheDestinationLaunchPath() throws {
        let root = try temporaryDirectory()
        let session = session()
        let account = AgentAccount(provider: .claude, handle: .standard, configPath: root.path)
        let project = Project(name: "worktree", folderURL: root.appendingPathComponent("worktree"))
        let oldSlug = root.appendingPathComponent("projects/-original/\(transcriptID.rawValue).jsonl")
        let destination = SessionMigration.destinationTranscript(
            for: session, in: project, account: account, accountRelativeDestination: oldSlug
        )
        XCTAssertNotEqual(destination, oldSlug)
        XCTAssertEqual(destination, ClaudeTranscript.storageURL(sessionID: transcriptID, account: account, in: project))
        let source = root.appendingPathComponent("source.jsonl")
        let complete = "earlier work\nwork after checkout move\nusage refusal\n"
        try complete.write(to: source, atomically: true, encoding: .utf8)
        _ = try TranscriptCopyTransaction.install(
            source: source, destination: destination,
            recoveryJournalURL: root.appendingPathComponent("recovery.json")
        ) { true }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), complete)
    }

    func testCodexMigrationKeepsItsAccountRelativeRolloutPath() {
        let account = AgentAccount(provider: .codex, handle: .standard, configPath: "/tmp/target")
        let source = URL(fileURLWithPath: "/tmp/target/sessions/2026/09/06/rollout.jsonl")
        XCTAssertEqual(SessionMigration.destinationTranscript(
            for: AgentSession(kind: .codex, title: "Codex"),
            in: Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p")),
            account: account, accountRelativeDestination: source
        ), source)
    }

    func testOtherAccountsSessionsAndChildPathsCannotSupplyTheRefusal() throws {
        let session = session()
        let account = AgentAccount(provider: .claude, handle: .standard, configPath: "/tmp/account")
        for path in [
            "/tmp/other-account/projects/-p/\(transcriptID.rawValue).jsonl",
            "/tmp/account/projects/-p/other-session.jsonl",
            "/tmp/account/projects/-p/parent/subagents/\(transcriptID.rawValue).jsonl",
            "/tmp/account/projects/-p/../../outside/\(transcriptID.rawValue).jsonl",
            "relative/projects/-p/\(transcriptID.rawValue).jsonl"
        ] {
            let locations = ClaudeTranscriptLocations()
            locations.observe(try report(for: session, path: path), for: session, ownershipEpoch: 0)
            XCTAssertNil(locations.url(for: session, account: account), path)
        }
    }

    func testOldCheckoutReportAndSubagentHooksCannotReplaceTheLivePath() throws {
        let session = session()
        let account = AgentAccount(provider: .claude, handle: .standard, configPath: "/tmp/account")
        let locations = ClaudeTranscriptLocations()
        let path = "/tmp/account/projects/-current/\(transcriptID.rawValue).jsonl"
        locations.observe(try report(for: session, path: path), for: session, ownershipEpoch: 2)
        var old = try report(for: session, path: "/tmp/account/projects/-old/\(transcriptID.rawValue).jsonl")
        old.capturedOwnershipEpoch = 1
        locations.observe(old, for: session, ownershipEpoch: 2)
        for event in [HookLifecycleEvent.subagentStarted, .subagentStopped] {
            locations.observe(try report(for: session, path: old.transcriptPath!, event: event), for: session, ownershipEpoch: 2)
        }
        XCTAssertEqual(locations.url(for: session, account: account)?.path, path)
    }

    func testChangingAccountOrConversationInvalidatesTheReportedPath() throws {
        let original = session()
        let account = AgentAccount(provider: .claude, handle: .standard, configPath: "/tmp/account")
        let locations = ClaudeTranscriptLocations()
        locations.observe(try report(for: original, path: "/tmp/account/projects/-p/\(transcriptID.rawValue).jsonl"), for: original, ownershipEpoch: 0)
        var changed = original
        changed.accountHandle = AccountHandle(storedName: "another")
        XCTAssertNil(locations.url(for: changed, account: account))
        changed = original
        changed.resumeState = .resumable(TranscriptID("another-conversation"))
        XCTAssertNil(locations.url(for: changed, account: account))
    }

    func testAMismatchedProviderIdentifierCannotSupplyALocation() throws {
        let session = session()
        let locations = ClaudeTranscriptLocations()
        let account = AgentAccount(provider: .claude, handle: .standard, configPath: "/tmp/account")
        let report = try XCTUnwrap(HookLifecycleReport(sessionID: session.id, event: .turnStarted, payload: [
            "session_id": "another-conversation",
            "transcript_path": "/tmp/account/projects/-p/\(transcriptID.rawValue).jsonl"
        ]))
        locations.observe(report, for: session, ownershipEpoch: 0)
        XCTAssertNil(locations.url(for: session, account: account))
    }

    func testAThousandRetainedSessionsKeepTheirOwnLocationsAcrossRepeatedHooksAndDiscard() throws {
        let locations = ClaudeTranscriptLocations()
        let account = AgentAccount(provider: .claude, handle: .standard, configPath: "/tmp/account")
        let sessions = (0..<1_000).map { _ in session() }
        for (index, session) in sessions.enumerated() {
            let path = "/tmp/account/projects/-p\(index)/\(transcriptID.rawValue).jsonl"
            let report = try report(for: session, path: path)
            for _ in 0..<10 {
                locations.observe(report, for: session, ownershipEpoch: 0)
            }
        }
        for (index, session) in sessions.enumerated() {
            XCTAssertEqual(locations.url(for: session, account: account)?.path,
                           "/tmp/account/projects/-p\(index)/\(transcriptID.rawValue).jsonl")
            locations.forget(session.id)
            XCTAssertNil(locations.url(for: session, account: account))
        }
    }
}
