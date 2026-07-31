import AppKit
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

// MARK: - The sheet

/// What the import sheet can be searched by, and what a row says about itself.
///
/// The list is the sheet: a busy project offers hundreds of past conversations, and the agent's
/// own summaries of them read alike — three of them beginning "Refactor the" is the ordinary
/// case, not the pathological one. So the identifier is here as a first-class way in, and every
/// row carries enough of one to be recognised.
@MainActor
final class SessionImportSheetTests: XCTestCase {

    private let sidebarID = "9f3c1a20-77b4-4e6d-9c02-5a1e8b3d40ff"
    private let toolbarID = "1188aa30-0000-4000-8000-000000000000"

    /// The reason identifiers are searchable at all: the reader is holding one — out of a hook's
    /// log, a `--resume` in their shell history, another window — and the titles cannot tell two
    /// conversations apart.
    func testAConversationIsFoundByItsIdentifier() {
        let sheet = makeSheet()

        sheet.updateSearchQuery(sidebarID)
        XCTAssertEqual(sheet.visibleSessionIDs, [sidebarID])

        // A fragment from the middle counts too: an id is quite often copied out of a path.
        sheet.updateSearchQuery("4e6d")
        XCTAssertEqual(sheet.visibleSessionIDs, [sidebarID])

        sheet.updateSearchQuery("Refactor")
        XCTAssertEqual(sheet.visibleSessionIDs, [sidebarID, toolbarID], "titles stopped matching")

        sheet.updateSearchQuery("")
        XCTAssertEqual(sheet.visibleSessionIDs, [sidebarID, toolbarID])
    }

    /// Every row shows some of its identifier whether or not anyone searched for one. It is the
    /// row's least interesting fact until it is the only one that matters.
    func testEveryRowShowsTheStartOfItsIdentifier() throws {
        let sheet = makeSheet()
        sheet.updateSearchQuery("")

        let row = try XCTUnwrap(sheet.rowViewForTesting(0))
        XCTAssertTrue(
            labels(in: row).contains(String(sidebarID.prefix(ImportLayout.identifierLength))),
            "the row said nothing about which conversation it is"
        )
    }

    /// The case a fixed prefix gets wrong. Matched in the middle, a row that went on showing its
    /// first eight characters would come back with nothing lit up in it — which reads as the
    /// sheet having found it for some other reason.
    func testARowShowsThePartOfItsIdentifierThatMatched() throws {
        let sheet = makeSheet()
        sheet.updateSearchQuery("4e6d")

        let row = try XCTUnwrap(sheet.rowViewForTesting(0))
        XCTAssertEqual(marks(in: row), ["4e6d"])
        XCTAssertTrue(
            labels(in: row).contains { $0.hasPrefix(ImportStrings.elision) && $0.contains("4e6d") },
            "the window did not slide to the match, or did not say it had"
        )
    }

    /// Pasting the whole identifier is the common way to use this, and the row is showing eight
    /// characters of a thirty-six character query. Every one of them is a character the reader
    /// typed, so all of them are marked.
    func testPastingAWholeIdentifierMarksTheCharactersTheRowIsShowing() throws {
        let sheet = makeSheet()
        sheet.updateSearchQuery(sidebarID)

        let row = try XCTUnwrap(sheet.rowViewForTesting(0))
        XCTAssertEqual(marks(in: row), [String(sidebarID.prefix(ImportLayout.identifierLength))])
    }

    // MARK: - Fixture

    private func makeSheet() -> SessionImportViewController {
        let sheet = SessionImportViewController(sessions: [
            session(id: sidebarID, title: "Refactor the sidebar"),
            session(id: toolbarID, title: "Refactor the toolbar")
        ])
        sheet.loadView()
        return sheet
    }

    private func session(id: String, title: String) -> ImportableSession {
        ImportableSession(
            agentSessionID: TranscriptID(id),
            kind: .claude,
            accountHandle: .standard,
            title: title,
            lastActiveAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func marks(in view: NSView) -> [String] {
        descendants(of: view)
            .compactMap { $0 as? SearchMatchLabel }
            .flatMap(\.markedTextForTesting)
    }

    private func labels(in view: NSView) -> [String] {
        descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
