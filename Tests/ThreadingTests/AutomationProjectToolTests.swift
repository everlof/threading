import XCTest

@testable import Threading

/// `manage_automation`'s `projects` and `addProject`: an agent asked to set up an automation can
/// find or add the project it runs in, instead of asking the person to read an id out of the app.
@MainActor
final class AutomationProjectToolTests: XCTestCase {
    private var directories: [URL] = []
    private var stateManagers: [StateManager] = []

    override func tearDown() async throws {
        for manager in stateManagers { manager.closeDatabase() }
        stateManagers = []
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        try await super.tearDown()
    }

    private func scratchDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-project-tool-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func scratchStore(_ projects: [Project] = []) throws -> ProjectStore {
        let manager = StateManager(appSupportDirectory: try scratchDirectory("state"))
        stateManagers.append(manager)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: projects)))
        return ProjectStore(stateManager: manager)
    }

    func testProjectsListTheIdsThatConfigureAccepts() throws {
        let alpha = Project(name: "Alpha", folderURL: URL(fileURLWithPath: "/tmp/alpha"))
        let beta = Project(name: "Beta", folderURL: URL(fileURLWithPath: "/tmp/beta"))
        let store = try scratchStore([alpha, beta])

        let page = AutomationToolActions.projectsPage(store.projects, cursor: nil)

        XCTAssertEqual(page.items.map(\.name), ["Alpha", "Beta"])
        XCTAssertNil(page.next)
        for item in page.items {
            let id = try XCTUnwrap(ProjectID(uuidString: item.id))
            XCTAssertNoThrow(try AutomationToolActions.requireKnownProject(
                AutomationConfiguration(projectID: id), exists: { store.project(withID: $0) != nil }))
        }
    }

    func testProjectsArePagedLikeHosts() {
        let projects = (0..<30).map { Project(name: "P\($0)", folderURL: URL(fileURLWithPath: "/tmp/p\($0)")) }

        let first = AutomationToolActions.projectsPage(projects, cursor: nil)
        let second = AutomationToolActions.projectsPage(projects, cursor: Int64(first.next ?? 0))

        XCTAssertEqual(first.items.count, 25)
        XCTAssertEqual(first.next, 25)
        XCTAssertEqual(second.items.map(\.name), ["P25", "P26", "P27", "P28", "P29"])
        XCTAssertNil(second.next)
    }

    func testAddProjectAddsAFolderOnceAndReturnsTheSameId() async throws {
        let store = try scratchStore()
        let folder = try scratchDirectory("folder")

        let first = try await AutomationToolActions.addProject(folder: folder.path, to: store)
        let again = try await AutomationToolActions.addProject(folder: folder.path + "/", to: store)

        XCTAssertTrue(first.added)
        XCTAssertFalse(again.added)
        XCTAssertEqual(first.project.id, again.project.id)
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertNotNil(store.project(withID: try XCTUnwrap(ProjectID(uuidString: first.project.id))))
    }

    func testAddProjectRefusesAnythingButAnExistingAbsoluteDirectory() async throws {
        let store = try scratchStore()
        let folder = try scratchDirectory("file")
        let file = folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)

        for candidate in [nil, "", "relative/folder", "~/somewhere", "/no/such/folder/\(UUID())", file.path] {
            do {
                _ = try await AutomationToolActions.addProject(folder: candidate, to: store)
                XCTFail("\(candidate ?? "nil") was added")
            } catch AutomationToolActions.Refusal.folderRequired {
            } catch {
                XCTFail("\(candidate ?? "nil"): unexpected error \(error)")
            }
        }
        XCTAssertTrue(store.projects.isEmpty)
    }
}
