import XCTest
@testable import Threading

/// The dormant-branch follower: `ProjectStore.refreshBranches(forCheckoutAt:)`, which moves
/// every session standing in a checkout together, and `CheckoutBranchFollower`, which keys
/// one watcher per checkout and gates itself on the setting.
///
/// Checkouts are fabricated as a `.git` directory holding a `HEAD` file — everything
/// `GitInfo` reads for a branch — so no test shells out to git. FSEvents delivery itself is
/// not awaited here; the follower's read paths (start-up catch-up, reconcile) are driven
/// synchronously, and the watcher's filtering is pinned in `GitCheckoutWatcherTests`.
@MainActor
final class CheckoutBranchFollowerTests: XCTestCase {

    private var testDirectory: URL!

    override func setUpWithError() throws {
        // Symlinks resolved up front (`/var` vs `/private/var`), so paths derived here and
        // paths normalised by the store agree about the checkout's identity.
        testDirectory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("CheckoutBranchFollowerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    // MARK: - Refreshing a Checkout

    func testCheckoutRefreshMovesEverySessionInTheCheckout() throws {
        let store = makeStore()
        let checkout = try makeCheckout(named: "app", branch: "main")
        let subfolder = try makeSubfolder(of: checkout, named: "docs")
        let elsewhere = try makeCheckout(named: "elsewhere", branch: "main")

        let project = store.addProject(folderURL: checkout)
        let subProject = store.addProject(folderURL: subfolder)
        let otherProject = store.addProject(folderURL: elsewhere)
        store.addSession(to: project.id, kind: .claude)
        store.addSession(to: project.id, kind: .claude)
        store.addSession(to: subProject.id, kind: .codex)
        store.addSession(to: otherProject.id, kind: .claude)

        try setBranch("feature", in: checkout)
        store.refreshBranches(forCheckoutAt: project.folderPath)

        XCTAssertEqual(branches(of: project.id, in: store), ["feature", "feature"])
        // A project added at a subfolder stands in the same checkout, so it moves too.
        XCTAssertEqual(branches(of: subProject.id, in: store), ["feature"])
        // Another repository entirely does not.
        XCTAssertEqual(branches(of: otherProject.id, in: store), ["main"])
    }

    func testADetachedReadingLeavesEveryRecordAlone() throws {
        let store = makeStore()
        let checkout = try makeCheckout(named: "app", branch: "main")
        let project = store.addProject(folderURL: checkout)
        store.addSession(to: project.id, kind: .claude)

        // A rebase detaches HEAD for seconds at a time; the follower's path never applies
        // the flicker. A genuine detachment is `refreshBranch`'s per-session business.
        try detachHead(in: checkout)
        store.refreshBranches(forCheckoutAt: project.folderPath)

        XCTAssertEqual(branches(of: project.id, in: store), ["main"])
    }

    func testCheckoutRefreshMovesStandaloneTerminalBranch() throws {
        let store = makeStore()
        let checkout = try makeCheckout(named: "terminal", branch: "main")
        let project = store.addProject(folderURL: checkout)
        let terminal = try XCTUnwrap(store.addTerminal(to: project.id))

        try setBranch("feature", in: checkout)
        store.refreshBranches(forCheckoutAt: checkout.path)

        XCTAssertEqual(store.terminal(withID: terminal.id)?.branch, "feature")
    }

    func testTerminalCwdMovesItToTheMostSpecificKnownProject() throws {
        let store = makeStore()
        let checkout = try makeCheckout(named: "app", branch: "main")
        let docs = try makeSubfolder(of: checkout, named: "docs")
        let home = store.addProject(folderURL: checkout)
        let docsProject = store.addProject(folderURL: docs)
        let terminal = try XCTUnwrap(store.addTerminal(to: home.id))

        store.updateTerminalLocation(docs.path, for: terminal.id)

        XCTAssertEqual(store.homeProject(forTerminalID: terminal.id)?.id, home.id)
        XCTAssertEqual(store.displayProject(forTerminalID: terminal.id)?.id, docsProject.id)
    }

    // MARK: - The Follower

    func testStartCatchesUpABranchThatMovedWhileUnwatched() throws {
        let store = makeStore()
        let checkout = try makeCheckout(named: "app", branch: "main")
        let project = store.addProject(folderURL: checkout)
        store.addSession(to: project.id, kind: .claude)

        // The switch happens before any watcher exists — the closed-app case.
        try setBranch("feature", in: checkout)
        let follower = CheckoutBranchFollower(store: store)
        follower.start()

        XCTAssertEqual(branches(of: project.id, in: store), ["feature"])
    }

    func testTheFollowerWatchesEachCheckoutOnceAndOnlyWhileEnabled() throws {
        let store = makeStore()
        let checkout = try makeCheckout(named: "app", branch: "main")
        let subfolder = try makeSubfolder(of: checkout, named: "docs")
        let plainFolder = testDirectory.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)

        store.addProject(folderURL: checkout)
        store.addProject(folderURL: subfolder)
        store.addProject(folderURL: plainFolder)

        let follower = CheckoutBranchFollower(store: store)
        follower.start()

        // Two projects, one checkout, one stream — and none for a folder outside git.
        XCTAssertEqual(follower.watchedIdentities.count, 1)

        UserDefaults.standard.set(false, forKey: "followsCheckoutBranch")
        defer { UserDefaults.standard.removeObject(forKey: "followsCheckoutBranch") }
        NotificationCenter.default.post(AppSettingsDidChange())
        XCTAssertTrue(follower.watchedIdentities.isEmpty)

        UserDefaults.standard.set(true, forKey: "followsCheckoutBranch")
        NotificationCenter.default.post(AppSettingsDidChange())
        XCTAssertEqual(follower.watchedIdentities.count, 1)
    }

    func testAProjectAddedLaterIsPickedUpThroughTheStoreNotification() throws {
        let store = makeStore()
        let follower = CheckoutBranchFollower(store: store)
        follower.start()
        XCTAssertTrue(follower.watchedIdentities.isEmpty)

        let checkout = try makeCheckout(named: "late", branch: "main")
        store.addProject(folderURL: checkout)

        XCTAssertEqual(follower.watchedIdentities.count, 1)
    }

    // MARK: - Fixtures

    private func makeStore() -> ProjectStore {
        ProjectStore(stateManager: StateManager(
            appSupportDirectory: testDirectory.appendingPathComponent("state", isDirectory: true),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        ))
    }

    /// A checkout is, to `GitInfo`, a folder whose `.git` directory holds a `HEAD` file.
    private func makeCheckout(named name: String, branch: String) throws -> URL {
        let root = testDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try setBranch(branch, in: root)
        return root
    }

    private func makeSubfolder(of checkout: URL, named name: String) throws -> URL {
        let subfolder = checkout.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        return subfolder
    }

    private func setBranch(_ branch: String, in root: URL) throws {
        try Data("ref: refs/heads/\(branch)\n".utf8)
            .write(to: root.appendingPathComponent(".git/HEAD"))
    }

    private func detachHead(in root: URL) throws {
        try Data("0123456789abcdef0123456789abcdef01234567\n".utf8)
            .write(to: root.appendingPathComponent(".git/HEAD"))
    }

    private func branches(of projectID: ProjectID, in store: ProjectStore) -> [String?] {
        store.project(withID: projectID)?.sessions.map(\.branch) ?? []
    }
}
