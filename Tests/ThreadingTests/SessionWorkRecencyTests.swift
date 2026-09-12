import XCTest
@testable import Threading

@MainActor
final class SessionWorkRecencyTests: HostedStoreTestCase {
    func testLegacyFallbackRoundTripAndProcessRestartPreserveWorkHistory() throws {
        var session = AgentSession(kind: .claude, title: "History")
        session.lastActiveAt = date(100)
        XCTAssertEqual(session.lastUsedAt, date(100))
        session.lastTurnAt = date(200)
        session.lastWorkAt = date(300)
        session.lastActiveAt = date(900)
        XCTAssertEqual(session.lastUsedAt, date(300))
        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)
        XCTAssertEqual(decoded.lastTurnAt, date(200))
        XCTAssertEqual(decoded.lastWorkAt, date(300))
        XCTAssertEqual(decoded.lastUsedAt, date(300))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "lastWorkAt")
        let migrated = try JSONDecoder().decode(
            AgentSession.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertNil(migrated.lastWorkAt)
        XCTAssertEqual(migrated.lastUsedAt, date(200))
    }

    func testWorkEventsPreserveTurnStartAndPersistTheExactSession() throws {
        let (project, session, _) = try fixture()
        var kinds: [SessionWorkDidChange.Kind] = []
        var projectChanges = 0
        let events = AppEventObservations()
        events.observe(SessionWorkDidChange.self) { event in
            if event.sessionID == session.id { kinds.append(event.kind) }
        }
        events.observe(ProjectsDidChange.self) { _ in projectChanges += 1 }
        ProjectStore.shared.noteTurnStarted(sessionID: session.id, at: date(200))
        ProjectStore.shared.noteInputAccepted(sessionID: session.id, at: date(300))
        ProjectStore.shared.noteTurnEnded(sessionID: session.id, at: date(400))
        XCTAssertEqual(kinds, [.turnStarted, .inputAccepted, .turnEnded])
        XCTAssertEqual(projectChanges, 0)
        let stored = try XCTUnwrap(ProjectStore.shared.session(withID: session.id))
        XCTAssertEqual(stored.lastTurnAt, date(200))
        XCTAssertEqual(stored.lastUsedAt, date(400))
        ProjectStore.shared.flushPendingSave()
        let reopened = ProjectStore()
        XCTAssertEqual(reopened.session(withID: session.id)?.lastUsedAt, date(400))
        XCTAssertEqual(reopened.project(withID: project.id)?.sessions.count, 1)
        withExtendedLifetime(events) {}
    }

    func testTerminalLifecycleRecordsWorkButIgnoresIdleLaunchAndExit() throws {
        let (_, session, _) = try fixture()
        let controller = AgentSessionViewController(agentSession: session)
        controller.activityTracker.markRunning()
        XCTAssertNil(ProjectStore.shared.session(withID: session.id)?.lastWorkAt)
        controller.activityTracker.noteTurnStarted()
        let started = try XCTUnwrap(ProjectStore.shared.session(withID: session.id)?.lastTurnAt)
        controller.activityTracker.noteTurnFinished()
        let completed = try XCTUnwrap(ProjectStore.shared.session(withID: session.id)?.lastWorkAt)
        XCTAssertGreaterThanOrEqual(completed, started)
        controller.activityTracker.markDormant()
        controller.activityTracker.markRunning()
        controller.activityTracker.markDormant()
        XCTAssertEqual(ProjectStore.shared.session(withID: session.id)?.lastWorkAt, completed)
        XCTAssertEqual(ProjectStore.shared.session(withID: session.id)?.lastTurnAt, started)
    }

    func testNavigationIndexRefreshesOnWorkWithoutAProjectMutation() async throws {
        let (project, first, _) = try fixture()
        let second = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id, kind: .claude, title: "Work second"
        ))
        ProjectStore.shared.update(sessionID: first.id) { $0.lastTurnAt = self.date(100) }
        ProjectStore.shared.update(sessionID: second.id) { $0.lastTurnAt = self.date(200) }
        let store = NavigationSearchIndexStore()
        try await waitForNavigation(store)
        let before = try await navigationIDs(store)
        XCTAssertEqual(before, [second.id, first.id])
        ProjectStore.shared.noteTurnEnded(sessionID: first.id, at: date(300))
        try await waitForNavigation(store)
        let after = try await navigationIDs(store)
        XCTAssertEqual(after, [first.id, second.id])
        withExtendedLifetime(store) {}
    }

    func testTranscriptStoreRefreshesCompletedWorkWithoutAProjectMutation() async throws {
        let (project, session, root) = try fixture()
        let account = AgentAccount(provider: .claude, handle: .standard, configPath: root.path)
        let transcriptID = TranscriptID("work-history")
        ProjectStore.shared.update(sessionID: session.id) { $0.resumeState = .resumable(transcriptID) }
        let stored = try XCTUnwrap(ProjectStore.shared.session(withID: session.id))
        let url = try XCTUnwrap(SessionTranscript.url(
            sessionID: transcriptID, for: stored, in: project, account: account, effort: .known
        ))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = #"{"type":"user","message":{"role":"user","content":"cobalt original"}}"# + "\n"
        try Data(first.utf8).write(to: url)
        let store = TranscriptSearchIndexStore(
            databaseURL: root.appendingPathComponent("search.sqlite"), accountResolver: { _, _ in account }
        )
        try await waitForTranscript("cobalt", in: store)
        let appended = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"indigo completion"}]}}"# + "\n"
        try Data((first + appended).utf8).write(to: url)
        ProjectStore.shared.noteTurnEnded(sessionID: session.id)
        try await waitForTranscript("indigo", in: store)
        try await waitForTranscript("cobalt", in: store)
        withExtendedLifetime(store) {}
    }

    private func waitForTranscript(_ term: String, in store: TranscriptSearchIndexStore) async throws {
        let query = try SearchQueryParser.parse(term, scope: .everywhere, generation: 1).get()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for await batch in store.provider().search(SearchProviderRequest(
                query: query, clientCapabilities: .macOS
            )) where !batch.hits.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Work refresh did not index \(term)")
    }

    func testSupervisionReordersOnCompletedWork() async throws {
        let (project, first, _) = try fixture()
        let second = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id, kind: .claude, title: "Other managed chat"
        ))
        ProjectStore.shared.update(sessionID: first.id) {
            $0.lastActiveAt = self.date(900)
            $0.lastTurnAt = self.date(100)
        }
        ProjectStore.shared.update(sessionID: second.id) {
            $0.lastActiveAt = self.date(50)
            $0.lastTurnAt = self.date(200)
        }
        let managerID = SessionID()
        let supervisions = [first, second].map {
            Supervision(managerID: managerID, childID: $0.id, brief: "Work")
        }
        let controller = SupervisionListViewController(managerID: managerID, rowsProvider: {
            supervisions.compactMap { supervision in
                guard let session = ProjectStore.shared.session(withID: supervision.childID) else { return nil }
                return .init(supervision: supervision, session: session, activity: .idle, lastEvent: nil)
            }
        })
        _ = controller.view
        XCTAssertEqual(controller.rows.map(\.session.id), [second.id, first.id])
        ProjectStore.shared.noteTurnEnded(sessionID: first.id, at: date(300))
        let deadline = Date().addingTimeInterval(5)
        while controller.rows.first?.session.id != first.id, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.rows.map(\.session.id), [first.id, second.id])
    }

    func testNativeReplayCannotAdvanceWorkHistory() throws {
        let (project, session, _) = try fixture(native: true)
        let controller = try XCTUnwrap(ConversationViewController(
            agentSession: session, project: project,
            currentSessionProjection: CurrentSessionProjection { ProjectStore.shared.session(withID: $0) },
            customizationLookup: { _ in .empty }
        ))
        _ = controller.view
        controller.isReplaying = true
        controller.apply(.status(.working(word: "Working")))
        controller.apply(.status(.ready(model: nil, lastTurn: nil)))
        controller.isReplaying = false
        XCTAssertNil(ProjectStore.shared.session(withID: session.id)?.lastWorkAt)
        XCTAssertNil(ProjectStore.shared.session(withID: session.id)?.lastTurnAt)
    }

    private func date(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: value) }

    private func fixture(native: Bool = false) throws -> (Project, AgentSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id, kind: .claude, usesNativeUI: native, title: "Work first"
        ))
        return (project, session, root)
    }

    private func waitForNavigation(_ store: NavigationSearchIndexStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.provider().coverage != .complete, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.provider().coverage, .complete)
    }

    private func navigationIDs(_ store: NavigationSearchIndexStore) async throws -> [SessionID] {
        let query = try SearchQueryParser.parse("Work", scope: .everywhere, generation: 1).get()
        var ids: [SessionID] = []
        for await batch in store.provider().search(SearchProviderRequest(
            query: query, clientCapabilities: .macOS
        )) {
            ids += batch.hits.compactMap(\.provenance.sessionID)
        }
        return ids
    }
}
