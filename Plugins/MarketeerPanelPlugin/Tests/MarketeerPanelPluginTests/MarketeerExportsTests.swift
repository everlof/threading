import AppKit
import Foundation
import XCTest
@testable import MarketeerPanelPlugin

/// Matching a slide to the picture a render produced for it. The convention is the Marketeer
/// CLI's — `Screenshot_01_6.9in.png`, slot one-based — and it is not ours to change, so it is
/// pinned here rather than assumed.
final class MarketeerExportsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marketeer-exports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The naming convention

    func testTheSlotIsReadFromTheCLIsOwnFileName() {
        XCTAssertEqual(MarketeerExports.slot(inFileNamed: "Screenshot_01_6.9in.png"), 1)
        XCTAssertEqual(MarketeerExports.slot(inFileNamed: "Screenshot_10_6.5in.png"), 10)
    }

    func testAnythingElseIsNotOneOfOurs() {
        for name in [
            "notes.txt",
            "Screenshot.png",
            "Thumbs_01_6.9in.png",
            "Screenshot_ab_6.9in.png",
            "Screenshot_01_6.9in.json",
        ] {
            XCTAssertNil(MarketeerExports.slot(inFileNamed: name), name)
        }
    }

    /// The CLI counts slots from one because that is what the App Store calls them; a slide counts
    /// its `slotPosition` from zero. Getting this off by one shows the wrong picture against the
    /// wrong caption, which is worse than showing none.
    func testTheIndexIsKeyedBySlidePositionNotBySlotNumber() throws {
        try writeExport(named: "Screenshot_01_6.9in.png", projectID: "p1")
        try writeExport(named: "Screenshot_03_6.9in.png", projectID: "p1")

        let index = MarketeerExports.index(forProjectID: "p1", root: root)
        XCTAssertEqual(Set(index.keys), [0, 2])
    }

    /// A render asked for locales writes into locale subfolders, so the pictures are one level
    /// down and a scan that only looked at the top level would find none.
    func testPicturesInLocaleSubfoldersAreFound() throws {
        try writeExport(named: "Screenshot_01_6.9in.png", projectID: "p2", subdirectory: "en-US")
        try writeExport(named: "Screenshot_02_6.9in.png", projectID: "p2", subdirectory: "sv")

        let index = MarketeerExports.index(forProjectID: "p2", root: root)
        XCTAssertEqual(Set(index.keys), [0, 1])
    }

    /// One slot rendered for several locales is several files and one row, so the choice has to be
    /// stable between reads rather than whatever the filesystem returns first.
    func testOneSlotWithSeveralLocalesResolvesToTheSameFileEveryTime() throws {
        try writeExport(named: "Screenshot_01_6.9in.png", projectID: "p3", subdirectory: "sv")
        try writeExport(named: "Screenshot_01_6.9in.png", projectID: "p3", subdirectory: "en-US")

        let first = MarketeerExports.index(forProjectID: "p3", root: root)[0]
        let again = MarketeerExports.index(forProjectID: "p3", root: root)[0]
        XCTAssertNotNil(first)
        XCTAssertEqual(first, again)
        XCTAssertEqual(first?.pathComponents.dropLast().last, "en-US", "sorted by path, so en-US wins")
    }

    /// Depth is bounded, so a deep tree — or a symlink into one — cannot turn a cheap lookup into
    /// a filesystem walk.
    func testPicturesBuriedDeeperThanTheCapAreNotFound() throws {
        try writeExport(named: "Screenshot_01_6.9in.png", projectID: "p4", subdirectory: "a/b/c")
        XCTAssertTrue(MarketeerExports.index(forProjectID: "p4", root: root).isEmpty)
    }

    func testAProjectThatWasNeverRenderedHasNoExportsAndNoError() {
        XCTAssertTrue(MarketeerExports.index(forProjectID: "never", root: root).isEmpty)
    }

    // MARK: - Decoding

    /// The pane draws these at 110 points. Decoding a 1290×2796 screenshot at full size for that
    /// is hundreds of megabytes across a folder of them, so the decode is downsampled by ImageIO
    /// rather than trimmed afterwards.
    func testTheThumbnailIsDownsampledDuringTheDecode() throws {
        let url = try writeExport(named: "Screenshot_01_6.9in.png", projectID: "p5", pixels: 1200)
        let image = try XCTUnwrap(MarketeerExports.thumbnail(at: url, maximumPixelSize: 64))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 64)
        XCTAssertGreaterThan(image.width, 0)
    }

    func testSomethingThatIsNotAnImageDecodesToNothingRatherThanThrowing() throws {
        let directory = MarketeerExports.directory(forProjectID: "p6", root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Screenshot_01_6.9in.png")
        try Data("not a png".utf8).write(to: url)
        XCTAssertNil(MarketeerExports.thumbnail(at: url))
    }

    // MARK: - Fixture

    @discardableResult
    private func writeExport(
        named name: String,
        projectID: String,
        subdirectory: String? = nil,
        pixels: Int = 40
    ) throws -> URL {
        var directory = MarketeerExports.directory(forProjectID: projectID, root: root)
        if let subdirectory { directory = directory.appendingPathComponent(subdirectory, isDirectory: true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(name)
        let size = NSSize(width: pixels, height: pixels * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(to: url)
        return url
    }
}
