import XCTest
@testable import Threading

@MainActor
final class GitMissingCheckoutTests: XCTestCase {
    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-checkout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        try Data("ref: refs/heads/main\n".utf8)
            .write(to: root.appendingPathComponent(".git/HEAD"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testMissingNestedCheckoutDoesNotBorrowParentIdentityOrBranch() throws {
        let root = try repository()
        let missing = root.appendingPathComponent(".claude/worktrees/removed")
        XCTAssertNil(GitInfo.repositoryRoot(for: missing.path))
        XCTAssertNil(GitInfo.worktreeLocation(for: missing.path))
        XCTAssertNil(GitInfo.repositoryIdentity(for: missing.path))
        XCTAssertNil(GitInfo.currentBranch(for: missing.path))
        XCTAssertEqual(GitInfo.currentBranch(for: root.path), "main")
    }

    func testExistingSubdirectoryStillResolvesButDeletionClearsIdentityOnRefresh() throws {
        let root = try repository()
        let child = root.appendingPathComponent("packages/client")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertEqual(GitInfo.currentBranch(for: child.path), "main")
        try FileManager.default.removeItem(at: child)
        GitInfo.invalidateCache(for: child.path)
        XCTAssertNil(GitInfo.worktreeLocation(for: child.path))
        XCTAssertNil(GitInfo.currentBranch(for: child.path))
    }

    func testSidebarKeepsMissingProjectOutsideParentRepository() throws {
        let root = try repository()
        let live = Project(name: "app-mono", folderURL: root)
        let missing = Project(
            name: "removed-worktree",
            folderURL: root.appendingPathComponent(".claude/worktrees/removed")
        )
        let nodes = SidebarTreeBuilder.rootNodes(from: [live, missing])
        XCTAssertEqual(nodes.count, 2)
        let repository = try XCTUnwrap(nodes.first as? RepoGroupNode)
        XCTAssertEqual(repository.projectNodes.map(\.projectID), [live.id])
        XCTAssertEqual((nodes.last as? ProjectNode)?.projectID, missing.id)
    }

    func testRememberedRepositoryKeepsMissingCheckoutGrouped() throws {
        let root = try repository()
        let live = Project(name: "app-mono", folderURL: root)
        var missing = Project(
            name: "removed-worktree",
            folderURL: root.deletingLastPathComponent().appendingPathComponent("removed-worktree")
        )
        missing.lastKnownRepositoryIdentity = try XCTUnwrap(
            GitInfo.repositoryIdentity(for: root.path)
        )

        let nodes = SidebarTreeBuilder.rootNodes(from: [live, missing])
        let repository = try XCTUnwrap(nodes.first as? RepoGroupNode)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(repository.projectNodes.map(\.projectID), [live.id, missing.id])
        XCTAssertEqual(repository.representativeProjectID, live.id)
        XCTAssertNil(GitInfo.currentBranch(for: missing.folderPath))
    }

    func testMissingCheckoutCannotBecomeRepositoryStartTarget() throws {
        let root = try repository()
        let live = Project(name: "app-mono", folderURL: root)
        var missing = Project(
            name: "removed-worktree",
            folderURL: root.deletingLastPathComponent().appendingPathComponent("removed-worktree")
        )
        missing.lastKnownRepositoryIdentity = try XCTUnwrap(
            GitInfo.repositoryIdentity(for: root.path)
        )

        let onlyMissing = try XCTUnwrap(
            SidebarTreeBuilder.rootNodes(from: [missing]).first as? RepoGroupNode
        )
        XCTAssertNil(onlyMissing.representativeProjectID)
        let mixed = try XCTUnwrap(
            SidebarTreeBuilder.rootNodes(from: [missing, live]).first as? RepoGroupNode
        )
        XCTAssertEqual(mixed.representativeProjectID, live.id)
    }

    func testStoredAffiliationSurvivesCheckoutRemovalAndReopening() throws {
        let root = try repository()
        let checkout = root.deletingLastPathComponent()
            .appendingPathComponent("linked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data("gitdir: \(root.path)/.git/worktrees/linked\n".utf8)
            .write(to: checkout.appendingPathComponent(".git"))
        addTeardownBlock { try? FileManager.default.removeItem(at: checkout) }

        let state = StateManager(appSupportDirectory: root.appendingPathComponent("app-state"))
        let store = ProjectStore(stateManager: state, refusesWrites: false)
        let main = try XCTUnwrap(store.addProject(folderURL: root))
        let added = try XCTUnwrap(store.addProject(folderURL: checkout))
        XCTAssertEqual(added.lastKnownRepositoryIdentity, GitInfo.repositoryIdentity(for: root.path))

        try FileManager.default.removeItem(at: checkout)
        GitInfo.invalidateCache(for: checkout.path)
        let reopened = ProjectStore(stateManager: state, refusesWrites: false)
        let saved = try XCTUnwrap(reopened.project(withID: added.id))
        XCTAssertEqual(saved.lastKnownRepositoryIdentity, GitInfo.repositoryIdentity(for: root.path))
        XCTAssertEqual(saved.folderPath, checkout.path)
        let nodes = SidebarTreeBuilder.rootNodes(from: reopened.projects)
        let repository = try XCTUnwrap(nodes.first as? RepoGroupNode)
        XCTAssertEqual(repository.projectNodes.map(\.projectID), [main.id, added.id])
        XCTAssertTrue(reopened.siblingCheckouts(of: main.id).isEmpty)
    }

    func testExistingAvailableProjectGetsAffiliationOnLoad() throws {
        let root = try repository()
        let state = StateManager(appSupportDirectory: root.appendingPathComponent("app-state"))
        let legacy = Project(name: "app-mono", folderURL: root)
        XCTAssertTrue(state.saveProjectsState(ProjectsState(projects: [legacy])))

        let loaded = ProjectStore(stateManager: state, refusesWrites: false)
        let identity = try XCTUnwrap(GitInfo.repositoryIdentity(for: root.path))
        XCTAssertEqual(loaded.project(withID: legacy.id)?.lastKnownRepositoryIdentity, identity)
        let reopened = ProjectStore(stateManager: state, refusesWrites: false)
        XCTAssertEqual(reopened.project(withID: legacy.id)?.lastKnownRepositoryIdentity, identity)
    }

    func testLegacyUnavailableCheckoutCanBeAssociatedWithoutMovingIt() throws {
        let root = try repository()
        let state = StateManager(appSupportDirectory: root.appendingPathComponent("app-state"))
        let store = ProjectStore(stateManager: state, refusesWrites: false)
        let main = try XCTUnwrap(store.addProject(folderURL: root))
        let missing = try XCTUnwrap(store.addProject(
            folderURL: root.deletingLastPathComponent()
                .appendingPathComponent("missing-\(UUID().uuidString)")
        ))
        let identity = try XCTUnwrap(GitInfo.repositoryIdentity(for: root.path))

        XCTAssertTrue(store.associateUnavailableCheckout(missing.id, withRepository: identity))
        let reopened = ProjectStore(stateManager: state, refusesWrites: false)
        let saved = try XCTUnwrap(reopened.project(withID: missing.id))
        XCTAssertEqual(saved.folderPath, missing.folderPath)
        XCTAssertEqual(saved.lastKnownRepositoryIdentity, identity)
        let repository = try XCTUnwrap(
            SidebarTreeBuilder.rootNodes(from: reopened.projects).first as? RepoGroupNode
        )
        XCTAssertEqual(repository.projectNodes.map(\.projectID), [main.id, missing.id])
    }
}
