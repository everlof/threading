import XCTest
import AppKit
@testable import Skalman

final class PromptAttachmentTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private var written: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("skalman-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        pasteboard = nil

        for path in written {
            try? FileManager.default.removeItem(atPath: path)
        }
        written = []

        try super.tearDownWithError()
    }

    /// A dropped file already has a home, so it is named where it lies rather than copied.
    func testFileURLsBecomeTheirOwnPaths() {
        let first = URL(fileURLWithPath: "/tmp/one.png")
        let second = URL(fileURLWithPath: "/tmp/two.txt")
        pasteboard.writeObjects([first as NSURL, second as NSURL])

        XCTAssertEqual(PromptAttachment.paths(from: pasteboard), [first.path, second.path])
    }

    /// A screenshot on the pasteboard has no path of its own, so one is made for it — this
    /// is what makes dropping an image into the composer mean anything to a CLI.
    func testImageDataIsWrittenOutAndNamed() throws {
        pasteboard.setData(try pngData(), forType: .png)

        let paths = PromptAttachment.paths(from: pasteboard)
        written = paths

        let path = try XCTUnwrap(paths.first)
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "png")
        XCTAssertNotNil(NSImage(contentsOfFile: path))
    }

    /// Dragged images often arrive as TIFF. They land as PNG, so the extension on disk is
    /// never a lie about the bytes under it.
    func testTIFFIsReencodedAsPNG() throws {
        pasteboard.setData(try tiffData(), forType: .tiff)

        let paths = PromptAttachment.paths(from: pasteboard)
        written = paths

        let path = try XCTUnwrap(paths.first)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "png")

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    /// Text is left to the text view: pasting a string must stay a paste, not become a file.
    func testPlainTextIsNotTreatedAsAnAttachment() {
        pasteboard.setString("just some words", forType: .string)
        XCTAssertTrue(PromptAttachment.paths(from: pasteboard).isEmpty)
    }

    // MARK: - Helpers

    private func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 2, height: 2))
        image.unlockFocus()
        return image
    }

    private func tiffData() throws -> Data {
        try XCTUnwrap(image().tiffRepresentation)
    }

    private func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try tiffData()))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
