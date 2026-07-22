import XCTest
@testable import Skalman

/// The scanner's two gates: git must ignore the path, *and* its name and marker must identify
/// it as a known build output. These tests exist because either gate alone deletes the wrong
/// thing.
final class ArtifactScannerTests: XCTestCase {

    // MARK: - Fixtures

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skalman-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try run("init")
        // A committed identity, so `check-ignore` has a repository to answer about.
        try write(".gitignore", """
            target/
            node_modules/
            .env.local
            secrets.yml
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(_ arguments: String...) throws -> Data {
        try GitProcess.run(arguments, in: root)
    }

    private func write(_ path: String, _ contents: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Kind Detection

    /// `target`, `build` and `dist` are ordinary words. Without the ecosystem's marker beside
    /// them the name proves nothing, and a directory called `target` next to no `Cargo.toml`
    /// is somebody's data.
    func testKindRequiresItsEcosystemMarker() throws {
        let bare = try directory("nested/target")
        XCTAssertNil(ArtifactKind.kind(for: bare))

        try write("nested/Cargo.toml", "[package]")
        XCTAssertEqual(ArtifactKind.kind(for: bare), .rust)
    }

    func testUnknownDirectoryIsNeverAKind() throws {
        XCTAssertNil(ArtifactKind.kind(for: try directory("src")))
        XCTAssertNil(ArtifactKind.kind(for: try directory("documents")))
    }

    // MARK: - The Ignore Gate

    /// The measured counter-example, and the reason ignore status alone can never be the rule:
    /// real projects ignore their secrets.
    func testIgnoredSecretsAreNotArtifacts() throws {
        try write(".env.local", "TOKEN=hunter2")
        try write("secrets.yml", "password: hunter2")

        // Both are genuinely ignored — that is the point.
        XCTAssertTrue(ArtifactScanner.isDisposable(root.appendingPathComponent(".env.local")))
        XCTAssertTrue(ArtifactScanner.isDisposable(root.appendingPathComponent("secrets.yml")))

        // And neither is ever offered, because neither is a known build output.
        let found = ArtifactScanner.scan(projectFolder: root.path)
        XCTAssertFalse(found.contains { $0.url.lastPathComponent == ".env.local" })
        XCTAssertFalse(found.contains { $0.url.lastPathComponent == "secrets.yml" })
    }

    /// The gap the ignore gate alone leaves open: a directory can be **matched by `.gitignore`
    /// and committed at the same time**, because git's rule is that tracked files are
    /// unaffected by the ignore list. `check-ignore` still calls it ignored, so without the
    /// tracking check this directory — whose contents exist nowhere else — would be offered
    /// for deletion.
    func testIgnoredButTrackedDirectoryIsRefused() throws {
        try write("vendored/Cargo.toml", "[package]")
        try write("vendored/target/keep.txt", "committed on purpose")

        // `-f` is required precisely because the path is ignored, which is the whole point.
        try run("add", "-f", "vendored")
        try run("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "keep")

        let tracked = root.appendingPathComponent("vendored/target")
        XCTAssertEqual(ArtifactKind.kind(for: tracked), .rust, "the name and marker do match")
        XCTAssertFalse(ArtifactScanner.isDisposable(tracked), "and git calls it ignored — but it is tracked")

        XCTAssertFalse(ArtifactScanner.scan(projectFolder: root.path).contains { $0.url == tracked })
    }

    /// Outside a repository nothing asserts a directory is regenerable, so nothing is offered.
    func testPathOutsideARepositoryIsRefused() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("skalman-loose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("target"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertFalse(ArtifactScanner.isDisposable(outside.appendingPathComponent("target")))
    }

    // MARK: - Scanning

    func testFindsIgnoredBuildOutputAndMeasuresIt() throws {
        try write("Cargo.toml", "[package]")
        try write("target/debug/binary", String(repeating: "x", count: 4096))

        let found = ArtifactScanner.scan(projectFolder: root.path)
        let rust = try XCTUnwrap(found.first { $0.kind == .rust })

        XCTAssertEqual(rust.url.lastPathComponent, "target")
        XCTAssertGreaterThan(rust.byteCount, 0)
        XCTAssertNotNil(rust.modifiedAt)
    }

    /// Build directories are full of hard links — Cargo alone left 37,810 files sharing 25,021
    /// inodes in one real `target/`. Counting a shared inode once per name reports space that
    /// deleting would not return, which is the one number this feature exists to state.
    func testHardLinksAreCountedOnce() throws {
        try write("Cargo.toml", "[package]")
        let payload = String(repeating: "x", count: 64 * 1024)
        try write("target/original", payload)

        let original = root.appendingPathComponent("target/original")
        for index in 0..<4 {
            try FileManager.default.linkItem(
                at: original,
                to: root.appendingPathComponent("target/link-\(index)")
            )
        }

        let artifact = try XCTUnwrap(
            ArtifactScanner.scan(projectFolder: root.path).first { $0.kind == .rust }
        )

        // Five names, one inode: the answer is one file's worth, not five.
        let onDisk = try XCTUnwrap(
            original.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
        )
        XCTAssertLessThan(artifact.byteCount, Int64(onDisk) * 2)
    }

    /// A `node_modules` containing a thousand nested `node_modules` is one answer, not a
    /// thousand — the walk stops at the top of what it finds.
    func testDoesNotDescendIntoWhatItFinds() throws {
        try write("package.json", "{}")
        try write("node_modules/pkg/package.json", "{}")
        _ = try directory("node_modules/pkg/node_modules")

        let found = ArtifactScanner.scan(projectFolder: root.path)
        XCTAssertEqual(found.filter { $0.kind == .node }.count, 1)
    }

    /// A repository's worktrees often live inside it, each with build output of its own — which
    /// is where the bulk of reclaimable space actually sits.
    func testAttributesNestedCheckoutsToThemselves() throws {
        try write("Cargo.toml", "[package]")
        try write("target/debug/binary", "x")

        let worktree = try directory(".worktrees/feature")
        try GitProcess.run(["init"], in: worktree)
        try ".gitignore".write(
            to: worktree.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "target/".write(
            to: worktree.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "[package]".write(
            to: worktree.appendingPathComponent("Cargo.toml"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("target"),
            withIntermediateDirectories: true
        )
        try "x".write(
            to: worktree.appendingPathComponent("target/binary"),
            atomically: true,
            encoding: .utf8
        )

        let found = ArtifactScanner.scan(projectFolder: root.path)
        let nested = try XCTUnwrap(found.first { $0.url.path.contains(".worktrees") })

        XCTAssertTrue(nested.isNestedCheckout(of: root.path))
        XCTAssertFalse(
            try XCTUnwrap(found.first { !$0.url.path.contains(".worktrees") })
                .isNestedCheckout(of: root.path)
        )
    }

    // MARK: - Removal

    func testRemovesOnlyWhatStillPassesBothGates() throws {
        try write("Cargo.toml", "[package]")
        try write("target/debug/binary", "x")

        let artifact = try XCTUnwrap(
            ArtifactScanner.scan(projectFolder: root.path).first { $0.kind == .rust }
        )

        // The marker disappearing between listing and deleting is exactly the staleness the
        // re-check exists for: without `Cargo.toml` this is no longer Cargo's directory.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Cargo.toml"))
        XCTAssertFalse(ArtifactScanner.isSafeToRemove(artifact))
        XCTAssertFalse(ArtifactScanner.remove(artifact))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))

        try write("Cargo.toml", "[package]")
        XCTAssertTrue(ArtifactScanner.remove(artifact))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.url.path))
    }
}
