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
        XCTAssertEqual(standing.remoteControl, true)
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
