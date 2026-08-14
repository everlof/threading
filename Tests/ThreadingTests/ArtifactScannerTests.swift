import XCTest
@testable import Threading

/// The scanner's two gates: git must ignore the path, *and* its name and marker must identify
/// it as a known build output. These tests exist because either gate alone deletes the wrong
/// thing.
///
/// The scratch scope replaces the first gate rather than relaxing it — a manifest its own tool
/// wrote, in a location the walk is allowed to look at — so the tests at the end are about what
/// that replacement still refuses.
final class ArtifactScannerTests: XCTestCase {

    // MARK: - Fixtures

    private var root: URL!

    /// A stand-in scratch root. It lives under the per-user temporary directory, which *is* one
    /// of the scratch roots, so the containment gate holds for these fixtures the same way it
    /// holds for a real finding.
    private var scratch: URL!

    private enum Manifest {
        static let fileName = "info.plist"
        static let workspaceKey = "WorkspacePath"
        static let lastAccessedKey = "LastAccessedDate"
        static let requiredDirectories = ["Build", "ModuleCache.noindex"]
        static let payloadBytes = 4096
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

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
        try? FileManager.default.removeItem(at: scratch)
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

    /// A directory shaped exactly the way Xcode writes DerivedData: `info.plist` naming the
    /// workspace, with `Build/` and `ModuleCache.noindex/` beside it. The names are spelled out
    /// here rather than taken from `ScratchDefaults` because they are Xcode's contract, and a
    /// test that reads them from the code under test would agree with any change to it.
    @discardableResult
    private func derivedData(
        _ path: String,
        workspacePath: String,
        lastAccessed: Date? = nil,
        in base: URL? = nil
    ) throws -> URL {
        let url = (base ?? scratch).appendingPathComponent(path)
        for name in Manifest.requiredDirectories {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        try String(repeating: "x", count: Manifest.payloadBytes).write(
            to: url.appendingPathComponent("Build/Products.o"),
            atomically: true,
            encoding: .utf8
        )

        var contents: [String: Any] = [Manifest.workspaceKey: workspacePath]
        if let lastAccessed { contents[Manifest.lastAccessedKey] = lastAccessed }
        let data = try PropertyListSerialization.data(
            fromPropertyList: contents,
            format: .xml,
            options: 0
        )
        try data.write(to: url.appendingPathComponent(Manifest.fileName))

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
            .appendingPathComponent("threading-loose-\(UUID().uuidString)")
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
        _ = try GitProcess.run(["init"], in: worktree)
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

    // MARK: - The Manifest Gate

    /// DerivedData has no name to match on: the trees measured under `/tmp` were called `dd`,
    /// `verify-dd` and `threading-theme-polish-dd`. What identifies them is the shape Xcode
    /// wrote, so that is what the scratch walk asks about.
    func testFindsDerivedDataWhateverTheDirectoryIsCalled() throws {
        try derivedData("dd", workspacePath: "/repo/App.xcodeproj")
        try derivedData("verify-dd", workspacePath: "/repo/App.xcodeproj")

        let found = ArtifactScanner.scanScratch(roots: [scratch])

        XCTAssertEqual(Set(found.map(\.url.lastPathComponent)), ["dd", "verify-dd"])
        XCTAssertTrue(found.allSatisfy { $0.kind == .xcodeDerivedData })
        XCTAssertTrue(found.allSatisfy { $0.byteCount > 0 })
        XCTAssertTrue(found.allSatisfy { $0.checkoutPath == scratch.path })
    }

    /// And the name-first answer stays name-first, so nothing about the project scan changes:
    /// a `dd` inside a project folder is still not a finding.
    func testNameFirstRecognitionNeverAnswersDerivedData() throws {
        let tree = try derivedData("dd", workspacePath: "/repo/App.xcodeproj")

        XCTAssertNil(ArtifactKind.kind(for: tree))
        XCTAssertNotNil(DerivedDataManifest.read(inDirectory: tree))
    }

    /// Two names are not the shape. A directory carrying a manifest and a `Build/` but no
    /// module cache was written by something else, and something else's directory is not this
    /// tool's to offer.
    func testDirectoryWithoutTheModuleCacheIsNotDerivedData() throws {
        let partial = try derivedData("half-dd", workspacePath: "/repo/App.xcodeproj")
        try FileManager.default.removeItem(at: partial.appendingPathComponent("ModuleCache.noindex"))

        XCTAssertNil(DerivedDataManifest.read(inDirectory: partial))
        XCTAssertTrue(ArtifactScanner.scanScratch(roots: [scratch]).isEmpty)
    }

    /// The manifest names its own workspace, which is the attribution the page needs — and a
    /// workspace that no longer exists is the safest tier of all, not a reason to skip the row:
    /// nothing can rebuild into an orphan and nothing will read it again.
    func testCapturesTheWorkspacePathAndStillOffersOrphans() throws {
        let vanished = scratch.appendingPathComponent("gone/App.xcodeproj").path
        try derivedData("dd", workspacePath: vanished)

        let found = try XCTUnwrap(ArtifactScanner.scanScratch(roots: [scratch]).first)

        XCTAssertEqual(found.workspacePath, vanished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vanished))
    }

    /// `LastAccessedDate` is the build system's own record of when it last used the tree, which
    /// beats guessing from whichever file inside happened to be written last.
    func testManifestDateWinsWhenItIsTheNewerReading() throws {
        let later = Date().addingTimeInterval(60 * 60)
        try derivedData("dd", workspacePath: "/repo/App.xcodeproj", lastAccessed: later)

        let found = try XCTUnwrap(ArtifactScanner.scanScratch(roots: [scratch]).first)
        let modified = try XCTUnwrap(found.modifiedAt)

        XCTAssertEqual(modified.timeIntervalSince1970, later.timeIntervalSince1970, accuracy: 1)
    }

    /// **The scope boundary, and the test that should fail loudly if anyone relaxes the gate.**
    ///
    /// A `.git`-less copy of a repository is where an agent is working right now: it passes the
    /// *sufficient* gate (a `node_modules` beside a real `package.json`) and has no repository
    /// to answer the *necessary* one, and a wrong answer there destroys the only copy. So it is
    /// not offered — and the walk does not go into it at all. The well-formed DerivedData buried
    /// inside proves the second half: a filter would still have found it, a prune does not.
    func testRefusesARepositoryCopyAndNeverDescendsIntoIt() throws {
        let copy = scratch.appendingPathComponent("tree")
        try FileManager.default.createDirectory(
            at: copy.appendingPathComponent("node_modules/pkg"),
            withIntermediateDirectories: true
        )
        try "{}".write(
            to: copy.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        try derivedData("node_modules/pkg/dd", workspacePath: "/repo/App.xcodeproj", in: copy)

        // The name and the marker do identify it — that is the sufficient gate passing.
        XCTAssertEqual(ArtifactKind.kind(for: copy.appendingPathComponent("node_modules")), .node)

        XCTAssertTrue(ArtifactScanner.scanScratch(roots: [scratch]).isEmpty)
    }

    /// A name-gated kind in a scratch location is never offered, even where its marker sits
    /// right beside it — and the manifest branch cannot be reached to argue otherwise.
    func testNameGatedKindInAScratchLocationIsNeverOffered() throws {
        let crate = scratch.appendingPathComponent("crate")
        try FileManager.default.createDirectory(
            at: crate.appendingPathComponent("target/debug"),
            withIntermediateDirectories: true
        )
        try "[package]".write(
            to: crate.appendingPathComponent("Cargo.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "x".write(
            to: crate.appendingPathComponent("target/debug/binary"),
            atomically: true,
            encoding: .utf8
        )

        let target = crate.appendingPathComponent("target")
        XCTAssertEqual(ArtifactKind.kind(for: target), .rust)
        XCTAssertTrue(ArtifactScanner.scanScratch(roots: [scratch]).isEmpty)
        XCTAssertFalse(ArtifactScanner.isDisposableScratch(target, kind: .rust))
    }

    /// The scratch bound is shallower than the project scan's, because a scratch root holds
    /// session directories rather than a checkout. Every tree measured sat within 6 levels.
    func testStopsAtTheScratchDepthBound() throws {
        try derivedData("shallow-dd", workspacePath: "/repo/App.xcodeproj")
        try derivedData("a/b/c/d/e/f/edge-dd", workspacePath: "/repo/App.xcodeproj")
        try derivedData("a/b/c/d/e/f/g/deep-dd", workspacePath: "/repo/App.xcodeproj")

        let found = ArtifactScanner.scanScratch(roots: [scratch])

        XCTAssertEqual(Set(found.map(\.url.lastPathComponent)), ["shallow-dd", "edge-dd"])
    }

    /// `du` descends into bundles, and so must the measurement that claims to count the way it
    /// does: a DerivedData's `Build/Products` is full of `.app` bundles, and skipping package
    /// descendants would leave the built products out of the one number the feature promises.
    func testMeasuresWhatIsInsideAnAppBundle() throws {
        let tree = try derivedData("dd", workspacePath: "/repo/App.xcodeproj")
        let bundle = tree.appendingPathComponent("Build/Products/Demo.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try String(repeating: "y", count: Manifest.payloadBytes * 4).write(
            to: bundle.appendingPathComponent("payload"),
            atomically: true,
            encoding: .utf8
        )

        let found = try XCTUnwrap(ArtifactScanner.scanScratch(roots: [scratch]).first)

        XCTAssertGreaterThanOrEqual(found.byteCount, Int64(Manifest.payloadBytes * 5))
    }

    /// The manifest is re-read before a delete, not remembered from the listing: a tree stops
    /// being Xcode's the moment its `info.plist` goes.
    func testRefusesRemovingDerivedDataWhoseManifestHasGone() throws {
        try derivedData("dd", workspacePath: "/repo/App.xcodeproj")
        let artifact = try XCTUnwrap(ArtifactScanner.scanScratch(roots: [scratch]).first)

        XCTAssertTrue(ArtifactScanner.isSafeToRemove(artifact))

        try FileManager.default.removeItem(at: artifact.url.appendingPathComponent("info.plist"))

        XCTAssertFalse(ArtifactScanner.isSafeToRemove(artifact))
        XCTAssertFalse(ArtifactScanner.remove(artifact))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
    }

    /// The manifest alone would be a rule about any directory anywhere holding three names. The
    /// claim being made is about the scratch locations, so a tree outside them is refused however
    /// well-formed it is.
    func testRefusesDerivedDataOutsideTheScratchRoots() throws {
        let caches = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        let outside = caches.appendingPathComponent("threading-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let tree = try derivedData("dd", workspacePath: "/repo/App.xcodeproj", in: outside)
        XCTAssertNotNil(DerivedDataManifest.read(inDirectory: tree), "it is Xcode's tree by shape")

        XCTAssertFalse(ArtifactScanner.isSafeToRemove(ReclaimableArtifact(
            url: tree,
            kind: .xcodeDerivedData,
            byteCount: 0,
            modifiedAt: nil,
            checkoutPath: outside.path,
            workspacePath: "/repo/App.xcodeproj"
        )))
    }
}
