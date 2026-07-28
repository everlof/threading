import XCTest
@testable import Skalman

/// The compare feature's data half: what a pair of files is decided to be, what the compare
/// controller makes of it, the review reader's endpoint blobs, the image rows, and the
/// `display_compare_files` tool's validation. The drawn surface is `ImageCompareRenderTests`.
final class CompareToolTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SkalmanCompare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Classification

    func testClassificationReadsBytesNotExtensions() throws {
        let text = try write("plain.bin", Data("just words\n".utf8))
        let png = try write("picture.txt", Self.pngData(width: 4, height: 4, color: .systemRed))
        let binary = try write("blob.png", Data([0x00, 0x01, 0x02, 0x03]))

        // The names lie on purpose: the bytes are what decide.
        XCTAssertEqual(CompareFileClassifier.classify(path: text.path), .text)
        XCTAssertEqual(CompareFileClassifier.classify(path: png.path), .image)
        XCTAssertEqual(CompareFileClassifier.classify(path: binary.path), .binary)
        XCTAssertEqual(
            CompareFileClassifier.classify(path: root.appendingPathComponent("gone").path),
            .missing
        )
    }

    // MARK: - The comparison itself

    func testIdenticalTextFilesSaySoInsteadOfShowingAnEmptyDiff() throws {
        let first = try write("a.txt", Data("same\ncontent\n".utf8))
        let second = try write("b.txt", Data("same\ncontent\n".utf8))

        guard case .message(let message) = CompareViewController.compare(
            oldPath: first.path, newPath: second.path
        ) else {
            return XCTFail("Identical files should produce a message")
        }
        XCTAssertEqual(message, "The files are identical.")
    }

    func testDifferingTextFilesProduceHunks() throws {
        let first = try write("a.txt", Data("one\ntwo\nthree\n".utf8))
        let second = try write("b.txt", Data("one\nTWO\nthree\n".utf8))

        guard case .text(let files) = CompareViewController.compare(
            oldPath: first.path, newPath: second.path
        ) else {
            return XCTFail("Differing text should produce a parsed diff")
        }
        let lines = files.flatMap(\.hunks).flatMap(\.lines)
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.text == "two" })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text == "TWO" })
    }

    func testAnImagePairComesBackAsImages() throws {
        let old = try write("old.png", Self.pngData(width: 6, height: 4, color: .systemRed))
        let new = try write("new.png", Self.pngData(width: 6, height: 4, color: .systemBlue))

        guard case .images(let oldImage, let newImage) = CompareViewController.compare(
            oldPath: old.path, newPath: new.path
        ) else {
            return XCTFail("Two PNGs should produce images")
        }
        XCTAssertNotNil(oldImage)
        XCTAssertNotNil(newImage)
    }

    func testAMixedPairIsRefusedInProse() throws {
        let image = try write("a.png", Self.pngData(width: 4, height: 4, color: .systemRed))
        let text = try write("b.txt", Data("words\n".utf8))

        guard case .message(let message) = CompareViewController.compare(
            oldPath: image.path, newPath: text.path
        ) else {
            return XCTFail("A mixed pair should produce a message")
        }
        XCTAssertTrue(message.contains("no comparison"), message)
    }

    // MARK: - Review endpoints

    func testEndpointPairReadsTheCommittedOldAndTheWorktreeNew() throws {
        try makeRepository()
        let committed = Self.pngData(width: 4, height: 4, color: .systemRed)
        try write("icon.png", committed)
        try git("add", ".")
        try git("commit", "-m", "add icon", "--quiet")

        let reworked = Self.pngData(width: 8, height: 8, color: .systemBlue)
        try write("icon.png", reworked)

        let pair = try fetchPair(path: "icon.png", request: .uncommitted)
        XCTAssertEqual(pair.old, committed)
        XCTAssertEqual(pair.new, reworked)
        XCTAssertEqual(pair.oldTitle, "HEAD")
        XCTAssertEqual(pair.newTitle, "Working Tree")
    }

    func testAnUntrackedImageHasNoOldSide() throws {
        try makeRepository()
        try write("seed.txt", Data("seed\n".utf8))
        try git("add", ".")
        try git("commit", "-m", "seed", "--quiet")

        let added = Self.pngData(width: 4, height: 4, color: .systemGreen)
        try write("fresh.png", added)

        let pair = try fetchPair(path: "fresh.png", request: .uncommitted)
        XCTAssertNil(pair.old, "an untracked file has nothing at HEAD")
        XCTAssertEqual(pair.new, added)
    }

    func testAPathOutsideTheCheckoutIsRefused() throws {
        try makeRepository()
        try write("seed.txt", Data("seed\n".utf8))
        try git("add", ".")
        try git("commit", "-m", "seed", "--quiet")

        let pair = try fetchPair(path: "../escape.png", request: .uncommitted)
        XCTAssertNil(pair.old)
        XCTAssertNil(pair.new, "a path resolving outside the root must not be read")
    }

    // MARK: - Image rows

    @MainActor
    func testABinaryImageRowOpensIntoTheCompareSurface() {
        let file = GitFileDiff(
            path: "Assets/icon.png", change: .binary, hunks: [], added: 0, removed: 0
        )
        let row = GitReviewFileRow(file: file, expanded: false)
        XCTAssertTrue(row.canOpen, "an image row must be expandable")

        var asked = false
        row.imagePairProvider = { _, completion in
            asked = true
            completion(.success(GitEndpointFilePair(
                old: Self.pngData(width: 4, height: 4, color: .systemRed),
                new: Self.pngData(width: 4, height: 4, color: .systemBlue),
                oldTitle: "HEAD",
                newTitle: "Working Tree"
            )))
        }
        row.setExpanded(true)

        XCTAssertTrue(asked, "expanding must fetch the pair")
        XCTAssertNotNil(
            firstCompareView(in: row),
            "the body should hold the compare surface once the pair arrives"
        )
    }

    /// A row restored as expanded builds its body during `init`, before the pane wires the
    /// provider — the wiring must kick the fetch that was waiting on it.
    @MainActor
    func testARowRestoredExpandedFetchesOnceItsProviderArrives() {
        let file = GitFileDiff(
            path: "shot.png", change: .binary, hunks: [], added: 0, removed: 0
        )
        let row = GitReviewFileRow(file: file, expanded: true)
        XCTAssertNil(firstCompareView(in: row))

        row.imagePairProvider = { _, completion in
            completion(.success(GitEndpointFilePair(
                old: nil,
                new: Self.pngData(width: 4, height: 4, color: .systemBlue),
                oldTitle: "HEAD",
                newTitle: "Working Tree"
            )))
        }
        XCTAssertNotNil(firstCompareView(in: row))
    }

    @MainActor
    func testANonImageBinaryRowStaysClosed() {
        let file = GitFileDiff(
            path: "model.bin", change: .binary, hunks: [], added: 0, removed: 0
        )
        let row = GitReviewFileRow(file: file, expanded: false)
        XCTAssertFalse(row.canOpen)
    }

    // MARK: - Persistence

    func testACompareTabSignsWithItsPair() {
        let panel = PersistedPanel(
            tabs: [PersistedTab(
                id: UUID().uuidString, kind: .compare, title: "Compare",
                subtitle: "", url: nil, html: nil, cacheFile: nil,
                mode: ImageCompareMode.fade.rawValue,
                compareOldPath: "/tmp/a.png", compareNewPath: "/tmp/b.png"
            )],
            activeTabID: nil,
            observedSignature: nil
        )
        XCTAssertTrue(panel.signature.hasPrefix("c:/tmp/a.png→/tmp/b.png"), panel.signature)
        XCTAssertTrue(panel.agentDescription.contains("file comparison of a.png against b.png"))
    }

    // MARK: - The MCP tool

    @MainActor
    func testTheToolValidatesItsPairBeforeSpendingATab() throws {
        let pane = DisplayPaneController()
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
        let sessionID = SessionID()
        defer {
            for tab in pane.tabs(for: sessionID) {
                _ = pane.closeTab(id: tab.id, for: sessionID)
            }
        }

        let missing = coordinator.handle(
            .displayCompareFiles(.init(oldPath: nil, newPath: "/tmp/b.png")), for: sessionID
        )
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("old_path"), missing.text)

        let image = try write("a.png", Self.pngData(width: 4, height: 4, color: .systemRed))
        let same = coordinator.handle(
            .displayCompareFiles(.init(oldPath: image.path, newPath: image.path)), for: sessionID
        )
        XCTAssertTrue(same.isError)
        XCTAssertTrue(same.text.contains("same file"), same.text)

        let text = try write("b.txt", Data("words\n".utf8))
        let mixed = coordinator.handle(
            .displayCompareFiles(.init(oldPath: image.path, newPath: text.path)), for: sessionID
        )
        XCTAssertTrue(mixed.isError)
        XCTAssertTrue(mixed.text.contains("no comparison"), mixed.text)
        XCTAssertTrue(pane.tabs(for: sessionID).isEmpty, "a refused pair must not open a tab")
    }

    @MainActor
    func testTheToolOpensOneTabPerPairAndReusesIt() throws {
        let pane = DisplayPaneController()
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
        let sessionID = SessionID()
        defer {
            for tab in pane.tabs(for: sessionID) {
                _ = pane.closeTab(id: tab.id, for: sessionID)
            }
        }

        let old = try write("old.png", Self.pngData(width: 4, height: 4, color: .systemRed))
        let new = try write("new.png", Self.pngData(width: 4, height: 4, color: .systemBlue))

        let first = coordinator.handle(
            .displayCompareFiles(.init(
                oldPath: old.path, newPath: new.path, oldTitle: "Baseline"
            )),
            for: sessionID
        )
        XCTAssertFalse(first.isError, first.text)
        XCTAssertTrue(first.text.contains("interactive image comparison"), first.text)

        let tabs = pane.tabs(for: sessionID)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.title, "Compare")
        XCTAssertEqual(tabs.first?.compare?.oldTitle, "Baseline")

        // The same pair asked again lands in the same tab rather than a second one.
        let again = coordinator.handle(
            .displayCompareFiles(.init(oldPath: old.path, newPath: new.path)), for: sessionID
        )
        XCTAssertFalse(again.isError, again.text)
        XCTAssertEqual(pane.tabs(for: sessionID).count, 1)
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeRepository() throws {
        try git("init", "--quiet")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> Data {
        try GitProcess.run(Array(arguments), in: root)
    }

    private func fetchPair(
        path: String, request: GitReviewReader.DiffRequest
    ) throws -> GitEndpointFilePair {
        let done = expectation(description: "endpoint pair")
        var outcome: Result<GitEndpointFilePair, GitFailure>?
        DispatchQueue.main.async { [root] in
            GitReviewReader.endpointFilePair(path: path, request: request, in: root!) { result in
                outcome = result
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
        switch outcome {
        case .success(let pair): return pair
        case .failure(let failure): throw failure
        case nil: throw GitFailure.gitFailed("No result arrived.")
        }
    }

    @MainActor
    private func firstCompareView(in view: NSView) -> ImageCompareView? {
        if let compare = view as? ImageCompareView { return compare }
        for subview in view.subviews {
            if let found = firstCompareView(in: subview) { return found }
        }
        return nil
    }

    private static func pngData(width: Int, height: Int, color: NSColor) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let converted = color.usingColorSpace(.deviceRGB)!
        for x in 0..<width {
            for y in 0..<height {
                rep.setColor(converted, atX: x, y: y)
            }
        }
        return rep.representation(using: .png, properties: [:])!
    }
}
