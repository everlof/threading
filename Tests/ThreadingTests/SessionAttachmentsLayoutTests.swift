import AppKit
import XCTest
@testable import Threading

/// The attachments pane leads with its content instead of stretching across the pane, and its
/// rows read as a visual history.
///
/// The bug these pin down: the preview was the layout's one flexible element between a
/// top-pinned list and a *bottom-pinned* footer, so a tall display panel stretched it to
/// hundreds of points around a small picture and put the file's name and buttons at the
/// window's floor, a screen below the list they describe. The footer's floor is now a limit
/// (`lessThanOrEqualTo`), an image states the preview's height (`previewHeightConstraint`),
/// and only a PDF — which reads better the taller it is — still fills the room the pane has.
///
/// The rows are here for the same reason the list grew: this is where the panel's per-image
/// tabs went, so a row has to carry the picture and the moment a tab used to.
@MainActor
final class SessionAttachmentsLayoutTests: XCTestCase {

    private var root: URL!
    private var outside: URL?

    /// The scope is a real behavioural setting on `.standard`, which under a hosted test bundle
    /// is the developer's own — so it is put back exactly as it was found.
    private var scopeBeforeTest = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scopeBeforeTest = AppSettings.shared.includesAttachmentsOutsideProject
    }

    override func tearDownWithError() throws {
        AppSettings.shared.includesAttachmentsOutsideProject = scopeBeforeTest
        if let root { try? FileManager.default.removeItem(at: root) }
        if let outside { try? FileManager.default.removeItem(at: outside) }
        outside = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A laid-out pane holding exactly one recorded attachment. The shared store is in-memory
    /// under XCTest by construction — see `SessionAttachmentStore.shared`.
    private func laidOutPane(showing url: URL, size: NSSize) throws -> SessionAttachmentsViewController {
        try laidOutPane(showing: [url], size: size)
    }

    /// The same fixture for a list with several rows in it — what the pane is for, and what a
    /// three-row letterbox could not show.
    private func laidOutPane(showing urls: [URL], size: NSSize) throws -> SessionAttachmentsViewController {
        let sessionID = SessionID()
        let recorded = SessionAttachmentStore.shared.record(
            urls: urls, sessionID: sessionID, projectRoot: root
        )
        XCTAssertEqual(recorded.count, urls.count, "a fixture attachment was refused")

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
        try writePNG(named: "picture.png", size: size)
    }

    /// A picture with a colour in it, for the assertions that read the row's own pixels rather
    /// than its geometry. Drawn through a graphics context rather than `setColor(atX:y:)`, which
    /// leaves this bitmap transparent (and logs a colorspace complaint per pixel while doing it).
    private func writePNG(named name: String, size: NSSize, color: NSColor) throws -> URL {
        let url = root.appendingPathComponent(name)
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
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// `count` distinct pictures, all the same shape, so which row the pane selects first cannot
    /// change what the preview is asked to hold.
    private func writePNGs(count: Int, size: NSSize) throws -> [URL] {
        try (0..<count).map { try writePNG(named: "picture-\($0).png", size: size) }
    }

    private func writePNG(named name: String, size: NSSize) throws -> URL {
        let url = root.appendingPathComponent(name)
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

    private func scopeBand(in view: NSView) throws -> PaneFooterView {
        try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? PaneFooterView }.first,
            "the pane grew no scope band"
        )
    }

    private func attachmentsTable(in view: NSView) throws -> ThemedTableView {
        try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? ThemedTableView }.first,
            "the pane grew no list"
        )
    }

    /// The list's viewport, reached through its table so a preview's own internal scrolling
    /// cannot be mistaken for it.
    private func list(in view: NSView) throws -> NSScrollView {
        try XCTUnwrap(attachmentsTable(in: view).enclosingScrollView, "the list is not scrollable")
    }

    /// How much of the last row is inside the viewport — the question "can this list be read
    /// without scrolling it" asked of the table itself, so no assertion here has to restate the
    /// table's own padding.
    private func lastRowOverflow(in view: NSView) throws -> CGFloat {
        let table = try attachmentsTable(in: view)
        let list = try list(in: view)
        return table.rect(ofRow: table.numberOfRows - 1).maxY - list.contentView.bounds.height
    }

    /// A pane for a session that has named `outside` — a real file the scan finds and the
    /// narrow scope refuses — plus one picture of its own so the list is not empty for an
    /// unrelated reason.
    private func laidOutPaneNaming(
        _ outside: URL,
        size: NSSize
    ) throws -> SessionAttachmentsViewController {
        let sessionID = SessionID()
        let inside = try writePNG(size: NSSize(width: 40, height: 40))
        SessionAttachmentStore.shared.recordReferences(
            in: "made `\(inside.lastPathComponent)`, then wrote \(outside.path)",
            sessionID: sessionID,
            projectRoot: root
        )

        let controller = SessionAttachmentsViewController(sessionID: sessionID)
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.autoresizingMask = []
        controller.view.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    /// Somewhere the project is not, with a real picture in it.
    private func writeOutsideProjectPNG() throws -> URL {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments-elsewhere-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        outside = elsewhere
        let picture = try writePNG(size: NSSize(width: 40, height: 40))
        let destination = elsewhere.appendingPathComponent("outside.png")
        try FileManager.default.moveItem(at: picture, to: destination)
        return destination
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
            Design.Spacing.inset - 0.5,
            "the footer was pushed out of the pane"
        )
        XCTAssertLessThanOrEqual(
            frame.minY,
            Design.Spacing.inset + 1,
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
            Design.Spacing.inset,
            accuracy: 1,
            "a document's preview no longer fills the pane"
        )
    }

    // MARK: - The List's Height

    /// One attachment is a one-row list, not the three-row letterbox it used to be whatever the
    /// session had exchanged.
    func testTheListIsAsTallAsTheOneRowItHolds() throws {
        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 400, height: 400)),
            size: NSSize(width: 353, height: 900)
        )
        let table = try attachmentsTable(in: pane.view)
        let list = try list(in: pane.view)

        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertGreaterThanOrEqual(
            list.frame.height,
            SessionAttachmentsDefaults.rowHeight,
            "the one row it holds does not fit in the list"
        )
        XCTAssertLessThan(
            list.frame.height,
            SessionAttachmentsDefaults.rowHeight * 2,
            "a one-row list is still being given the room for three"
        )
        XCTAssertLessThanOrEqual(
            try lastRowOverflow(in: pane.view),
            0,
            "a list with one row in it has something to scroll"
        )
    }

    /// Eight attachments in a pane with the room for them are eight visible rows, and nothing
    /// to scroll.
    func testATallPaneShowsEveryRowRatherThanThreeOfThem() throws {
        let pane = try laidOutPane(
            showing: try writePNGs(count: 8, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 900)
        )
        let table = try attachmentsTable(in: pane.view)
        let list = try list(in: pane.view)

        XCTAssertEqual(table.numberOfRows, 8)
        XCTAssertGreaterThanOrEqual(
            list.frame.height,
            SessionAttachmentsDefaults.rowHeight * 8,
            "eight rows are still being read through a three-row letterbox"
        )
        XCTAssertLessThanOrEqual(
            try lastRowOverflow(in: pane.view),
            0,
            "a list showing everything it has was still given something to scroll"
        )
    }

    /// The same eight in a pane that cannot hold them: the list stops at its share and the rest
    /// is scrolled to, rather than taking the room the preview and the footer need.
    func testAShortPaneCapsTheListAtItsShareAndScrollsTheRest() throws {
        let height: CGFloat = 420
        let pane = try laidOutPane(
            showing: try writePNGs(count: 8, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: height)
        )
        let list = try list(in: pane.view)

        XCTAssertEqual(
            list.frame.height,
            height * SessionAttachmentsDefaults.listShareOfPane,
            accuracy: 1,
            "the list took more than its share of a short pane"
        )
        XCTAssertGreaterThan(
            try lastRowOverflow(in: pane.view),
            0,
            "the rows the cap left out cannot be scrolled to"
        )
    }

    /// The cap is a fraction of the pane, so it has to be re-asked when the pane changes — the
    /// same reason the preview's fitted height is re-asked from `viewDidLayout`.
    func testResizingThePaneReAnswersTheCap() throws {
        let pane = try laidOutPane(
            showing: try writePNGs(count: 8, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 420)
        )
        let list = try list(in: pane.view)
        let capped = list.frame.height
        XCTAssertGreaterThan(try lastRowOverflow(in: pane.view), 0, "the fixture was never capped")

        pane.view.frame = NSRect(x: 0, y: 0, width: 353, height: 900)
        pane.view.needsLayout = true
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(list.frame.height, capped, "the cap was answered once and kept")
        XCTAssertLessThanOrEqual(
            try lastRowOverflow(in: pane.view),
            0,
            "a pane with the room for every row is still showing half of them"
        )
    }

    /// The regression the flexible list could have caused: rows *and* a picture taller than the
    /// pane, in a pane too short for either. The preview is what gives way — the list is capped
    /// at half the pane and the footer's floor is `required`, so neither can be what yields.
    func testRowsAndATallImageInAShortPaneStillCompressThePreview() throws {
        let height: CGFloat = 420
        let pane = try laidOutPane(
            showing: try writePNGs(count: 8, size: NSSize(width: 400, height: 400)),
            size: NSSize(width: 353, height: height)
        )
        let open = try button(titled: L10n.string("Open"), in: pane.view)
        let frame = pane.view.convert(open.bounds, from: open)
        let list = try list(in: pane.view)

        XCTAssertGreaterThanOrEqual(
            frame.minY,
            Design.Spacing.inset - 0.5,
            "the rows pushed the footer out of the pane"
        )
        XCTAssertLessThanOrEqual(
            frame.minY,
            Design.Spacing.inset + 1,
            "a short pane left slack under the footer instead of giving it to the preview"
        )
        XCTAssertEqual(
            list.frame.height,
            height * SessionAttachmentsDefaults.listShareOfPane,
            accuracy: 1,
            "the list gave up its share to the preview rather than the other way round"
        )
    }

    // MARK: - The Window's Size Is Not The Pane's To Decide

    /// The pane hosted where it ships: in a window whose height Auto Layout may change. AppKit
    /// reads a window's minimum size out of every constraint at `windowSizeStayPut` (500) and
    /// above, so a content-derived height above that is not a preference inside the pane — it
    /// is the pane resizing the window. The preview's fitted height carried `.defaultHigh`,
    /// and a full-page screenshot grew the main window to 3386 points on a 1084-point screen
    /// every time the session holding it was opened. None of the fixtures above could see it:
    /// a detached fixture's own frame is `required`, while a window's size merely stays put
    /// at 500 — the same lesson as the sidebar row asserted outside its outline view.
    func testATallScreenshotCannotGrowTheWindowHoldingThePane() throws {
        let sessionID = SessionID()
        let recorded = SessionAttachmentStore.shared.record(
            urls: [try writePNG(size: NSSize(width: 400, height: 4000))],
            sessionID: sessionID,
            projectRoot: root
        )
        XCTAssertEqual(recorded.count, 1, "a fixture attachment was refused")

        // Built, never shown — an unshown window still lays out, which is all this needs.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 353, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = SessionAttachmentsViewController(sessionID: sessionID)
        window.setContentSize(NSSize(width: 353, height: 700))
        // Twice for the same fixpoint the detached fixtures reach: the first pass gives the
        // preview its width, the second lays the chain out against its fitted height.
        window.layoutIfNeeded()
        window.layoutIfNeeded()

        XCTAssertEqual(
            window.contentRect(forFrameRect: window.frame).height,
            700,
            accuracy: 1,
            "the preview's height reached the window — a constraint above windowSizeStayPut is loose in the pane"
        )
    }

    // MARK: - The Scope Band

    /// Quiet where it would say nothing. A session whose files are all inside its project is
    /// never asked about files outside it — the setting is a safety rule, and one advertised
    /// where it costs nothing teaches people to turn it off before they have ever needed it.
    func testThePaneSaysNothingAboutTheScopeWhenItWouldChangeNothing() throws {
        AppSettings.shared.includesAttachmentsOutsideProject = false
        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 400, height: 400)),
            size: NSSize(width: 353, height: 900)
        )

        XCTAssertTrue(try scopeBand(in: pane.view).isHidden)
    }

    /// And present the moment it would: the count is what the rule is costing *this* session.
    func testThePaneOffersTheScopeOnlyWhenThisSessionHasFilesOutsideItsProject() throws {
        AppSettings.shared.includesAttachmentsOutsideProject = false
        let pane = try laidOutPaneNaming(
            try writeOutsideProjectPNG(),
            size: NSSize(width: 353, height: 900)
        )

        let band = try scopeBand(in: pane.view)
        XCTAssertFalse(band.isHidden, "the pane refused a file and then said nothing about it")
        _ = try button(titled: L10n.string("Show"), in: band)

        // The band is the pane's floor while it is there, so the actions stop above it rather
        // than sliding underneath the one control that explains them.
        let open = try button(titled: L10n.string("Open"), in: pane.view)
        let actions = pane.view.convert(open.bounds, from: open)
        XCTAssertGreaterThanOrEqual(
            actions.minY,
            band.frame.maxY,
            "the pane's actions were laid out over the scope band"
        )
    }

    /// Pressing it answers, in the pane, with the file itself — and offers the way back.
    func testShowingFilesOutsideTheProjectListsThemAndOffersToHideThemAgain() throws {
        AppSettings.shared.includesAttachmentsOutsideProject = false
        let pane = try laidOutPaneNaming(
            try writeOutsideProjectPNG(),
            size: NSSize(width: 353, height: 900)
        )
        let band = try scopeBand(in: pane.view)

        let show = try XCTUnwrap(button(titled: L10n.string("Show"), in: band) as? ThemedButton)
        show.performClick()
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(AppSettings.shared.includesAttachmentsOutsideProject)
        // The pane's own answer, not the store's: the point of the control is that the list in
        // front of the person who pressed it changes.
        let table = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? NSTableView }.first
        )
        XCTAssertEqual(
            table.numberOfRows,
            2,
            "the file the pane offered to show is still not listed in it"
        )
        XCTAssertEqual(
            Set(SessionAttachmentStore.shared.attachments(for: pane.sessionID).map(\.name)),
            ["outside.png", "picture.png"]
        )
        _ = try button(titled: L10n.string("Hide"), in: band)
    }

    // MARK: - The Rows

    /// A row shows the picture it is about. This list is the panel's visual history now — the
    /// tab strip's column of identical `photo` glyphs is exactly what it replaced — so a row
    /// carrying a generic file icon would be the same failure one pane to the left.
    func testAnImageRowShowsItsOwnPictureRatherThanAFileIcon() throws {
        let url = try writePNG(
            named: "red.png", size: NSSize(width: 300, height: 200), color: .systemRed
        )
        let pane = try laidOutPane(showing: url, size: NSSize(width: 353, height: 900))
        let well = try iconWell(inRow: 0, of: pane)
        let image = try XCTUnwrap(well.image)

        // The picture's own colour rather than a document glyph's: read as "red leads", since
        // the exact components move with the colour conversion on the way through ImageIO.
        let centre = try centrePixel(of: image)
        XCTAssertGreaterThan(
            centre.redComponent - centre.greenComponent,
            0.3,
            "the row is showing something that is not the red picture behind it"
        )

        // Decoded at the row's size rather than the file's: this is what keeps a list of
        // full-screen screenshots from being 32 full decodes on the main thread.
        XCTAssertLessThanOrEqual(
            max(image.size.width, image.size.height),
            SessionAttachmentsDefaults.iconSize * SessionAttachmentsDefaults.thumbnailScale,
            "the row decoded more of the file than it can draw"
        )
        XCTAssertEqual(
            image.size.width / image.size.height,
            1.5,
            accuracy: 0.1,
            "the thumbnail was not decoded in the picture's own proportions"
        )
    }

    /// The same row says *when*, in the caption voice beside the origin mark: a chronology whose
    /// rows carry no time is a list whose order has to be taken on trust.
    func testARowSaysWhenTheFileArrived() throws {
        let url = try writePNG(size: NSSize(width: 40, height: 40))
        let pane = try laidOutPane(showing: url, size: NSSize(width: 353, height: 900))
        let attachment = try XCTUnwrap(
            SessionAttachmentStore.shared.attachments(for: pane.sessionID).first
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let expected = formatter.string(from: attachment.referencedAt)

        let row = try row(0, of: pane)
        let labels = descendants(of: row).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(
            labels.contains(expected),
            "no row label said when the file arrived: \(labels)"
        )
        // One sentence, not five: the time joins the row's single accessibility label.
        XCTAssertTrue(
            (row.accessibilityLabel() ?? "").contains(expected),
            "the moment is on screen but not in the row's spoken sentence"
        )
    }

    /// A PDF keeps the file icon. ImageIO is asked for a picture and there is none to give, and a
    /// blank well would be worse than the icon the system already has for the format.
    func testAPDFRowKeepsTheFileIcon() throws {
        let url = try writePDF()
        let pane = try laidOutPane(showing: url, size: NSSize(width: 353, height: 900))
        let attachment = try XCTUnwrap(
            SessionAttachmentStore.shared.attachments(for: pane.sessionID).first
        )

        XCTAssertNil(
            SessionAttachmentThumbnails.thumbnail(for: attachment),
            "a PDF was sent through the image decoder"
        )
        let well = try iconWell(inRow: 0, of: pane)
        XCTAssertEqual(
            well.image?.size,
            NSWorkspace.shared.icon(forFile: url.path).size,
            "the PDF row is not showing the system's icon for the file"
        )
    }

    /// The cache is keyed by modification date, so an overwritten file is a new picture at the
    /// same path — which is the case the list exists for, a chart regenerated in place.
    func testTheThumbnailCacheFollowsTheFileRatherThanItsPath() throws {
        let url = try writePNG(
            named: "chart.png", size: NSSize(width: 60, height: 60), color: .systemRed
        )
        let first = try XCTUnwrap(
            SessionAttachmentThumbnails.thumbnail(
                for: url, size: SessionAttachmentsDefaults.iconSize
            )
        )
        let before = try centrePixel(of: first)
        XCTAssertGreaterThan(before.redComponent - before.blueComponent, 0.3)

        // A second ask for an untouched file is answered from memory, not decoded again.
        XCTAssertTrue(
            SessionAttachmentThumbnails.thumbnail(
                for: url, size: SessionAttachmentsDefaults.iconSize
            ) === first,
            "an unchanged file was decoded twice"
        )

        try FileManager.default.removeItem(at: url)
        _ = try writePNG(
            named: "chart.png", size: NSSize(width: 60, height: 60), color: .systemBlue
        )
        // Stated rather than raced: the key is the modification date, and two writes a
        // millisecond apart would leave the test asserting the filesystem's clock resolution.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)],
            ofItemAtPath: url.path
        )
        let second = try XCTUnwrap(
            SessionAttachmentThumbnails.thumbnail(
                for: url, size: SessionAttachmentsDefaults.iconSize
            )
        )
        let after = try centrePixel(of: second)
        XCTAssertGreaterThan(
            after.blueComponent - after.redComponent,
            0.3,
            "the row kept showing the picture the file used to hold"
        )
    }

    // MARK: - Row Reading

    private func row(_ index: Int, of pane: SessionAttachmentsViewController) throws -> NSView {
        let table = try attachmentsTable(in: pane.view)
        return try XCTUnwrap(
            table.view(atColumn: 0, row: index, makeIfNecessary: true),
            "the list built no row \(index)"
        )
    }

    private func iconWell(
        inRow index: Int,
        of pane: SessionAttachmentsViewController
    ) throws -> NSImageView {
        let row = try row(index, of: pane)
        return try XCTUnwrap(
            ([row] + descendants(of: row)).compactMap { $0 as? NSImageView }.first,
            "the row has no icon well"
        )
    }

    private func centrePixel(of image: NSImage) throws -> NSColor {
        let data = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        let pixel = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        return try XCTUnwrap(pixel.usingColorSpace(.sRGB))
    }
}
