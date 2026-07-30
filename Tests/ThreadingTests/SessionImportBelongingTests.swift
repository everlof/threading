import XCTest
@testable import Threading

/// Which conversations a project may adopt, put against a **real** `git worktree` layout.
///
/// Every transcript records the directory it launched in, and `SessionImporter.belongs` decides
/// whether that directory is this project's checkout. Getting it wrong in the permissive
/// direction offers a user another checkout's conversations as though they were their own — and
/// the common layout for that is a worktree living *inside* the project folder
/// (`<repo>/.claude-worktrees/<branch>`), which a plain path-prefix test cannot tell from an
/// ordinary subdirectory.
///
/// Built with `git` itself rather than by hand. The rule turns on where git puts a linked
/// worktree's git directory and what it writes into the `.git` *file* that points at it; a
/// fixture I assemble from what I believe that layout to be would prove my belief, not the rule.
/// CLAUDE.md says these rules were "proven against a built layout" — this is that proof, run.
final class SessionImportBelongingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Self.hasGit, "git is not available on this machine")

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-belongs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    // MARK: - The rule

    func testAChatBelongsToTheCheckoutItRanIn() throws {
        let layout = try buildLayout()

        // The case almost every rollout takes, settled without touching disk.
        XCTAssertTrue(belongs(layout.main, to: layout))

        // An ordinary subdirectory of the checkout — an agent that spent ten minutes inside a
        // subpackage is still working in this project.
        let subdirectory = layout.main.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        XCTAssertTrue(belongs(subdirectory, to: layout))
    }

    /// The case the rule exists for: a separate checkout that happens to live *inside* the
    /// project's folder. It is a different branch with its own git directory, and its
    /// conversations are not this project's.
    func testANestedWorktreeIsNotPartOfTheProject() throws {
        let layout = try buildLayout()

        XCTAssertTrue(
            layout.nested.path.hasPrefix(layout.main.path + "/"),
            "the fixture is not actually nested, so it proves nothing"
        )
        XCTAssertFalse(belongs(layout.nested, to: layout))

        // Including from further inside it.
        let inside = layout.nested.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        XCTAssertFalse(belongs(inside, to: layout))
    }

    func testASiblingWorktreeIsNotPartOfTheProject() throws {
        let layout = try buildLayout()
        XCTAssertFalse(belongs(layout.sibling, to: layout))
    }

    /// A sibling directory whose name merely *starts* with the project's path. Prefix matching
    /// without the separator would adopt `/tmp/repo-notes` into `/tmp/repo`.
    func testAPathThatOnlySharesAPrefixIsNotPartOfTheProject() throws {
        let layout = try buildLayout()
        let lookalike = URL(fileURLWithPath: layout.main.path + "-notes")
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)

        XCTAssertFalse(belongs(lookalike, to: layout))
    }

    /// A project that is not a repository at all still adopts its own folder and subdirectories:
    /// with no worktree on either side there is nothing to disagree about.
    func testAFolderOutsideGitStillOwnsItself() throws {
        let plain = root.appendingPathComponent("plain")
        let inside = plain.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        XCTAssertTrue(
            SessionImporter.belongs(cwd: plain.path, folder: plain.path, worktree: nil)
        )
        XCTAssertTrue(
            SessionImporter.belongs(cwd: inside.path, folder: plain.path, worktree: nil)
        )
        XCTAssertFalse(
            SessionImporter.belongs(cwd: root.path, folder: plain.path, worktree: nil)
        )
    }

    // MARK: - Fixture

    private struct Layout {
        let main: URL
        let nested: URL
        let sibling: URL
        let worktree: String?
    }

    private func belongs(_ cwd: URL, to layout: Layout) -> Bool {
        SessionImporter.belongs(
            cwd: cwd.path,
            folder: layout.main.path,
            worktree: layout.worktree
        )
    }

    /// A main checkout, a linked worktree *inside* it, and one beside it.
    private func buildLayout() throws -> Layout {
        let main = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)

        try git(["init", "--initial-branch=main"], in: main)
        try git(["config", "user.email", "tests@example.com"], in: main)
        try git(["config", "user.name", "Threading Tests"], in: main)

        // `git worktree add` needs a commit to branch from.
        try "seed".write(
            to: main.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "."], in: main)
        try git(["commit", "-m", "seed"], in: main)

        let nested = main.appendingPathComponent(".claude-worktrees/nested")
        try git(["worktree", "add", "-b", "nested", nested.path], in: main)

        let sibling = root.appendingPathComponent("beside")
        try git(["worktree", "add", "-b", "beside", sibling.path], in: main)

        return Layout(
            main: main,
            nested: nested,
            sibling: sibling,
            worktree: GitInfo.worktreeIdentity(for: main.path)
        )
    }

    // MARK: - Git

    private static var hasGit: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // A repository built from the user's own git config could inherit hooks, templates or a
        // signing key, none of which this is about.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "git \(arguments.joined(separator: " ")) failed while building the fixture"
        )
    }
}
