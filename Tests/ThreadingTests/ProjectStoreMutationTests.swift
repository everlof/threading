import Foundation
import XCTest
@testable import Threading

@MainActor
final class ProjectStoreMutationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-store-mutations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testDurableMutationsReportAppliedAndSurviveReopening() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let store = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let terminal = try XCTUnwrap(store.addTerminal(to: project.id))
        let themeID = TerminalThemeID("fixture-theme")

        XCTAssertEqual(store.renameProject(id: project.id, to: "Durable project"), .applied)
        XCTAssertEqual(store.renameSession(id: session.id, to: "  Durable name  "), .applied)
        XCTAssertEqual(store.renameTerminal(id: terminal.id, to: "  Durable shell  "), .applied)
        XCTAssertEqual(store.setPinned(true, for: session.id), .applied)
        XCTAssertEqual(store.setUsesNativeUI(true, for: session.id), .applied)
        XCTAssertEqual(store.setArchived(true, for: session.id), .applied)
        XCTAssertEqual(store.setRemoteControl(true, for: session.id), .applied)
        XCTAssertEqual(store.setTerminalRenderer(true, for: session.id), .applied)
        XCTAssertEqual(store.setPermissionMode(.plan, for: session.id), .applied)
        XCTAssertEqual(store.setNotificationsMuted(true, forSessionID: session.id), .applied)
        XCTAssertEqual(store.setNotificationsMuted(false, forProjectID: project.id), .applied)
        XCTAssertEqual(
            store.setAccountHandle(.named("work"), for: session.id),
            .applied
        )
        XCTAssertEqual(store.setThemeID(themeID, forSessionID: session.id), .applied)
        XCTAssertEqual(store.setThemeID(themeID, forProjectID: project.id), .applied)
        XCTAssertEqual(store.setThemeID(themeID, forTerminalID: terminal.id), .applied)

        let reopened = ProjectStore(stateManager: manager, refusesWrites: false)
        let standing = try XCTUnwrap(reopened.session(withID: session.id))
        XCTAssertEqual(standing.customTitle, "Durable name")
        XCTAssertTrue(standing.isPinned)
        XCTAssertTrue(standing.usesNativeUI)
        XCTAssertTrue(standing.isArchived)
        XCTAssertNotNil(standing.archivedAt)
        XCTAssertEqual(standing.remoteControl, true)
        XCTAssertEqual(standing.fullscreenRenderer, true)
        XCTAssertEqual(standing.permissionMode, .plan)
        XCTAssertEqual(standing.notificationsMuted, true)
        XCTAssertEqual(standing.accountHandle, .named("work"))
        XCTAssertEqual(standing.themeID, themeID)
        let reopenedProject = try XCTUnwrap(reopened.project(withID: project.id))
        XCTAssertEqual(reopenedProject.name, "Durable project")
        XCTAssertEqual(reopenedProject.notificationsMuted, false)
        XCTAssertEqual(reopenedProject.themeID, themeID)
        XCTAssertEqual(
            reopenedProject.terminals.first(where: { $0.id == terminal.id })?.customTitle,
            "Durable shell"
        )
        XCTAssertEqual(reopenedProject.terminals.first(where: { $0.id == terminal.id })?.themeID, themeID)
    }

    func testArchiveWritesOnlyTheChangedSessionRows() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let store = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let untouched = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let first = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))
        let second = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))

        // A payload from a newer build must survive an archive action on neighbouring rows.
        // The old whole-graph save rewrote this sentinel and made the test fail.
        let inspection = try SQLiteDatabase(
            path: directory.appendingPathComponent("threading.db").path
        )
        defer { inspection.close() }
        let sentinel = #"{"futureSessionFormat":true}"#
        try inspection.prepare("UPDATE session SET data = ? WHERE id = ?")
            .bind(1, sentinel)
            .bind(2, untouched.id.uuidString)
            .run()

        XCTAssertEqual(
            store.synchronizeArchiveStates([first.id: true, second.id: true]),
            .applied
        )
        XCTAssertEqual(store.setArchived(false, for: first.id), .applied)

        let payload = try inspection.prepare("SELECT data FROM session WHERE id = ?")
        defer { payload.finalize() }
        payload.bind(1, untouched.id.uuidString)
        XCTAssertTrue(try payload.step())
        XCTAssertEqual(payload.text(0), sentinel)
    }

    func testAddingTitledTerminalWritesOnlyItsOwningProject() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let store = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let untouched = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))

        // A terminal launch must not encode or upsert retained conversations. The Update All
        // incident had 696 of them, and the old whole-graph path rewrote every one before the
        // updater PTY was even created.
        let inspection = try SQLiteDatabase(
            path: directory.appendingPathComponent("threading.db").path
        )
        defer { inspection.close() }
        let sentinel = #"{"futureSessionFormat":true}"#
        try inspection.prepare("UPDATE session SET data = ? WHERE id = ?")
            .bind(1, sentinel)
            .bind(2, untouched.id.uuidString)
            .run()

        let observations = AppEventObservations()
        var additionImpact: ProjectsDidChange.SidebarImpact?
        observations.observe(ProjectsDidChange.self) { additionImpact = $0.sidebarImpact }
        let terminal = try XCTUnwrap(store.addTerminal(
            to: project.id,
            customTitle: "  Agent Updates  "
        ))
        guard case let .terminalAdded(addedProjectID, addedTerminalID) = additionImpact else {
            return XCTFail("terminal creation must publish its exact owning identities")
        }
        XCTAssertEqual(addedProjectID, project.id)
        XCTAssertEqual(addedTerminalID, terminal.id)
        XCTAssertEqual(terminal.customTitle, "Agent Updates")
        XCTAssertEqual(
            store.project(withID: project.id)?.terminals.first { $0.id == terminal.id }?.customTitle,
            "Agent Updates"
        )

        let sessionPayload = try inspection.prepare("SELECT data FROM session WHERE id = ?")
        defer { sessionPayload.finalize() }
        sessionPayload.bind(1, untouched.id.uuidString)
        XCTAssertTrue(try sessionPayload.step())
        XCTAssertEqual(sessionPayload.text(0), sentinel)

        let projectPayload = try inspection.prepare("SELECT data FROM project WHERE id = ?")
        defer { projectPayload.finalize() }
        projectPayload.bind(1, project.id.uuidString)
        XCTAssertTrue(try projectPayload.step())
        let durableProject = try JSONDecoder().decode(
            Project.self,
            from: try XCTUnwrap(projectPayload.data(0))
        )
        XCTAssertEqual(
            durableProject.terminals.first { $0.id == terminal.id }?.customTitle,
            "Agent Updates"
        )
    }

    func testRenameDoesNotFlushUnrelatedCoalescedSessionWrites() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let store = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let background = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let renamed = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))

        XCTAssertEqual(
            store.updateAgentTitle("Background report", for: background.id),
            .accepted
        )

        // Stand in for a newer build's payload after the automatic title was queued. Pressing
        // Enter on another row must commit only that rename, leaving this pending row alone until
        // its coalescing deadline. The old path synchronously drained it and overwrote the marker.
        let inspection = try SQLiteDatabase(
            path: directory.appendingPathComponent("threading.db").path
        )
        defer { inspection.close() }
        let sentinel = #"{"futureSessionFormat":true}"#
        try inspection.prepare("UPDATE session SET data = ? WHERE id = ?")
            .bind(1, sentinel)
            .bind(2, background.id.uuidString)
            .run()

        let observations = AppEventObservations()
        var renameImpact: ProjectsDidChange.SidebarImpact?
        observations.observe(ProjectsDidChange.self) { renameImpact = $0.sidebarImpact }
        XCTAssertEqual(store.renameSession(id: renamed.id, to: "Renamed"), .applied)

        guard case let .sessionTitle(renamedID, reorders) = renameImpact else {
            return XCTFail("rename must publish one non-reordering title delta")
        }
        XCTAssertEqual(renamedID, renamed.id)
        XCTAssertEqual(reorders, NativeSidebarPipelineOptions.sessionOrder == .name)

        let backgroundPayload = try inspection.prepare("SELECT data FROM session WHERE id = ?")
        defer { backgroundPayload.finalize() }
        backgroundPayload.bind(1, background.id.uuidString)
        XCTAssertTrue(try backgroundPayload.step())
        XCTAssertEqual(backgroundPayload.text(0), sentinel)

        let renamedPayload = try inspection.prepare("SELECT data FROM session WHERE id = ?")
        defer { renamedPayload.finalize() }
        renamedPayload.bind(1, renamed.id.uuidString)
        XCTAssertTrue(try renamedPayload.step())
        let durableRename = try JSONDecoder().decode(
            AgentSession.self,
            from: try XCTUnwrap(renamedPayload.data(0))
        )
        XCTAssertEqual(durableRename.customTitle, "Renamed")
    }

    func testInteractiveStructuralMutationsDoNotRewriteStandingSessions() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let store = ProjectStore(stateManager: manager, refusesWrites: false)
        let standingProject = try XCTUnwrap(store.addProject(folderURL: directory))
        let untouched = try XCTUnwrap(store.addSession(to: standingProject.id, kind: .claude))

        let inspection = try SQLiteDatabase(
            path: directory.appendingPathComponent("threading.db").path
        )
        defer { inspection.close() }
        let sentinel = #"{"futureSessionFormat":true}"#
        try inspection.prepare("UPDATE session SET data = ? WHERE id = ?")
            .bind(1, sentinel)
            .bind(2, untouched.id.uuidString)
            .run()

        let addedFolder = directory.appendingPathComponent("added", isDirectory: true)
        try FileManager.default.createDirectory(
            at: addedFolder,
            withIntermediateDirectories: true
        )
        let addedProject = try XCTUnwrap(store.addProject(folderURL: addedFolder))
        let imported = store.importSessions([
            ImportableSession(
                agentSessionID: TranscriptID("imported"),
                kind: .codex,
                accountHandle: .standard,
                title: "Imported",
                lastActiveAt: Date(timeIntervalSince1970: 1_750_000_000)
            )
        ], into: addedProject.id)
        XCTAssertEqual(imported.count, 1)
        let observations = AppEventObservations()
        var removalImpact: ProjectsDidChange.SidebarImpact?
        observations.observe(ProjectsDidChange.self) { removalImpact = $0.sidebarImpact }
        XCTAssertEqual(store.removeProject(id: addedProject.id), .applied)

        guard case let .projectRemoved(projectID, sessionIDs, terminalIDs) = removalImpact else {
            return XCTFail("project removal must publish its exact owned identities")
        }
        XCTAssertEqual(projectID, addedProject.id)
        XCTAssertEqual(sessionIDs, Set(imported.map(\.id)))
        XCTAssertTrue(terminalIDs.isEmpty)

        let payload = try inspection.prepare("SELECT data FROM session WHERE id = ?")
        defer { payload.finalize() }
        payload.bind(1, untouched.id.uuidString)
        XCTAssertTrue(try payload.step())
        XCTAssertEqual(payload.text(0), sentinel)
    }

    func testAlreadyStandingValuesAreSuccessfulWithoutTakingAWrite() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let seed = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(seed.addProject(folderURL: directory))
        let session = try XCTUnwrap(seed.addSession(to: project.id, kind: .claude))
        let terminal = try XCTUnwrap(seed.addTerminal(to: project.id))

        // Recovery mode refuses writes. These still succeed because the requested values are
        // already the durable snapshot and therefore require no write to acknowledge honestly.
        let recovery = ProjectStore(stateManager: manager, refusesWrites: true)
        XCTAssertEqual(recovery.renameProject(id: project.id, to: project.name), .unchanged)
        XCTAssertEqual(recovery.renameSession(id: session.id, to: nil), .unchanged)
        XCTAssertEqual(recovery.renameTerminal(id: terminal.id, to: nil), .unchanged)
        XCTAssertEqual(recovery.setPinned(false, for: session.id), .unchanged)
        XCTAssertEqual(recovery.setUsesNativeUI(false, for: session.id), .unchanged)
        XCTAssertEqual(recovery.setArchived(false, for: session.id), .unchanged)
        XCTAssertEqual(recovery.setRemoteControl(nil, for: session.id), .unchanged)
        XCTAssertEqual(recovery.setTerminalRenderer(nil, for: session.id), .unchanged)
        XCTAssertEqual(recovery.setPermissionMode(nil, for: session.id), .unchanged)
        XCTAssertEqual(recovery.setNotificationsMuted(nil, forSessionID: session.id), .unchanged)
        XCTAssertEqual(recovery.setNotificationsMuted(nil, forProjectID: project.id), .unchanged)
    }

    func testARefusedWriteRestoresEveryStandingValueAndSaysSo() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let seed = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(seed.addProject(folderURL: directory))
        let session = try XCTUnwrap(seed.addSession(to: project.id, kind: .claude))
        let terminal = try XCTUnwrap(seed.addTerminal(to: project.id))

        let recovery = ProjectStore(stateManager: manager, refusesWrites: true)
        XCTAssertEqual(
            recovery.renameProject(id: project.id, to: "Optimistic project"),
            .persistenceRefused
        )
        XCTAssertEqual(recovery.project(withID: project.id)?.name, project.name)
        XCTAssertEqual(
            recovery.renameSession(id: session.id, to: "Optimistic ghost"),
            .persistenceRefused
        )
        XCTAssertNil(recovery.session(withID: session.id)?.customTitle)
        XCTAssertEqual(
            recovery.renameTerminal(id: terminal.id, to: "Optimistic shell"),
            .persistenceRefused
        )
        XCTAssertNil(
            recovery.project(withID: project.id)?.terminals
                .first(where: { $0.id == terminal.id })?.customTitle
        )
        XCTAssertEqual(recovery.setPinned(true, for: session.id), .persistenceRefused)
        XCTAssertFalse(try XCTUnwrap(recovery.session(withID: session.id)).isPinned)
        XCTAssertEqual(recovery.setUsesNativeUI(true, for: session.id), .persistenceRefused)
        XCTAssertFalse(try XCTUnwrap(recovery.session(withID: session.id)).usesNativeUI)
        XCTAssertEqual(recovery.setArchived(true, for: session.id), .persistenceRefused)
        XCTAssertFalse(try XCTUnwrap(recovery.session(withID: session.id)).isArchived)
        XCTAssertNil(recovery.session(withID: session.id)?.archivedAt)
        XCTAssertEqual(recovery.setRemoteControl(true, for: session.id), .persistenceRefused)
        XCTAssertNil(recovery.session(withID: session.id)?.remoteControl)
        XCTAssertEqual(recovery.setPermissionMode(.plan, for: session.id), .persistenceRefused)
        XCTAssertNil(recovery.session(withID: session.id)?.permissionMode)
        XCTAssertEqual(
            recovery.setNotificationsMuted(true, forSessionID: session.id),
            .persistenceRefused
        )
        XCTAssertNil(recovery.session(withID: session.id)?.notificationsMuted)
        XCTAssertEqual(
            recovery.setNotificationsMuted(true, forProjectID: project.id),
            .persistenceRefused
        )
        XCTAssertNil(recovery.project(withID: project.id)?.notificationsMuted)
        XCTAssertEqual(
            recovery.setThemeID(TerminalThemeID("ghost-theme"), forSessionID: session.id),
            .persistenceRefused
        )
        XCTAssertNil(recovery.session(withID: session.id)?.themeID)
        XCTAssertEqual(
            recovery.setAccountHandle(.named("ghost"), for: session.id),
            .persistenceRefused
        )
        XCTAssertEqual(recovery.session(withID: session.id)?.accountHandle, .standard)
        XCTAssertEqual(
            recovery.update(sessionID: session.id) { $0.model = "optimistic-model" },
            .persistenceRefused
        )
        XCTAssertNil(recovery.session(withID: session.id)?.model)
    }

    func testInvalidTargetsAndUnsupportedSurfacesAreTypedRefusals() throws {
        let store = ProjectStore(
            stateManager: StateManager(appSupportDirectory: directory),
            refusesWrites: false
        )
        let missing = SessionID()
        XCTAssertEqual(store.renameProject(id: ProjectID(), to: "Name"), .targetNotFound)
        XCTAssertEqual(store.renameSession(id: missing, to: "Name"), .targetNotFound)
        XCTAssertEqual(store.renameTerminal(id: TerminalID(), to: "Name"), .targetNotFound)
        XCTAssertEqual(store.setPinned(true, for: missing), .targetNotFound)
        XCTAssertEqual(store.setUsesNativeUI(true, for: missing), .targetNotFound)
        XCTAssertEqual(store.setArchived(true, for: missing), .targetNotFound)
        XCTAssertEqual(store.setRemoteControl(true, for: missing), .targetNotFound)
        XCTAssertEqual(store.setPermissionMode(.plan, for: missing), .targetNotFound)
        XCTAssertEqual(store.setNotificationsMuted(true, forSessionID: missing), .targetNotFound)
        XCTAssertEqual(
            store.setNotificationsMuted(true, forProjectID: ProjectID()),
            .targetNotFound
        )
        XCTAssertEqual(
            store.setThemeID(TerminalThemeID("fixture"), forSessionID: missing),
            .targetNotFound
        )

        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let openCode = try XCTUnwrap(store.addSession(to: project.id, kind: .openCode))
        XCTAssertEqual(
            store.setUsesNativeUI(true, for: openCode.id),
            .unsupportedValue
        )
        XCTAssertEqual(
            store.setAccountHandle(.named("unsupported"), for: openCode.id),
            .unsupportedValue
        )
        XCTAssertEqual(store.setRemoteControl(true, for: openCode.id), .unsupportedValue)
        XCTAssertFalse(try XCTUnwrap(store.session(withID: openCode.id)).usesNativeUI)
    }

    func testArchivedSessionsFollowArchiveChronologyRatherThanRuntimeActivity() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let store = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let recentlyActive = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .claude,
            title: "Recently active, archived first"
        ))
        let longIdle = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .claude,
            title: "Long idle, archived last"
        ))
        store.update(sessionID: recentlyActive.id) {
            $0.lastActiveAt = Date(timeIntervalSince1970: 9_000)
        }
        store.update(sessionID: longIdle.id) {
            $0.lastActiveAt = Date(timeIntervalSince1970: 1_000)
        }

        let firstArchive = Date(timeIntervalSince1970: 10_000)
        let secondArchive = Date(timeIntervalSince1970: 11_000)
        XCTAssertEqual(
            store.setArchived(true, for: recentlyActive.id, at: firstArchive),
            .applied
        )
        XCTAssertEqual(
            store.setArchived(true, for: longIdle.id, at: secondArchive),
            .applied
        )

        XCTAssertEqual(
            store.archivedSessions().map(\.session.id),
            [longIdle.id, recentlyActive.id]
        )
        XCTAssertEqual(store.session(withID: longIdle.id)?.archivedAt, secondArchive)

        XCTAssertEqual(store.setArchived(false, for: longIdle.id), .applied)
        XCTAssertNil(store.session(withID: longIdle.id)?.archivedAt)
        let rearchive = Date(timeIntervalSince1970: 12_000)
        XCTAssertEqual(store.setArchived(true, for: longIdle.id, at: rearchive), .applied)

        let reopened = ProjectStore(stateManager: manager, refusesWrites: false)
        XCTAssertEqual(reopened.session(withID: longIdle.id)?.archivedAt, rearchive)
        XCTAssertEqual(
            reopened.archivedSessions().map(\.session.id),
            [longIdle.id, recentlyActive.id]
        )
    }

    /// Delete/close callers own live processes. A store refusal must therefore be visible before
    /// they tear anything down, and the standing graph must be restored in full for retry.
    func testRefusedDestructiveMutationsLeaveEveryDurableOwnerStanding() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let seed = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(seed.addProject(folderURL: directory))
        let session = try XCTUnwrap(seed.addSession(to: project.id, kind: .claude))
        let terminal = try XCTUnwrap(seed.addTerminal(to: project.id))

        let recovery = ProjectStore(stateManager: manager, refusesWrites: true)
        XCTAssertEqual(recovery.removeSession(id: session.id), .persistenceRefused)
        XCTAssertNotNil(recovery.session(withID: session.id))
        XCTAssertEqual(recovery.removeTerminal(id: terminal.id), .persistenceRefused)
        XCTAssertNotNil(
            recovery.project(withID: project.id)?.terminals.first { $0.id == terminal.id }
        )
        XCTAssertEqual(recovery.removeProject(id: project.id), .persistenceRefused)
        XCTAssertNotNil(recovery.project(withID: project.id))

        let reopened = ProjectStore(stateManager: manager, refusesWrites: false)
        XCTAssertNotNil(reopened.project(withID: project.id))
        XCTAssertNotNil(reopened.session(withID: session.id))
        XCTAssertNotNil(
            reopened.project(withID: project.id)?.terminals.first { $0.id == terminal.id }
        )
    }
}
