import Foundation
import ThreadingPluginKit
import XCTest
@testable import Threading

@MainActor
final class NativeWorkspaceNavigatorSnapshotSourceTests: XCTestCase {
    private var directories: [URL] = []
    private var stateManagers: [StateManager] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            stateManagers.forEach { $0.closeDatabase() }
            stateManagers = []
            directories.forEach { try? FileManager.default.removeItem(at: $0) }
            directories = []
        }
        super.tearDown()
    }

    func testSnapshotPublishesTypedBoundedDisplayStateWithoutModelObjectsOrPaths() throws {
        let longTitle = String(repeating: "navigator", count: 80)
        let longBranch = String(repeating: "branch/", count: 100)
        var session = AgentSession(kind: .codex, title: longTitle)
        session.branch = longBranch
        session.isPinned = true
        session.isArchived = true

        let directory = makeDirectory()
        var project = Project(name: "Threading", folderURL: directory.appendingPathComponent("secret"))
        project.sessions = [session]
        project.terminals = [ProjectTerminal(currentDirectory: project.folderPath, title: "Shell")]
        let store = try makeStore(projects: [project], directory: directory)
        let source = NativeWorkspaceNavigatorSnapshotSource(
            projectStore: store,
            activity: { $0 == session.id ? .awaitingUser : .idle }
        )
        let selected = PluginWorkspaceItemIdentity(
            kind: .session,
            identifier: session.id.uuidString.lowercased()
        )

        let snapshot = source.initialSnapshot(selectedItemIdentity: selected)

        XCTAssertEqual(snapshot.items.map(\.identity.kind), [.project, .session, .terminal])
        XCTAssertEqual(snapshot.selectedItemIdentity, selected)
        let sessionItem = try XCTUnwrap(snapshot.items.first { $0.identity.kind == .session })
        XCTAssertEqual(sessionItem.parentIdentity?.kind, .project)
        XCTAssertEqual(sessionItem.parentIdentity?.identifier, project.id.uuidString.lowercased())
        XCTAssertEqual(sessionItem.activity, .awaitingUser)
        XCTAssertTrue(sessionItem.isPinned)
        XCTAssertTrue(sessionItem.isArchived)
        XCTAssertLessThanOrEqual(
            sessionItem.title.unicodeScalars.count,
            NativeWorkspaceNavigatorSnapshotSource.maximumStringScalars
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(sessionItem.branch).unicodeScalars.count,
            NativeWorkspaceNavigatorSnapshotSource.maximumStringScalars
        )
        XCTAssertFalse(snapshot.items.contains {
            [$0.title, $0.detail, $0.branch].compactMap { $0 }.contains(project.folderPath)
        })
    }

    func testSessionEdgeIsOneRowAndSelectionEdgesAreDeduplicated() throws {
        let directory = makeDirectory()
        var project = Project(name: "Threading", folderURL: directory.appendingPathComponent("repo"))
        let session = AgentSession(kind: .claude, title: "Before")
        project.sessions = [session]
        let store = try makeStore(projects: [project], directory: directory)
        let source = NativeWorkspaceNavigatorSnapshotSource(projectStore: store) { _ in .working }
        _ = source.initialSnapshot(selectedItemIdentity: nil)

        XCTAssertEqual(store.renameSession(id: session.id, to: "After"), .applied)
        let delta = try XCTUnwrap(source.sessionUpdate(session.id))
        XCTAssertFalse(delta.isReplacement)
        XCTAssertEqual(delta.items.count, 1)
        XCTAssertEqual(delta.items.first?.identity.kind, .session)
        XCTAssertEqual(delta.items.first?.title, "After")
        XCTAssertEqual(delta.items.first?.activity, .working)

        let selected = PluginWorkspaceItemIdentity(
            kind: .session,
            identifier: session.id.uuidString.lowercased()
        )
        XCTAssertNotNil(source.selectionUpdate(selected))
        XCTAssertNil(source.selectionUpdate(selected))
        XCTAssertNotNil(source.selectionUpdate(nil))
    }

    func testFullSnapshotStopsAtPublishedItemLimit() throws {
        let directory = makeDirectory()
        var project = Project(name: "Large", folderURL: directory.appendingPathComponent("repo"))
        project.sessions = (0...NativeWorkspaceNavigatorSnapshotSource.maximumItems).map {
            AgentSession(kind: .claude, title: "Session \($0)")
        }
        let store = try makeStore(projects: [project], directory: directory)
        let source = NativeWorkspaceNavigatorSnapshotSource(projectStore: store)

        XCTAssertEqual(
            source.initialSnapshot(selectedItemIdentity: nil).items.count,
            NativeWorkspaceNavigatorSnapshotSource.maximumItems
        )
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-native-navigator-source-\(UUID().uuidString)",
            isDirectory: true
        )
        directories.append(directory)
        return directory
    }

    private func makeStore(projects: [Project], directory: URL) throws -> ProjectStore {
        let manager = StateManager(appSupportDirectory: directory)
        stateManagers.append(manager)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: projects)))
        return ProjectStore(stateManager: manager)
    }
}
