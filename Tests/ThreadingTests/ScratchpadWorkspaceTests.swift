import XCTest
@testable import Threading

/// Where the scratchpad lives, and what provisioning it is allowed to do twice.
///
/// The location is the part worth pinning down in a test rather than a comment: it was chosen
/// *against* the obvious answer. Application Support is where the app's other owned checkouts
/// go, and it is the one place the scratchpad must not be, because Reset Everything renames
/// that whole directory aside — which is correct for a managed worktree, reproducible from a
/// real checkout, and wrong for the only copy of something the user wrote.
final class ScratchpadWorkspaceTests: XCTestCase {

    // MARK: - Fixtures

    /// The override is process-wide, so every test puts back what it found. It is written
    /// through `PreferenceStore`, which redirects to a scratch suite under a hosted test bundle
    /// — without that, a test here would repoint the developer's own scratchpad at a temporary
    /// directory that is deleted on the way out.
    private var savedOverride: URL?

    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(
            PreferenceStore.isRedirected,
            "this test writes a user choice and must not reach the real defaults domain"
        )
        savedOverride = ScratchpadWorkspace.configuredFolderURL

        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-scratchpad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        ScratchpadWorkspace.configuredFolderURL = savedOverride
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        try super.tearDownWithError()
    }

    /// A path inside the fixture directory, never the real default.
    private func scratchpadPath(_ name: String = "Scratchpad") -> URL {
        temporaryRoot.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Location

    /// `~/Threading/Scratchpad` — reachable from Finder and a terminal, and not inside a
    /// TCC-protected folder, so the agent's first write cannot raise a Documents prompt.
    func testDefaultFolderIsUnderTheHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

        XCTAssertEqual(
            ScratchpadWorkspace.defaultFolderURL,
            home
                .appendingPathComponent("Threading", isDirectory: true)
                .appendingPathComponent("Scratchpad", isDirectory: true)
                .standardizedFileURL
        )
    }

    /// The decision this whole type exists to encode: Reset Everything moves Application
    /// Support ▸ Threading aside, and the scratchpad must not go with it.
    func testDefaultFolderIsOutsideTheDirectoryResetEverythingMovesAside() {
        let support = AppDataLocations.supportDirectory.standardizedFileURL.path

        XCTAssertFalse(
            ScratchpadWorkspace.defaultFolderURL.path.hasPrefix(support),
            "a scratchpad under Application Support is erased by Reset Everything"
        )
    }

    func testAnOverrideReplacesTheDefaultAndClearingItRestoresTheDefault() {
        let chosen = scratchpadPath()

        ScratchpadWorkspace.configuredFolderURL = chosen
        XCTAssertEqual(ScratchpadWorkspace.folderURL, chosen.standardizedFileURL)

        ScratchpadWorkspace.configuredFolderURL = nil
        XCTAssertEqual(ScratchpadWorkspace.folderURL, ScratchpadWorkspace.defaultFolderURL)
    }

    /// A relative path is not a folder anyone can launch an agent in, so a stored value that is
    /// not absolute reads as no override rather than as a location.
    func testARelativeStoredPathIsIgnored() {
        PreferenceStore.shared.set("Threading/Scratchpad", forKey: ScratchpadDefaults.folderPathKey)

        XCTAssertNil(ScratchpadWorkspace.configuredFolderURL)
        XCTAssertEqual(ScratchpadWorkspace.folderURL, ScratchpadWorkspace.defaultFolderURL)
    }

    // MARK: - Provisioning

    func testPrepareCreatesTheFolderTheRepositoryAndTheSeedFiles() throws {
        let root = try ScratchpadWorkspace.prepare(at: scratchpadPath())

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertNotNil(GitInfo.repositoryIdentity(for: root.path))

        for name in [ScratchpadDefaults.readmeName, ScratchpadDefaults.gitignoreName] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(name).path
                ),
                "\(name) should have been seeded"
            )
        }
    }

    /// Every "New Scratchpad" calls this, so the second one must not undo the first. A README
    /// the user rewrote is theirs — the seed is a starting point, not a managed file.
    func testPreparingTwiceKeepsAnEditedReadme() throws {
        let root = try ScratchpadWorkspace.prepare(at: scratchpadPath())
        let readme = root.appendingPathComponent(ScratchpadDefaults.readmeName)
        try "mine".write(to: readme, atomically: true, encoding: .utf8)

        _ = try ScratchpadWorkspace.prepare(at: root)

        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "mine")
    }

    /// The first scratchpad gets one commit so the folder starts from a clean tree. The
    /// identity is set locally here because provisioning deliberately does not pass one — a
    /// commit made in the user's own repository is made as the user.
    func testTheFirstScratchpadIsCommitted() throws {
        let root = scratchpadPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitProcess.run(["init"], in: root)
        _ = try GitProcess.run(["config", "user.email", "test@example.com"], in: root)
        _ = try GitProcess.run(["config", "user.name", "Test"], in: root)

        _ = try ScratchpadWorkspace.prepare(at: root)

        let tracked = String(
            decoding: try GitProcess.run(["ls-files"], in: root),
            as: UTF8.self
        )
        XCTAssertTrue(tracked.contains(ScratchpadDefaults.readmeName))
        XCTAssertTrue(tracked.contains(ScratchpadDefaults.gitignoreName))
    }

    /// A commit that cannot be made is not a scratchpad that cannot be used: the folder is the
    /// hard requirement, and the seeds simply stay untracked where Git Review will show them.
    func testProvisioningSucceedsWithoutACommittableIdentity() throws {
        let root = try ScratchpadWorkspace.prepare(at: scratchpadPath())

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(ScratchpadDefaults.readmeName).path
            )
        )
    }

    func testPrepareRefusesAPathHeldByAFile() throws {
        // Not `scratchpadPath`: that spells a directory URL, and writing a file through one is
        // its own failure rather than the one under test.
        let occupied = temporaryRoot.appendingPathComponent("taken")
        try "not a folder".write(to: occupied, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ScratchpadWorkspace.prepare(at: occupied)) { error in
            XCTAssertEqual(
                error as? ScratchpadWorkspace.Failure,
                .notADirectory(occupied.standardizedFileURL.path)
            )
        }
    }

    // MARK: - Relocating

    func testRelocateMovesTheFolderAndRecordsTheChoice() throws {
        let origin = try ScratchpadWorkspace.prepare(at: scratchpadPath("origin"))
        ScratchpadWorkspace.configuredFolderURL = origin
        let note = origin.appendingPathComponent("note.md")
        try "kept".write(to: note, atomically: true, encoding: .utf8)

        let destination = scratchpadPath("moved")
        let landed = try ScratchpadWorkspace.relocate(to: destination)

        XCTAssertEqual(landed, destination.standardizedFileURL)
        XCTAssertEqual(ScratchpadWorkspace.configuredFolderURL, destination.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: origin.path))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("note.md"), encoding: .utf8),
            "kept"
        )
    }

    /// Merging two scratchpads is not a thing this can do safely, so an occupied destination is
    /// refused rather than written into.
    func testRelocateRefusesAnOccupiedDestination() throws {
        let origin = try ScratchpadWorkspace.prepare(at: scratchpadPath("origin"))
        ScratchpadWorkspace.configuredFolderURL = origin

        let destination = scratchpadPath("occupied")
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try ScratchpadWorkspace.relocate(to: destination)) { error in
            XCTAssertEqual(
                error as? ScratchpadWorkspace.Failure,
                .destinationExists(destination.standardizedFileURL.path)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: origin.path))
        XCTAssertEqual(ScratchpadWorkspace.configuredFolderURL, origin.standardizedFileURL)
    }

    /// "Use Default" with nothing on disk records the choice and touches no filesystem — which
    /// is also what keeps this test from creating a folder in the developer's home directory.
    func testClearingTheOverrideWithNoFolderYetMovesNothing() throws {
        ScratchpadWorkspace.configuredFolderURL = scratchpadPath("never-made")
        let defaultExistedBefore = FileManager.default.fileExists(
            atPath: ScratchpadWorkspace.defaultFolderURL.path
        )

        let landed = try ScratchpadWorkspace.relocate(to: nil)

        XCTAssertEqual(landed, ScratchpadWorkspace.defaultFolderURL)
        XCTAssertNil(ScratchpadWorkspace.configuredFolderURL)
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: ScratchpadWorkspace.defaultFolderURL.path),
            defaultExistedBefore,
            "clearing an override must not conjure the default folder"
        )
    }

    func testRelocatingToWhereItAlreadyIsDoesNothing() throws {
        let origin = try ScratchpadWorkspace.prepare(at: scratchpadPath("origin"))
        ScratchpadWorkspace.configuredFolderURL = origin

        XCTAssertEqual(try ScratchpadWorkspace.relocate(to: origin), origin.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: origin.path))
    }

    /// The same folder, spelled the other way. `URL(fileURLWithPath:)` carries no trailing slash
    /// and `appendingPathComponent(_:isDirectory: true)` does, so the two compare unequal while
    /// naming one directory — and the store hands back the first while an open panel hands back
    /// the second. Unnormalised, choosing the folder the scratchpad is already in read as a move
    /// onto itself and failed with "something is already there".
    func testRelocatingToTheSameFolderSpelledAsAPlainPathDoesNothing() throws {
        let origin = try ScratchpadWorkspace.prepare(at: scratchpadPath("origin"))
        ScratchpadWorkspace.configuredFolderURL = origin

        let spelledAsAPath = URL(fileURLWithPath: origin.path)

        XCTAssertNoThrow(try ScratchpadWorkspace.relocate(to: spelledAsAPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: origin.path))
        XCTAssertEqual(ScratchpadWorkspace.configuredFolderURL, origin.standardizedFileURL)
    }

    // MARK: - The store's row

    /// The row is flagged rather than matched by path, which is what lets the folder move
    /// without the chats inside it becoming a second scratchpad.
    @MainActor
    func testMovingTheFolderRePointsTheSameRow() throws {
        try withIsolatedStore { store in
            let first = try XCTUnwrap(store.ensureScratchpadProject(at: scratchpadPath("one")))

            let second = try XCTUnwrap(store.ensureScratchpadProject(at: scratchpadPath("two")))

            XCTAssertEqual(second.id, first.id)
            XCTAssertEqual(
                second.folderPath,
                scratchpadPath("two").resolvingSymlinksInPath().path
            )
            XCTAssertEqual(store.projects.filter(\.isTheScratchpad).count, 1)
        }
    }

    /// A folder the user had already added by hand is adopted, not duplicated — the same answer
    /// `addProject` gives for a path it already holds.
    @MainActor
    func testAFolderAlreadyAddedAsAProjectIsAdopted() throws {
        try withIsolatedStore { store in
            let folder = scratchpadPath("existing")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let added = try XCTUnwrap(store.addProject(folderURL: folder))

            let scratchpad = try XCTUnwrap(store.ensureScratchpadProject(at: folder))

            XCTAssertEqual(scratchpad.id, added.id)
            XCTAssertTrue(scratchpad.isTheScratchpad)
            XCTAssertEqual(store.projects.count, 1)
        }
    }

    @MainActor
    func testThereIsNoScratchpadUntilOneIsStarted() throws {
        try withIsolatedStore { store in
            XCTAssertNil(store.scratchpadProject)
        }
    }

    /// Never `ProjectStore.shared`: this bundle is hosted in the app, and the shared store's
    /// reconciling save is what once deleted a developer's real projects.
    @MainActor
    private func withIsolatedStore(_ body: (ProjectStore) throws -> Void) rethrows {
        let manager = StateManager(
            appSupportDirectory: temporaryRoot.appendingPathComponent("state", isDirectory: true)
        )
        defer { manager.closeDatabase() }
        try body(ProjectStore(stateManager: manager))
    }
}
