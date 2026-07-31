import AppKit
import XCTest
@testable import Threading

/// The attachments pane leads with its content instead of stretching across the pane.
///
/// The bug these pin down: the preview was the layout's one flexible element between a
/// top-pinned list and a *bottom-pinned* footer, so a tall display panel stretched it to
/// hundreds of points around a small picture and put the file's name and buttons at the
/// window's floor, a screen below the list they describe. The footer's floor is now a limit
/// (`lessThanOrEqualTo`), an image states the preview's height (`previewHeightConstraint`),
/// and only a PDF — which reads better the taller it is — still fills the room the pane has.
@MainActor
final class SessionAttachmentsLayoutTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A laid-out pane holding exactly one recorded attachment. The shared store is in-memory
    /// under XCTest by construction — see `SessionAttachmentStore.shared`.
    private func laidOutPane(showing url: URL, size: NSSize) throws -> SessionAttachmentsViewController {
        let sessionID = SessionID()
        let recorded = SessionAttachmentStore.shared.record(
            urls: [url], sessionID: sessionID, projectRoot: root
        )
        XCTAssertEqual(recorded.count, 1, "the fixture attachment was refused")

        let controller = SessionAttachmentsViewController(sessionID: sessionID)
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.autoresizingMask = []
        // Twice, deliberately: the first pass gives the preview its width, `viewDidLayout`
        // re-aims the height constraint at the image's fitted height for it, and the second
        // pass places the chain against that answer — the fixpoint a window's display cycle
        // reaches on its own before anything is drawn.
        controller.view.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func writePNG(size: NSSize) throws -> URL {
        let url = root.appendingPathComponent("picture.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func writePDF() throws -> URL {
        let url = root.appendingPathComponent("document.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func button(titled title: String, in view: NSView) throws -> NSView {
        try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == title },
            "the pane grew no \(title) button"
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    // MARK: - Tests

    /// A small picture on a tall pane: the footer follows the content, and the slack falls
    /// *below* the buttons, empty — not into the preview.
    func testATallPaneHugsItsContentRatherThanStretchingThePreview() throws {
        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 400, height: 400)),
            size: NSSize(width: 353, height: 900)
        )
        let open = try button(titled: L10n.string("Open"), in: pane.view)
        let frame = pane.view.convert(open.bounds, from: open)

        XCTAssertGreaterThan(
            frame.minY,
            200,
            "the footer sits at the pane's floor, so the preview is absorbing the slack again"
        )
    }

    /// The same pane, shorter than the picture: the limit still holds — the preview compresses
    /// and the buttons stay reachable inside the pane.
    func testAShortPaneCompressesThePreviewRatherThanTheFooter() throws {
        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 400, height: 400)),
            size: NSSize(width: 353, height: 420)
        )
        let open = try button(titled: L10n.string("Open"), in: pane.view)
        let frame = pane.view.convert(open.bounds, from: open)

        XCTAssertGreaterThanOrEqual(
            frame.minY,
            Design.Spacing.small - 0.5,
            "the footer was pushed out of the pane"
        )
        XCTAssertLessThanOrEqual(
            frame.minY,
            Design.Spacing.small + 1,
            "a short pane left slack under the footer instead of giving it to the preview"
        )
    }

    /// A PDF is the case that *should* fill the pane: a document reads better the taller it is,
    /// so the footer returns to the floor and the preview takes the room.
    func testAPDFStillFillsTheRoomThePaneHas() throws {
        let pane = try laidOutPane(
            showing: try writePDF(),
            size: NSSize(width: 353, height: 900)
        )
        let open = try button(titled: L10n.string("Open"), in: pane.view)
        let frame = pane.view.convert(open.bounds, from: open)

        XCTAssertEqual(
            frame.minY,
            Design.Spacing.small,
            accuracy: 1,
            "a document's preview no longer fills the pane"
        )
    }
}
