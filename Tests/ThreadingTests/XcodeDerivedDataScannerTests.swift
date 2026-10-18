import XCTest
@testable import Threading

final class XcodeDerivedDataScannerTests: XCTestCase {
    private var directory: URL!
    private var root: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-xcode-scan-\(UUID().uuidString)")
        root = directory.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func tree(_ name: String, contents: String = "Build") throws -> URL {
        let url = root.appendingPathComponent(name)
        let output = url.appendingPathComponent(contents)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: output.appendingPathComponent("payload"))
        try writeManifest(url)
        return url
    }

    private func writeManifest(_ url: URL, workspace: String = "/missing/App.xcodeproj") throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0
        )
        try data.write(to: url.appendingPathComponent("info.plist"))
    }

    private func age(_ url: URL) throws {
        let old = Date().addingTimeInterval(-3600)
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
        for case let child as URL in walker {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: child.path)
        }
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }

    func testStandardLayoutDoesNotRequireAPrivateModuleCache() throws {
        let build = try tree("App-abc")
        let logs = try tree("Cleaned-def", contents: "Logs")
        let index = try tree("Indexed-ghi", contents: "Index.noindex")
        let shared = root.appendingPathComponent("ModuleCache.noindex")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        let found = XcodeDerivedDataScanner.scan(root: root)
        XCTAssertEqual(Set(found.map(\.url.lastPathComponent)), Set([build, logs, index].map(\.lastPathComponent)))
        XCTAssertTrue(found.allSatisfy { $0.byteCount >= 4096 && $0.workspacePath == "/missing/App.xcodeproj" })
        XCTAssertNil(XcodeDerivedDataScanner.vet(shared, root: root))
        XCTAssertNil(DerivedDataManifest.read(inDirectory: build), "the scratch recognizer stays strict")
    }

    func testRootDescendantsMissingManifestsAndRelativeWorkspacesAreRefused() throws {
        let good = try tree("Good")
        let unknown = try tree("Unknown")
        try FileManager.default.removeItem(at: unknown.appendingPathComponent("info.plist"))
        let relative = try tree("Relative")
        try writeManifest(relative, workspace: "App.xcodeproj")
        let nested = try tree("Good/Nested")
        XCTAssertEqual(XcodeDerivedDataScanner.scan(root: root).map(\.url.lastPathComponent), ["Good"])
        for url in [root!, good.appendingPathComponent("Build"), unknown, relative, nested] {
            XCTAssertEqual(ArtifactScanner.vet(url, roots: [directory], derivedDataRoot: root), .refused(.unrecognised))
        }
    }

    func testSymlinkedCacheOrManifestCannotBorrowEvidence() throws {
        let good = try tree("Good")
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: good)
        XCTAssertNil(XcodeDerivedDataScanner.vet(alias, root: root))
        let outside = directory.appendingPathComponent("manifest.plist")
        try FileManager.default.moveItem(at: good.appendingPathComponent("info.plist"), to: outside)
        try FileManager.default.createSymbolicLink(at: good.appendingPathComponent("info.plist"), withDestinationURL: outside)
        XCTAssertNil(XcodeDerivedDataScanner.vet(good, root: root))
    }

    func testIncompleteMeasurementIsOmittedAndBundlesAreMeasured() throws {
        let url = try tree("App", contents: "Build/Products/App.app/Contents")
        XCTAssertTrue(XcodeDerivedDataScanner.scan(root: root, maximumEntries: 2).isEmpty)
        let found = try XCTUnwrap(XcodeDerivedDataScanner.scan(root: root).first)
        XCTAssertGreaterThanOrEqual(found.byteCount, 4096)
        guard case .vetted(let vetted) = ArtifactScanner.vet(url, roots: [], derivedDataRoot: root) else {
            return XCTFail("the standard cache was not vetted")
        }
        // Foundation's enumerator spells /var as /private/var. Nomination preserves the
        // submitted spelling; proposal approval deliberately matches the listed path exactly.
        XCTAssertEqual(vetted.url.resolvingSymlinksInPath().path, found.url.resolvingSymlinksInPath().path)
        XCTAssertEqual(vetted.byteCount, found.byteCount)
        XCTAssertEqual(vetted.workspacePath, found.workspacePath)
        XCTAssertEqual(vetted.url.path, url.path)
        let resolved = StorageCleanupGate.resolve(found.url.path, against: [found])
        XCTAssertEqual(resolved.matched, [found])
        XCTAssertTrue(StorageCleanupGate.resolve(root.path, against: [found]).matched.isEmpty)
    }

    func testRemovalRechecksActivityAgeAndWorkspaceIdentity() throws {
        let url = try tree("App")
        try age(url)
        let artifact = try XCTUnwrap(XcodeDerivedDataScanner.vet(url, root: root))
        XCTAssertTrue(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in false }))
        XCTAssertFalse(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in true }))

        try Data([2]).write(to: url.appendingPathComponent("Build/new-output"))
        XCTAssertFalse(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in false }))
        XCTAssertEqual(ArtifactScanner.removeWithOutcome(artifact, roots: [], derivedDataRoot: root), .refused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try writeManifest(url, workspace: "/different/App.xcodeproj")
        try age(url)
        XCTAssertFalse(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in false }))
        try FileManager.default.removeItem(at: url.appendingPathComponent("info.plist"))
        XCTAssertFalse(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in false }))
    }

    func testManifestAccessDateProtectsARecentlyUsedCache() throws {
        let url = try tree("App")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["WorkspacePath": "/missing/App.xcodeproj", "LastAccessedDate": Date()],
            format: .xml, options: 0
        )
        try data.write(to: url.appendingPathComponent("info.plist"))
        try age(url)
        let artifact = try XCTUnwrap(XcodeDerivedDataScanner.vet(url, root: root))
        XCTAssertTrue(artifact.isInUse())
        XCTAssertFalse(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in false }))
    }

    func testReplacingAListedDirectoryWithASymlinkRefusesRemoval() throws {
        let url = try tree("App")
        try age(url)
        let artifact = try XCTUnwrap(XcodeDerivedDataScanner.vet(url, root: root))
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: moved)
        XCTAssertFalse(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in false }))
        XCTAssertEqual(ArtifactScanner.removeWithOutcome(artifact, roots: [directory], derivedDataRoot: root), .refused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Build/payload").path))
    }

    func testRunningExecutableIsProtected() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        XCTAssertTrue(XcodeDerivedDataScanner.hasActiveProcess(in: executable.deletingLastPathComponent()))
    }

    func testBoundedScanAcrossManyStandardCaches() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_STORAGE_STRESS"] == "1")
        for index in 0..<1_000 { _ = try tree("App-\(index)", contents: "Logs") }
        let started = Date()
        let found = XcodeDerivedDataScanner.scan(root: root)
        print("Standard Xcode scan: \(found.count) caches in \(Date().timeIntervalSince(started)) seconds")
        XCTAssertEqual(found.count, 1_000)
        XCTAssertTrue(XcodeDerivedDataScanner.scan(root: root, maximumEntries: 2).isEmpty)
    }

    // MARK: - Xcode's naming rule

    /// The one vector Xcode itself produced: a real folder and the `WorkspacePath` in its
    /// manifest, read off the machine the rule was measured on.
    func testTheNameRuleReproducesXcodesOwnFolderName() {
        XCTAssertEqual(
            XcodeDerivedDataName.hash(forWorkspace: "/Users/david/repo/Strom/apple/Strom.xcworkspace"),
            "euwruxsrzfobriemxfltpdfuwceg"
        )
        XCTAssertEqual(
            XcodeDerivedDataName.hash(inFolderName: "Strom-euwruxsrzfobriemxfltpdfuwceg"),
            "euwruxsrzfobriemxfltpdfuwceg"
        )
        for name in ["Threading-StallVerification", "ModuleCache.noindex", "-euwruxsrzfobriemxfltpdfuwceg",
                     "App-EUWRUXSRZFOBRIEMXFLTPDFUWCEG", "App_euwruxsrzfobriemxfltpdfuwceg"] {
            XCTAssertNil(XcodeDerivedDataName.hash(inFolderName: name), name)
        }
    }

    /// A child Xcode named and filled but left without `info.plist` — 297 of 315 on the measuring
    /// machine. Its workspace is whichever candidate path hashes to its name, or nothing.
    private func remnant(for workspace: String, contents: [String] = ["Logs", "SourcePackages"]) throws -> URL {
        let url = root.appendingPathComponent("App-" + XcodeDerivedDataName.hash(forWorkspace: workspace))
        for name in contents {
            let output = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: output.appendingPathComponent("payload"))
        }
        return url
    }

    func testAManifestlessFolderIsOfferedByItsNameAndAttributedByItsHash() throws {
        let workspace = "/gone/App-feature/App.xcodeproj"
        let url = try remnant(for: workspace)

        let unattributed = try XCTUnwrap(XcodeDerivedDataScanner.scan(root: root).first)
        XCTAssertEqual(unattributed.url.lastPathComponent, url.lastPathComponent)
        XCTAssertNil(unattributed.workspacePath, "no candidate, so no claim about what it was built for")

        let candidates = XcodeWorkspaceCandidates(byHash: [XcodeDerivedDataName.hash(forWorkspace: workspace): workspace])
        let attributed = try XCTUnwrap(XcodeDerivedDataScanner.scan(root: root, candidates: candidates).first)
        XCTAssertEqual(attributed.workspacePath, workspace)
        XCTAssertGreaterThanOrEqual(attributed.byteCount, 8192)
    }

    /// The name is 28 letters anybody could type; the contents are what make it Xcode's.
    func testAManifestlessFolderHoldingAnythingElseIsRefused() throws {
        let foreign = try remnant(for: "/a/App.xcodeproj")
        try Data("mine".utf8).write(to: foreign.appendingPathComponent("notes.txt"))

        let unreadable = try remnant(for: "/b/App.xcodeproj")
        try writeManifest(unreadable, workspace: "relative/App.xcodeproj")

        let empty = root.appendingPathComponent("App-" + XcodeDerivedDataName.hash(forWorkspace: "/c/App.xcodeproj"))
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let linked = try remnant(for: "/d/App.xcodeproj", contents: ["Logs"])
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("SourcePackages"),
            withDestinationURL: directory
        )

        XCTAssertTrue(XcodeDerivedDataScanner.scan(root: root).isEmpty)
    }

    func testRemovingANameIdentifiedFolderRechecksItsIdentity() throws {
        let url = try remnant(for: "/gone/App.xcodeproj")
        try age(url)
        let artifact = try XCTUnwrap(XcodeDerivedDataScanner.vet(url, root: root))
        XCTAssertTrue(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in false }))
        XCTAssertFalse(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in true }))

        // Xcode building into it again writes a manifest: no longer the folder that was listed.
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Build"), withIntermediateDirectories: true)
        try writeManifest(url, workspace: "/gone/App.xcodeproj")
        try age(url)
        XCTAssertFalse(XcodeDerivedDataScanner.isSafeToRemove(artifact, root: root, hasActiveProcess: { _ in false }))
    }

    // MARK: - Candidates

    /// Candidates are every checkout on record joined to where the project keeps its Xcode
    /// project: here a nested `ios/App.xcodeproj`, a session's managed worktree, and a worktree
    /// git still records although its directory is gone.
    func testCandidatesJoinEveryRecordedCheckoutToTheProjectsXcodeProject() throws {
        let project = directory.appendingPathComponent("App")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("ios/App.xcodeproj"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("node_modules/dep/Vendored.xcodeproj"),
            withIntermediateDirectories: true
        )
        let record = project.appendingPathComponent(".git/worktrees/feature")
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
        try Data("/gone/App-feature/.git\n".utf8).write(to: record.appendingPathComponent("gitdir"))

        let candidates = XcodeWorkspaceCandidates.gather([
            .init(folder: project.path, checkouts: ["/gone/managed/App"])
        ])

        let expected = [
            project.path + "/ios/App.xcodeproj",
            "/gone/managed/App/ios/App.xcodeproj",
            "/gone/App-feature/ios/App.xcodeproj"
        ]
        XCTAssertEqual(Set(candidates.byHash.values), Set(expected))
        for path in expected {
            XCTAssertEqual(candidates.byHash[XcodeDerivedDataName.hash(forWorkspace: path)], path)
        }
    }
}
