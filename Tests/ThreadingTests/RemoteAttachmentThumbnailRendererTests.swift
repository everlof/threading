import AppKit
import PDFKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// The ledger raster is bounded on its own account: whatever the attachment holds, the answer
/// is at most `RemoteAttachmentThumbnail.maximumPixelDimension` on a side, a PDF is its first
/// page at the same bound, and a kind with no raster answers nothing rather than a guess.
final class RemoteAttachmentThumbnailRendererTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "thumbnail-renderer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testALargeImageComesBackNoWiderThanTheBound() throws {
        let url = directory.appendingPathComponent("wide.png")
        try png(width: 1_600, height: 400).write(to: url)

        let frame = try XCTUnwrap(RemoteAttachmentThumbnailRenderer.thumbnailFrame(at: url))

        XCTAssertLessThanOrEqual(frame.width, RemoteAttachmentThumbnail.maximumPixelDimension)
        XCTAssertLessThanOrEqual(frame.height, RemoteAttachmentThumbnail.maximumPixelDimension)
        XCTAssertEqual(
            Double(frame.width) / Double(frame.height),
            4,
            accuracy: 0.1,
            "the bound scales, it does not crop"
        )
    }

    func testTheAnswerIsAJPEGTheLedgerCanDecode() throws {
        let url = directory.appendingPathComponent("small.png")
        try png(width: 40, height: 40).write(to: url)

        let data = try XCTUnwrap(RemoteAttachmentThumbnailRenderer.jpeg(at: url))

        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "JPEG start-of-image marker")
        XCTAssertNotNil(NSImage(data: data))
    }

    func testAPDFIsThumbnailedByItsFirstPage() throws {
        let url = directory.appendingPathComponent("pages.pdf")
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: NSImage(
            data: png(width: 600, height: 800)
        ) ?? NSImage()))
        document.insert(page, at: 0)
        try XCTUnwrap(document.dataRepresentation()).write(to: url)

        let frame = try XCTUnwrap(RemoteAttachmentThumbnailRenderer.thumbnailFrame(at: url))

        XCTAssertLessThanOrEqual(frame.width, RemoteAttachmentThumbnail.maximumPixelDimension)
        XCTAssertLessThanOrEqual(frame.height, RemoteAttachmentThumbnail.maximumPixelDimension)
        XCTAssertGreaterThan(frame.height, frame.width, "a portrait page stays portrait")
    }

    func testAKindWithNoRasterAnswersNothing() throws {
        let url = directory.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: url)

        XCTAssertNil(RemoteAttachmentThumbnailRenderer.jpeg(at: url))
    }

    func testAMoviePosterIsAJPEGInsideTheLedgerBound() async throws {
        let url = directory.appendingPathComponent("recording.mov")
        try MovieFixture.write(to: url)

        let rendered = await RemoteAttachmentThumbnailRenderer.jpeg(
            at: url,
            kind: .video
        )
        let data = try XCTUnwrap(rendered)
        let image = try XCTUnwrap(NSImage(data: data))
        let representation = try XCTUnwrap(image.representations.first)

        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "JPEG start-of-image marker")
        XCTAssertLessThanOrEqual(
            max(representation.pixelsWide, representation.pixelsHigh),
            RemoteAttachmentThumbnail.maximumPixelDimension
        )
    }

    private func png(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
