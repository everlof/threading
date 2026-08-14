import XCTest

@testable import Threading

/// The two halves of "a test bundle must not be able to delete the developer's projects".
///
/// This is a regression test for real, unrecoverable loss. `ProjectDatabase.save(_:)` reconciles
/// the whole graph, `StateManager.shared` resolved the user's own Application Support directory
/// even under a hosted XCTest bundle, and the test host never reaches `SingleInstanceLock` —
/// `AppDelegate.applicationDidFinishLaunching` returns on `NSClassFromString("XCTestCase")`
/// before acquiring it. A test that called `ProjectStore.shared.addProject` therefore wrote its
/// fixture list over the live store and deleted every project its snapshot predated, taking each
/// one's chats with it through `ON DELETE CASCADE`.
@MainActor
final class HostedStoreIsolationTests: HostedStoreTestCase {

    // MARK: - The Redirect

    /// The first half: a hosted test never resolves the user's own store.
    func testTheSharedStoreWritesToScratchRatherThanTheUsersApplicationSupport() throws {
        XCTAssertTrue(
            StateManager.sharedUsesHostedTestState,
            "without the redirect every test below is writing to the developer's real database"
        )

        let scratch = StateManager.hostedTestDirectory()
        XCTAssertTrue(
            scratch.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "the scratch store must live in the temporary directory, not beside the real one"
        )

        let store = ProjectStore.shared
        let project = try XCTUnwrap(
            store.addProject(
                folderURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("hosted-store-isolation-\(UUID().uuidString)")
            )
        )
        defer { _ = store.removeProject(id: project.id) }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent(SQLiteDefaults.databaseName).path
            ),
            "the fixture project was committed somewhere other than the scratch store"
        )

        let real = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Threading")
        XCTAssertNotEqual(
            scratch.standardizedFileURL,
            real.standardizedFileURL,
            "the scratch store resolved to the user's own directory"
        )
    }

    // MARK: - The Backstop

    /// The second half, and the exact shape of the loss: a writer holding a stale picture of the
    /// graph must refuse to reconcile rather than delete the rows it never saw.
    func testAStaleWholeGraphWriteCannotDeleteAProjectItNeverLoaded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(SQLiteDefaults.databaseName)
        let app = try ProjectDatabase(url: url)
        let testHost = try ProjectDatabase(url: url)
        defer {
            app.close()
            testHost.close()
        }

        // Both writers read the same empty graph, which is where the test host's snapshot freezes.
        _ = try app.load()
        _ = try testHost.load()

        // The user adds a project in the running app.
        let survivor = Project(
            name: "survivor",
            folderURL: URL(fileURLWithPath: "/tmp/survivor")
        )
        try app.save(ProjectsState(projects: [survivor]))

        // The test host now saves its own fixture list. Before the guard this silently executed
        // `DELETE FROM project WHERE id NOT IN (…)` and took `survivor` with it.
        let fixture = Project(
            name: "fixture",
            folderURL: URL(fileURLWithPath: "/tmp/fixture")
        )
        XCTAssertThrowsError(
            try testHost.save(ProjectsState(projects: [fixture])),
            "a writer two generations behind was allowed to reconcile the whole graph"
        ) { error in
            guard case ProjectDatabaseWriteError.staleGeneration = error else {
                return XCTFail("expected a stale-generation refusal, got \(error)")
            }
        }

        let reread = try app.load()
        XCTAssertEqual(
            reread.state.projects.map(\.name),
            ["survivor"],
            "the refused write must leave the store exactly as the other writer left it"
        )
    }

    /// The refusal is about staleness, not about there being two connections: a writer that reads
    /// the store back before saving is up to date and must be allowed through. Without this the
    /// guard would be indistinguishable from breaking every second write.
    func testAWriterThatHasReloadedIsAllowedToReconcile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(SQLiteDefaults.databaseName)
        let app = try ProjectDatabase(url: url)
        let other = try ProjectDatabase(url: url)
        defer {
            app.close()
            other.close()
        }

        _ = try app.load()
        _ = try other.load()

        try app.save(ProjectsState(projects: [
            Project(name: "first", folderURL: URL(fileURLWithPath: "/tmp/first"))
        ]))

        // Catching up is what makes the next reconcile legitimate.
        let caughtUp = try other.load()
        var projects = caughtUp.state.projects
        projects.append(Project(name: "second", folderURL: URL(fileURLWithPath: "/tmp/second")))
        XCTAssertNoThrow(try other.save(ProjectsState(projects: projects)))

        let reread = try other.load()
        XCTAssertEqual(reread.state.projects.map(\.name), ["first", "second"])
    }

    /// A store that has never counted a generation must still accept its first write, or the
    /// legacy `projects.json` import and every fresh install would refuse to save.
    func testAConnectionThatNeverLoadedAdoptsTheStoreRatherThanRefusingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(SQLiteDefaults.databaseName)
        let database = try ProjectDatabase(url: url)
        defer { database.close() }

        XCTAssertNoThrow(
            try database.save(ProjectsState(projects: [
                Project(name: "imported", folderURL: URL(fileURLWithPath: "/tmp/imported"))
            ]))
        )
        XCTAssertEqual(try database.load().state.projects.map(\.name), ["imported"])
    }
}
