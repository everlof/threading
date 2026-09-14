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
}
