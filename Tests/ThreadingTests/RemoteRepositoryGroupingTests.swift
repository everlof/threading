import XCTest
@testable import Threading

/// What the paired phone is told about which checkouts belong together.
///
/// Real repositories on disk rather than stubbed paths, for the same reason
/// `SidebarTreeBuilderTests` uses them: the grouping key is `git rev-parse --git-common-dir`
/// read off disk, and a fake path answers "not a repository", so every assertion here would
/// pass against a description that grouped nothing at all.
final class RemoteRepositoryGroupingTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRepository(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-grouping-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        _ = try GitProcess.run(["init"], in: root)
        _ = try GitProcess.run(["config", "user.email", "tests@example.com"], in: root)
        _ = try GitProcess.run(["config", "user.name", "Tests"], in: root)
        try "seed".write(
            to: root.appendingPathComponent("seed.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try GitProcess.run(["add", "."], in: root)
        _ = try GitProcess.run(["commit", "-m", "seed"], in: root)
        return root
    }

    private func makeWorktree(named branch: String, of repository: URL) throws -> URL {
        let destination = repository
            .deletingLastPathComponent()
            .appendingPathComponent("\(repository.lastPathComponent)-\(branch)")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

        _ = try GitProcess.run(["worktree", "add", "-b", branch, destination.path], in: repository)
        return destination
    }

    private func project(_ name: String, at folder: URL) -> Project {
        Project(name: name, folderURL: folder)
    }

    // MARK: - Tests

    /// The whole point of sending this: the phone orders by name, and a worktree's directory
    /// name says nothing about the project it grew from once that project has been renamed.
    func testEveryCheckoutOfOneRepositoryCarriesTheSameIdentity() throws {
        let repository = try makeRepository(named: "grouped")
        let worktree = try makeWorktree(named: "experiment", of: repository)
        let main = project("Threading", at: repository)
        let linked = project(worktree.lastPathComponent, at: worktree)

        let described = RemoteRepositoryGrouping.describe([main, linked])

        XCTAssertEqual(
            described[main.id]?.id,
            described[linked.id]?.id,
            "a worktree was given an identity of its own"
        )
        XCTAssertEqual(described[main.id]?.isMainCheckout, true)
        XCTAssertEqual(described[linked.id]?.isMainCheckout, false)
    }

    /// Renaming the project that answers for a repository renames the group on the phone, which
    /// is what it already does to the Mac's own repository row.
    func testTheRepositoryIsNamedAfterItsMainWorkingTreesProject() throws {
        let repository = try makeRepository(named: "named")
        let worktree = try makeWorktree(named: "poc", of: repository)

        let described = RemoteRepositoryGrouping.describe([
            project("Threading", at: repository),
            project(worktree.lastPathComponent, at: worktree),
        ])

        XCTAssertEqual(Set(described.values.map(\.name)), ["Threading"])
    }

    /// Asked for by what a checkout *is*, not by position: the arrangement is the user's, and a
    /// worktree can stand anywhere in it.
    func testALinkedWorktreeListedFirstDoesNotSpeakForTheRepository() throws {
        let repository = try makeRepository(named: "ordered")
        let worktree = try makeWorktree(named: "first", of: repository)
        let linked = project("Linked", at: worktree)
        let main = project("Threading", at: repository)

        let described = RemoteRepositoryGrouping.describe([linked, main])

        XCTAssertEqual(described[linked.id]?.name, "Threading")
        XCTAssertEqual(described[linked.id]?.isMainCheckout, false)
        XCTAssertEqual(described[main.id]?.isMainCheckout, true)
    }

    /// A package inside a monorepo resolves to the monorepo's git directory and has no worktree
    /// name of its own, so "not a linked worktree" is not enough to make it answer for the
    /// repository — it would name the whole group after itself.
    func testAPackageInsideARepositoryDoesNotNameThatRepository() throws {
        let repository = try makeRepository(named: "monorepo")
        let package = repository.appendingPathComponent("packages/api")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        let inner = project("api", at: package)
        let described = RemoteRepositoryGrouping.describe([inner])

        XCTAssertEqual(described[inner.id]?.isMainCheckout, false)
        XCTAssertNotEqual(described[inner.id]?.name, "api")
    }

    /// A repository whose main working tree was never added is still a repository, and its
    /// worktrees still belong together — it just has to be named after the directory holding
    /// the shared git directory.
    func testCheckoutsGroupEvenWhenTheMainWorkingTreeIsNotAdded() throws {
        let repository = try makeRepository(named: "absent")
        let first = try makeWorktree(named: "one", of: repository)
        let second = try makeWorktree(named: "two", of: repository)
        let left = project("one", at: first)
        let right = project("two", at: second)

        let described = RemoteRepositoryGrouping.describe([left, right])

        XCTAssertEqual(described[left.id]?.id, described[right.id]?.id)
        XCTAssertEqual(described[left.id]?.name, repository.lastPathComponent)
        XCTAssertEqual(described[left.id]?.isMainCheckout, false)
        XCTAssertEqual(described[right.id]?.isMainCheckout, false)
    }

    /// The scratchpad answers "no repository" even though it is one — the same exemption the
    /// sidebar makes, so it cannot drag a project the user added inside it into a group.
    func testTheScratchpadIsNotGrouped() throws {
        let repository = try makeRepository(named: "scratch")
        var scratchpad = project("Scratchpad", at: repository)
        scratchpad.isScratchpad = true

        XCTAssertTrue(RemoteRepositoryGrouping.describe([scratchpad]).isEmpty)
    }

    /// A folder outside any repository has nothing to group with, and says so by being absent
    /// rather than by inventing an identity the phone would then sort by.
    func testAFolderOutsideARepositoryIsNotDescribed() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-grouping-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        XCTAssertTrue(RemoteRepositoryGrouping.describe([project("Plain", at: folder)]).isEmpty)
    }

    /// The identity is a digest, not the `git-common-dir` path: the owner catalogue publishes a
    /// project's name and never its location.
    func testThePublishedIdentityDoesNotCarryTheCheckoutPath() throws {
        let repository = try makeRepository(named: "opaque")
        let main = project("Threading", at: repository)

        let identity = try XCTUnwrap(RemoteRepositoryGrouping.describe([main])[main.id]?.id)

        XCTAssertFalse(identity.contains("/"))
        XCTAssertFalse(identity.contains(repository.lastPathComponent))
        XCTAssertEqual(identity.count, 32)
    }
}
