import AppKit
import XCTest
@testable import Threading

/// The attachments pane is two panes — the chronology above the fold, its preview below — with
/// a footer band naming the selected file beside the one action the user last took, and its
/// rows read as a visual history.
///
/// The shape these pin down: the list asks for its rows' height up to half the pane, the
/// preview is the layout's one flexible element between the fold and the footer, and the
/// footer is a `PaneFooterView` at the pane's floor — its band height `required`, so nothing
/// the preview or the list does can push the file's name and its action out of reach. What no
/// constraint here may do is state a content-derived height at `windowSizeStayPut` or above;
/// the window test at the bottom is the tripwire for that.
///
/// The rows are here for the same reason the list grew: this is where the panel's per-image
/// tabs went, so a row has to carry the picture and the moment a tab used to.
@MainActor
final class SessionAttachmentsLayoutTests: XCTestCase {

    /// Quick Look completes display-bundle activation asynchronously. Focused Quick Look fixtures
    /// and the one-workload-per-process stress command retain their offscreen windows until exit,
    /// avoiding an immediate XCTest teardown lifecycle the production pane never has.
    private static var parkedQuickLookWindows: [NSWindow] = []

    private var root: URL!
    private var outside: URL?

    /// The scope is a real behavioural setting on `.standard`, which under a hosted test bundle
    /// is the developer's own — so it is put back exactly as it was found.
    private var scopeBeforeTest = false

    /// The footer's remembered action lives in `PreferenceStore`'s scratch suite here — never
    /// the developer's own — but that suite persists across tests in one process, so it is
    /// still put back exactly as it was found.
    private var lastActionBeforeTest: String?

    /// The fold lives in the same scratch suite, and the same sentence applies twice over: a
    /// test that drags it decides where every *later* test in the process opens its pane.
    private var foldBeforeTest: CGFloat?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scopeBeforeTest = AppSettings.shared.includesAttachmentsOutsideProject
        lastActionBeforeTest = PreferenceStore.shared.string(
            forKey: SessionAttachmentsDefaults.lastActionKey
        )
        PreferenceStore.shared.removeObject(forKey: SessionAttachmentsDefaults.lastActionKey)
        foldBeforeTest = AttachmentsListHeight.stored
        AttachmentsListHeight.reset()
    }

    override func tearDownWithError() throws {
        if let foldBeforeTest {
            AttachmentsListHeight.record(foldBeforeTest)
        } else {
            AttachmentsListHeight.reset()
        }
        AppSettings.shared.includesAttachmentsOutsideProject = scopeBeforeTest
        if let lastActionBeforeTest {
            PreferenceStore.shared.set(
                lastActionBeforeTest,
                forKey: SessionAttachmentsDefaults.lastActionKey
            )
        } else {
            PreferenceStore.shared.removeObject(forKey: SessionAttachmentsDefaults.lastActionKey)
        }
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

    private func laidOutTurnPane(
        showing urls: [URL],
        size: NSSize
    ) throws -> (
        pane: SessionAttachmentsViewController,
        latest: SessionAttachmentTurnBoundary,
        previous: SessionAttachmentTurnBoundary
    ) {
        let sessionID = SessionID()
        let recorded = SessionAttachmentStore.shared.record(
            urls: urls, sessionID: sessionID, projectRoot: root
        )
        XCTAssertEqual(recorded.count, urls.count, "a fixture attachment was refused")

        let now = Date()
        let previous = SessionAttachmentTurnBoundary(
            id: GitTurnCheckpointID(),
            ordinal: 1,
            userTurnID: "previous-turn",
            requestedAt: now.addingTimeInterval(-2)
        )
        let latest = SessionAttachmentTurnBoundary(
            id: GitTurnCheckpointID(),
            ordinal: 2,
            userTurnID: "latest-turn",
            requestedAt: now.addingTimeInterval(-1)
        )
        SessionAttachmentStore.shared.associate(
            attachmentIDs: Array(recorded.prefix(2)).map(\.id),
            withTurnID: latest.userTurnID,
            for: sessionID
        )
        SessionAttachmentStore.shared.associate(
            attachmentIDs: Array(recorded.dropFirst(2)).map(\.id),
            withTurnID: previous.userTurnID,
            for: sessionID
        )

        let controller = SessionAttachmentsViewController(sessionID: sessionID)
        controller.turnBoundariesProvider = { [latest, previous] in [latest, previous] }
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.autoresizingMask = []
        controller.view.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, latest, previous)
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

    private func writeHTML(named name: String = "report.html") throws -> URL {
        let url = root.appendingPathComponent(name)
        try "<!doctype html><title>Report</title><p>Done</p>".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
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

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
        }
        XCTAssertTrue(condition(), "asynchronous pane update did not finish")
    }

    /// By identifier, not by type: the pane holds two `PaneFooterView`s now — the footer naming
    /// the selected file, and this band — and "the first one found" is whichever the traversal
    /// happens to reach.
    private func scopeBand(in view: NSView) throws -> PaneFooterView {
        try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? PaneFooterView }
                .first { $0.accessibilityIdentifier() == "attachments.scope-band" },
            "the pane grew no scope band"
        )
    }

    /// The band at the pane's floor naming the selected file beside its action.
    private func footerBand(in view: NSView) throws -> PaneFooterView {
        try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? PaneFooterView }
                .first { $0.accessibilityIdentifier() == "attachments.footer" },
            "the pane grew no footer band"
        )
    }

    /// The preview well between the fold and the footer — the one surface filled with
    /// `Design.Surface.ground`. Its identity is on the host rather than on whichever format
    /// renderer happens to have been installed lazily inside it.
    private func previewHost(in view: NSView) throws -> NSView {
        try XCTUnwrap(
            descendants(of: view).first {
                $0.accessibilityIdentifier() == "attachments.preview-host"
            },
            "the pane grew no preview"
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

    /// The same pane inside a window, which is what the preview key needs: the inspector
    /// installs into the window's own content view rather than opening a panel, so a pane held
    /// in nothing has nowhere to put it. Never ordered on screen — see the note in `CLAUDE.md`.
    private func windowedPane(
        showing urls: [URL],
        size: NSSize
    ) throws -> (pane: SessionAttachmentsViewController, window: NSWindow) {
        let pane = try laidOutPane(showing: urls, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = pane
        pane.view.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    /// The bare key, as the list receives it.
    private func spaceKey(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
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

    /// The footer is the pane's floor, whatever the pane's height: the file's name and its
    /// action are always in the same place, and the preview pane above them takes the slack.
    func testTheFooterIsThePanesFloorAndThePreviewTakesTheSlack() throws {
        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 400, height: 400)),
            size: NSSize(width: 353, height: 900)
        )
        let footer = try footerBand(in: pane.view)
        let preview = try previewHost(in: pane.view)

        XCTAssertEqual(footer.frame.minY, 0, accuracy: 0.5, "the footer left the pane's floor")
        XCTAssertEqual(
            footer.frame.height,
            Design.Size.footerHeight,
            accuracy: 0.5,
            "the footer is not the band `PaneFooterView` states"
        )
        XCTAssertGreaterThan(
            preview.frame.height,
            400,
            "a tall pane's slack did not go to the preview pane"
        )
        XCTAssertEqual(
            preview.frame.minY,
            footer.frame.maxY + Design.Spacing.small,
            accuracy: 1,
            "the preview does not stand directly on the footer"
        )
    }

    /// The same pane, shorter than the picture: the preview is what compresses — the footer
    /// keeps its band and stays reachable at the floor.
    func testAShortPaneCompressesThePreviewRatherThanTheFooter() throws {
        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 400, height: 400)),
            size: NSSize(width: 353, height: 420)
        )
        let footer = try footerBand(in: pane.view)
        let preview = try previewHost(in: pane.view)

        XCTAssertEqual(footer.frame.minY, 0, accuracy: 0.5, "the footer was pushed off the floor")
        XCTAssertEqual(
            footer.frame.height,
            Design.Size.footerHeight,
            accuracy: 0.5,
            "a short pane compressed the footer instead of the preview"
        )
        XCTAssertGreaterThan(preview.frame.height, 0, "the preview vanished entirely")
        XCTAssertLessThan(
            preview.frame.height,
            400,
            "a short pane did not compress the preview"
        )
    }

    /// Every kind fills the room between the fold and the footer now — a PDF, which reads
    /// better the taller it is, most visibly.
    func testAPDFStillFillsTheRoomThePaneHas() throws {
        let pane = try laidOutPane(
            showing: try writePDF(),
            size: NSSize(width: 353, height: 900)
        )
        let footer = try footerBand(in: pane.view)
        let preview = try previewHost(in: pane.view)

        XCTAssertEqual(footer.frame.minY, 0, accuracy: 0.5)
        XCTAssertGreaterThan(
            preview.frame.height,
            600,
            "a document's preview no longer fills the pane"
        )
        let document = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? MediaInspectorDocumentView }.first
        )
        XCTAssertTrue(document.hasPDFRendererForTesting)
        XCTAssertFalse(
            document.hasQuickLookRendererForTesting,
            "showing a PDF eagerly constructed the unused Quick Look renderer"
        )
    }

    // MARK: - The Footer's Sentence

    /// The band names the file on one side and offers the action on the other, centred on one
    /// line — the name gives way, never the controls.
    func testTheFooterNamesTheFileBesideItsAction() throws {
        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 600)
        )
        let footer = try footerBand(in: pane.view)
        let labels = descendants(of: footer).compactMap { $0 as? NSTextField }
        XCTAssertTrue(
            labels.contains { $0.stringValue == "picture.png" },
            "the footer does not name the selected file"
        )

        let open = try button(titled: L10n.string("Open"), in: footer)
        let chevron = try XCTUnwrap(
            descendants(of: footer).compactMap { $0 as? ThemedIconButton }.first,
            "the footer's action carries no menu beside it"
        )
        XCTAssertEqual(
            chevron.accessibilityTitle(),
            L10n.string("Attachment actions"),
            "the chevron says nothing assistive about what it opens"
        )

        // One centreline: the action stands on the same line as the name block, which is the
        // whole difference between a footer and a stack of leftovers.
        let openFrame = footer.convert(open.bounds, from: open)
        XCTAssertEqual(
            openFrame.midY,
            footer.bounds.midY,
            accuracy: 1,
            "the action is not centred in the band"
        )
    }

    /// "Last used wins": choosing from the menu is two things at once — the action runs, and it
    /// becomes what the footer's press does next. The entries walked here are the row menu's
    /// own, which is the same builder the chevron presents.
    ///
    /// Copy Path is the probe because it is the one rememberable action whose side effect a
    /// test can hold and put back — the pasteboard's string. Open and Finder leave the process.
    func testChoosingFromTheMenuBecomesTheFootersPress() throws {
        let clipboardBefore = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let clipboardBefore {
                NSPasteboard.general.setString(clipboardBefore, forType: .string)
            }
        }

        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 600)
        )
        let attachment = try XCTUnwrap(
            SessionAttachmentStore.shared.attachments(for: pane.sessionID).first
        )
        let copyPath = try XCTUnwrap(
            items(in: pane.contextMenuEntries(for: attachment))
                .first { $0.title == L10n.string("Copy Path") },
            "the menu no longer offers Copy Path"
        )
        copyPath.onChoose?()

        XCTAssertEqual(
            PreferenceStore.shared.string(forKey: SessionAttachmentsDefaults.lastActionKey),
            AttachmentAction.copyPath.rawValue,
            "the choice was not remembered"
        )
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            attachment.url.path,
            "the remembered choice did not also run"
        )
        _ = try button(titled: L10n.string("Copy Path"), in: try footerBand(in: pane.view))
    }

    /// The memory survives the pane: a fresh pane resolves the stored id before anything is
    /// chosen in it.
    func testAStoredActionRetitlesTheFootersPress() throws {
        PreferenceStore.shared.set(
            AttachmentAction.reveal.rawValue,
            forKey: SessionAttachmentsDefaults.lastActionKey
        )
        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 600)
        )
        _ = try button(titled: L10n.string("Finder"), in: try footerBand(in: pane.view))
    }

    /// A browser choice belongs to HTML, not to whichever unrelated file is selected next. The
    /// preference stays put while the footer falls back, so returning to HTML restores it.
    func testAStoredBrowserActionRetitlesOnlyAnHTMLSelection() throws {
        PreferenceStore.shared.set(
            AttachmentAction.openInBrowser.rawValue,
            forKey: SessionAttachmentsDefaults.lastActionKey
        )
        let htmlPane = try laidOutPane(
            showing: try writeHTML(),
            size: NSSize(width: 353, height: 600)
        )
        _ = try button(titled: L10n.string("Browser"), in: try footerBand(in: htmlPane.view))

        let imagePane = try laidOutPane(
            showing: try writePNG(named: "picture.png", size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 600)
        )
        _ = try button(titled: L10n.string("Open"), in: try footerBand(in: imagePane.view))
        XCTAssertEqual(
            PreferenceStore.shared.string(forKey: SessionAttachmentsDefaults.lastActionKey),
            AttachmentAction.openInBrowser.rawValue,
            "falling back outside HTML erased the remembered browser choice"
        )
    }

    /// A remembered Chat falls back while nothing is listening — a button performing nothing is
    /// worse than a button saying something else — and the memory itself is not overwritten, so
    /// the door reopening restores the remembered answer.
    func testARememberedChatFallsBackWhileNothingIsListening() throws {
        PreferenceStore.shared.set(
            AttachmentAction.chat.rawValue,
            forKey: SessionAttachmentsDefaults.lastActionKey
        )
        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 600)
        )

        _ = try button(titled: L10n.string("Open"), in: try footerBand(in: pane.view))
        XCTAssertEqual(
            PreferenceStore.shared.string(forKey: SessionAttachmentsDefaults.lastActionKey),
            AttachmentAction.chat.rawValue,
            "falling back rewrote the memory instead of waiting out the closed door"
        )
    }

    // MARK: - Several Rows At Once

    /// Several rows are a batch: the list allows the selection, the footer counts it, and the
    /// preview says the same count rather than pretending one picture speaks for three.
    func testSelectingSeveralRowsTurnsTheFooterIntoABatch() throws {
        let pane = try laidOutPane(
            showing: try writePNGs(count: 3, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 700)
        )
        let table = try attachmentsTable(in: pane.view)
        XCTAssertTrue(table.allowsMultipleSelection, "the list refuses a second selected row")

        table.selectRowIndexes(IndexSet(0..<3), byExtendingSelection: false)
        pane.view.layoutSubtreeIfNeeded()

        let footer = try footerBand(in: pane.view)
        let labels = descendants(of: footer).compactMap { ($0 as? NSTextField)?.stringValue }
        let expected = L10n.format("%lld files selected", 3)
        XCTAssertTrue(labels.contains(expected), "the footer does not count the batch: \(labels)")
    }

    /// The remembered action applies to the whole batch. Copy Path is the probe again — the one
    /// action whose side effect a test can hold and put back.
    func testTheFootersPressActsOnEverySelectedRow() throws {
        let clipboardBefore = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let clipboardBefore {
                NSPasteboard.general.setString(clipboardBefore, forType: .string)
            }
        }
        PreferenceStore.shared.set(
            AttachmentAction.copyPath.rawValue,
            forKey: SessionAttachmentsDefaults.lastActionKey
        )

        let pane = try laidOutPane(
            showing: try writePNGs(count: 2, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 700)
        )
        let table = try attachmentsTable(in: pane.view)
        table.selectRowIndexes(IndexSet(0..<2), byExtendingSelection: false)
        pane.view.layoutSubtreeIfNeeded()

        let press = try XCTUnwrap(
            button(titled: L10n.string("Copy Path"), in: try footerBand(in: pane.view))
                as? ThemedButton
        )
        press.performClick()

        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        let expected = Set(
            SessionAttachmentStore.shared.attachments(for: pane.sessionID)
                .prefix(2)
                .map(\.url.path)
        )
        XCTAssertEqual(
            Set(copied.split(separator: "\n").map(String.init)),
            expected,
            "the footer's press did not act on the whole selection"
        )
    }

    /// A batch's chevron menu keeps only the actions that mean something said of several files —
    /// no editor submenu, comparison, or comment — and offers the batch forms of the rest.
    func testABatchMenuOffersTheBatchActionsOnly() throws {
        let pane = try laidOutPane(
            showing: try writePNGs(count: 2, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 700)
        )
        let table = try attachmentsTable(in: pane.view)
        table.selectRowIndexes(IndexSet(0..<2), byExtendingSelection: false)

        let selection = SessionAttachmentStore.shared.attachments(for: pane.sessionID)
        let titles = items(in: pane.actionMenuEntries(for: selection)).map(\.title)
        XCTAssertTrue(titles.contains(L10n.string("Open")))
        XCTAssertTrue(titles.contains(L10n.string("Reveal in Finder")))
        XCTAssertTrue(titles.contains(L10n.string("Copy Files")))
        XCTAssertTrue(titles.contains(L10n.string("Copy Path")))
        XCTAssertFalse(
            titles.contains(L10n.string("Compare with")),
            "a batch was offered a comparison, which is a decision about one pair"
        )
    }

    /// Opening in a browser means the whole selection can go there. A run of HTML files gets the
    /// batch action; mixing in a picture removes it rather than silently acting on only part.
    func testOnlyAnAllHTMLBatchOffersOpenInBrowser() throws {
        let pane = try laidOutPane(
            showing: [
                try writeHTML(named: "first.html"),
                try writeHTML(named: "second.htm"),
                try writePNG(named: "picture.png", size: NSSize(width: 40, height: 40))
            ],
            size: NSSize(width: 353, height: 700)
        )
        let listed = SessionAttachmentStore.shared.attachments(for: pane.sessionID)
        let html = listed.filter { $0.kind == .html }
        XCTAssertEqual(html.count, 2, "the fixture did not record both HTML files")

        let htmlTitles = items(in: pane.actionMenuEntries(for: html)).map(\.title)
        XCTAssertTrue(htmlTitles.contains(L10n.string("Open in Browser")))

        let mixedTitles = items(in: pane.actionMenuEntries(for: listed)).map(\.title)
        XCTAssertFalse(
            mixedTitles.contains(L10n.string("Open in Browser")),
            "a mixed batch offered an action that could only handle part of it"
        )
    }

    // MARK: - Kinds

    /// The browser action is a property of HTML, not a generic file action. `Open` remains beside
    /// it because that follows the file association and may deliberately be an editor.
    func testAnHTMLRowAloneOffersOpenInBrowser() throws {
        let pane = try laidOutPane(
            showing: [
                try writeHTML(),
                try writePNG(named: "picture.png", size: NSSize(width: 40, height: 40))
            ],
            size: NSSize(width: 353, height: 700)
        )
        let listed = SessionAttachmentStore.shared.attachments(for: pane.sessionID)
        let html = try XCTUnwrap(listed.first { $0.kind == .html })
        let image = try XCTUnwrap(listed.first { $0.kind == .image })

        let htmlTitles = items(in: pane.contextMenuEntries(for: html)).map(\.title)
        XCTAssertTrue(htmlTitles.contains(L10n.string("Open")))
        XCTAssertTrue(htmlTitles.contains(L10n.string("Open in Browser")))

        let imageTitles = items(in: pane.contextMenuEntries(for: image)).map(\.title)
        XCTAssertFalse(imageTitles.contains(L10n.string("Open in Browser")))
    }

    /// An archive and an office document land in the document preview — the same Quick Look
    /// surface the space bar shows in Finder — never in the image decoder.
    func testArchivesAndDocumentsPreviewThroughTheDocumentView() throws {
        // The smallest zip there is: a bare end-of-central-directory record.
        let zip = root.appendingPathComponent("bundle.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: zip)
        let pane = try laidOutPane(showing: zip, size: NSSize(width: 353, height: 700))
        let quickLookWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 353, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        quickLookWindow.contentViewController = pane
        Self.parkedQuickLookWindows.append(quickLookWindow)

        let document = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? MediaInspectorDocumentView }.first,
            "the pane grew no document preview"
        )
        XCTAssertFalse(document.isHidden, "an archive found nothing to preview it")
        XCTAssertTrue(
            descendants(of: pane.view).compactMap { $0 as? ThemedImagePreview }.isEmpty,
            "an archive initialized the image preview"
        )
        XCTAssertTrue(document.hasQuickLookRendererForTesting)
        XCTAssertFalse(
            document.hasPDFRendererForTesting,
            "showing an archive eagerly constructed the unused PDF renderer"
        )

        let attachment = try XCTUnwrap(
            SessionAttachmentStore.shared.attachments(for: pane.sessionID).first
        )
        XCTAssertEqual(attachment.kind, .archive)
        XCTAssertNil(
            SessionAttachmentThumbnails.thumbnail(for: attachment),
            "an archive was sent through the image decoder for its row"
        )
    }

    // MARK: - The Preview Key

    /// Space is the key Finder previews with, and the pane answers it with the app's own
    /// inspector rather than the system panel — the same surface a click on the picture below
    /// the fold opens, positioned on the selected row and carrying the other rows on its rail.
    func testSpaceOnAnImageRowOpensTheAppsOwnInspectorOnTheRail() throws {
        let pictures = try writePNGs(count: 3, size: NSSize(width: 40, height: 30))
        let (pane, window) = try windowedPane(
            showing: pictures, size: NSSize(width: 353, height: 700)
        )
        defer { MediaInspectorPresenter.dismiss(in: window) }
        let table = try attachmentsTable(in: pane.view)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        table.keyDown(with: try spaceKey(in: window))

        XCTAssertTrue(
            MediaInspectorPresenter.isPresenting(in: window),
            "Space on a selected picture opened nothing"
        )
        XCTAssertEqual(
            descendants(of: pane.view).compactMap { $0 as? MediaInspectorView }.count,
            1,
            "the key opened something other than the app's own inspector"
        )
        let selection = try XCTUnwrap(pane.mediaInspectorSelection(forRow: 1))
        XCTAssertEqual(selection.items.count, 3, "the row opened alone rather than on the rail")
        XCTAssertEqual(selection.selectedIndex, 1, "the rail opened on a row nobody selected")
        XCTAssertNil(
            PreferenceStore.shared.string(forKey: SessionAttachmentsDefaults.lastActionKey),
            "looking at a row is not a choice about what to do with it, and moved the footer's memory"
        )
    }

    /// A modified Space is somebody else's — Command-Space is Spotlight's — so only the bare key
    /// is claimed. Asserted here because the list, not the pane, is what draws that line.
    func testAModifiedSpaceIsNotThePreviewKey() throws {
        let pictures = try writePNGs(count: 2, size: NSSize(width: 40, height: 30))
        let (pane, window) = try windowedPane(
            showing: pictures, size: NSSize(width: 353, height: 700)
        )
        defer { MediaInspectorPresenter.dismiss(in: window) }
        let table = try attachmentsTable(in: pane.view)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let bare = try spaceKey(in: window)
        let commanded = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: bare.keyCode
        ))
        table.keyDown(with: commanded)

        XCTAssertFalse(
            MediaInspectorPresenter.isPresenting(in: window),
            "the list claimed a key it shares with the system"
        )
    }

    /// The other kinds the inspector can hold open alone: there is no rail for an archive to
    /// join, and the same contained boundary that renders it below the fold renders it here.
    func testSpaceOnAnArchiveRowOpensItAlone() throws {
        let zip = root.appendingPathComponent("bundle.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: zip)
        let (pane, window) = try windowedPane(
            showing: [zip], size: NSSize(width: 353, height: 700)
        )
        let table = try attachmentsTable(in: pane.view)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        table.keyDown(with: try spaceKey(in: window))

        XCTAssertTrue(
            MediaInspectorPresenter.isPresenting(in: window),
            "Space on an archive opened nothing"
        )
        XCTAssertNil(
            pane.mediaInspectorSelection(forRow: 0),
            "an archive joined the image rail, where the inspector can only draw a blank"
        )
        MediaInspectorPresenter.dismiss(in: window)
        // Quick Look's display bundle activates asynchronously — see `parkedQuickLookWindows`.
        Self.parkedQuickLookWindows.append(window)
    }

    /// HTML and diagram source are the two kinds the pane renders itself — a non-persistent web
    /// view and a text view — and routing them into the inspector would hand both to a system
    /// previewer instead. The key declines, so the list keeps it and the row's own preview,
    /// already on screen, stands.
    func testSpaceOnAnHTMLRowLeavesTheKeyWithTheList() throws {
        let html = root.appendingPathComponent("preview.html")
        try Data("<html><body>Preview</body></html>".utf8).write(to: html)
        let (pane, window) = try windowedPane(
            showing: [html], size: NSSize(width: 353, height: 700)
        )
        defer { MediaInspectorPresenter.dismiss(in: window) }
        let table = try attachmentsTable(in: pane.view)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        table.keyDown(with: try spaceKey(in: window))

        XCTAssertFalse(
            MediaInspectorPresenter.isPresenting(in: window),
            "HTML was handed to a previewer the pane deliberately does not use for it"
        )
    }

    /// HTML is the one preview whose system handoff can exceed a frame after the app is warm.
    /// The pane itself must finish first, and a later row selection must be able to cancel this
    /// handoff before WebKit starts navigating stale content.
    func testHTMLNavigationWaitsUntilAfterThePaneMounts() throws {
        let html = root.appendingPathComponent("preview.html")
        try Data("<html><body>Preview</body></html>".utf8).write(to: html)
        let pane = try laidOutPane(showing: html, size: NSSize(width: 353, height: 700))

        XCTAssertTrue(
            pane.hasPendingHTMLNavigationForTesting,
            "WebKit navigation blocked the pane's initial mount"
        )
        XCTAssertFalse(
            pane.hasInstalledHTMLRendererForTesting,
            "the deferred navigation still constructed WebKit during pane mount"
        )
        XCTAssertEqual(pane.latestHTMLNavigationNanosecondsForTesting, 0)
        XCTAssertGreaterThan(pane.flushPendingHTMLNavigationForTesting(), 0)
        XCTAssertFalse(pane.hasPendingHTMLNavigationForTesting)
        XCTAssertTrue(pane.hasInstalledHTMLRendererForTesting)
    }

    /// A file over the preview cap is refused before any surface touches it: the size is read
    /// from metadata, the message is the whole preview, and neither Quick Look nor the image
    /// decoder is ever asked. Pinned with an archive because archives are where multi-gigabyte
    /// files live — and nothing in the app ever unpacks one.
    func testAFileOverThePreviewCapIsRefusedBeforeAnySurfaceTouchesIt() throws {
        let huge = root.appendingPathComponent("release.zip")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        // Sparse on purpose: the *reported* size is what the gate reads, and a fixture that
        // wrote 65 MB of zeros would be paying for bytes the test exists to prove untouched.
        try handle.truncate(
            atOffset: UInt64(SessionAttachmentsDefaults.maximumPreviewFileBytes) + 1
        )
        try handle.close()
        let pane = try laidOutPane(showing: huge, size: NSSize(width: 353, height: 700))

        let labels = descendants(of: pane.view).compactMap { $0 as? NSTextField }
        XCTAssertTrue(
            labels.contains {
                $0.stringValue == L10n.string("This file is too large to preview here.")
                    && !$0.isHidden
            },
            "an oversized file was not refused with the message"
        )
        XCTAssertTrue(
            descendants(of: pane.view).compactMap { $0 as? MediaInspectorDocumentView }.isEmpty,
            "an oversized archive initialized Quick Look before the size gate"
        )
    }

    /// Diagram source previews as itself: the pane carries no Graphviz or Mermaid engine, and
    /// the source — short, legible, and what gets dragged into a chat box next — beats an icon
    /// card claiming there is nothing to see.
    func testADiagramPreviewsItsOwnSource() throws {
        let source = "graph TD; Composer-->Terminal"
        let mermaid = root.appendingPathComponent("flow.mmd")
        try Data(source.utf8).write(to: mermaid)
        let pane = try laidOutPane(showing: mermaid, size: NSSize(width: 353, height: 700))

        let text = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? ThemedTextView }.first,
            "the pane grew no source preview"
        )
        XCTAssertEqual(text.string, source, "the preview is not the file's own source")
        XCTAssertFalse(text.isEditable, "a preview must not take edits")
        XCTAssertFalse(
            try XCTUnwrap(text.enclosingScrollView).isHidden,
            "the source preview is built but not shown"
        )
        XCTAssertTrue(
            descendants(of: pane.view).compactMap { $0 as? ThemedImagePreview }.isEmpty,
            "a diagram initialized the image preview"
        )
    }

    private func items(in entries: [ThemedMenuEntry]) -> [ThemedMenuItem] {
        entries.compactMap {
            if case .item(let item) = $0 { return item }
            return nil
        }
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

    /// Rows *and* a picture taller than the pane, in a pane too short for either. The preview
    /// is what gives way — the list is capped at half the pane and the footer's band is
    /// `required`, so neither can be what yields.
    func testRowsAndATallImageInAShortPaneStillCompressThePreview() throws {
        let height: CGFloat = 420
        let pane = try laidOutPane(
            showing: try writePNGs(count: 8, size: NSSize(width: 400, height: 400)),
            size: NSSize(width: 353, height: height)
        )
        let footer = try footerBand(in: pane.view)
        let list = try list(in: pane.view)

        XCTAssertEqual(
            footer.frame.minY,
            0,
            accuracy: 0.5,
            "the rows pushed the footer out of the pane"
        )
        XCTAssertEqual(
            footer.frame.height,
            Design.Size.footerHeight,
            accuracy: 0.5,
            "a crowded pane compressed the footer instead of the preview"
        )
        XCTAssertEqual(
            list.frame.height,
            height * SessionAttachmentsDefaults.listShareOfPane,
            accuracy: 1,
            "the list gave up its share to the preview rather than the other way round"
        )
    }

    // MARK: - The Fold

    /// Half the pane is the right *opening* answer and the wrong permanent one. A session with
    /// eighteen attachments fills that cap, and the report a row is pointing at then gets half a
    /// pane to be read in however long it is — which is where this came from.
    func testDraggingTheFoldDownGivesTheListTheRoomThePreviewHad() throws {
        let height: CGFloat = 420
        let pane = try laidOutPane(
            showing: try writePNGs(count: 20, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: height)
        )
        let list = try list(in: pane.view)
        let preview = try previewHost(in: pane.view)
        let opened = list.frame.height
        let openedPreview = preview.frame.height

        pane.foldDragged(by: 60)
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(list.frame.height, opened + 60, accuracy: 1, "the fold did not travel")
        XCTAssertEqual(
            preview.frame.height,
            openedPreview - 60,
            accuracy: 1,
            "the list grew into something other than the preview"
        )
    }

    /// And back the other way, which is the same gesture asked of a session whose pictures matter
    /// less than the page one of them is pointing at.
    func testDraggingTheFoldUpGivesThePreviewTheRoomTheListHad() throws {
        let height: CGFloat = 420
        let pane = try laidOutPane(
            showing: try writePNGs(count: 20, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: height)
        )
        let list = try list(in: pane.view)
        let preview = try previewHost(in: pane.view)
        let openedPreview = preview.frame.height

        pane.foldDragged(by: -80)
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            preview.frame.height,
            openedPreview + 80,
            accuracy: 1,
            "the preview did not take the room the list gave up"
        )
        XCTAssertGreaterThan(
            try lastRowOverflow(in: pane.view),
            0,
            "the rows the shrunken list left out cannot be scrolled to"
        )
    }

    /// The two limits the pane keeps for itself. A list dragged to nothing is a scroller with
    /// nothing legible beside it, and a list dragged over the whole pane leaves a preview that
    /// can no longer show what a row is about — neither is a reading choice.
    ///
    /// In a pane tall enough to deliver that ceiling: a share is a fraction, and four fifths of a
    /// *short* pane is more than what is left after the header, the fold and the footer, so there
    /// the list constraint gives way first and lands below its own ceiling. The case below covers
    /// that end.
    func testTheFoldStopsAtOneRowAndAtTheListsMaximumShare() throws {
        let height: CGFloat = 900
        let pane = try laidOutPane(
            showing: try writePNGs(count: 30, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: height)
        )
        let list = try list(in: pane.view)

        pane.foldDragged(by: -1_000)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(
            list.frame.height,
            SessionAttachmentsDefaults.rowHeight,
            "the fold shrank the list past the one row it must always show"
        )
        XCTAssertLessThan(
            list.frame.height,
            SessionAttachmentsDefaults.rowHeight * 2,
            "the fold stopped short of the floor it is allowed to reach"
        )

        pane.foldDragged(by: 1_000)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            list.frame.height,
            height * SessionAttachmentsDefaults.maximumListShareOfPane,
            accuracy: 1,
            "the list took more of the pane than a fold may give it"
        )
    }

    /// The same drag in a pane too short to give that ceiling away. The list asks for four fifths
    /// and the layout answers with what is left after the footer, whose band height is `required`
    /// while the list's is not — the pane's own compression order, which a fold cannot reverse.
    func testAFoldDraggedToTheFloorOfAShortPaneStillLeavesTheFooterWhole() throws {
        let height: CGFloat = 420
        let pane = try laidOutPane(
            showing: try writePNGs(count: 20, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: height)
        )
        let list = try list(in: pane.view)
        let footer = try footerBand(in: pane.view)

        pane.foldDragged(by: 1_000)
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            list.frame.height,
            height * SessionAttachmentsDefaults.maximumListShareOfPane + 1,
            "the list took more of a short pane than a fold may ask for"
        )
        XCTAssertEqual(footer.frame.minY, 0, accuracy: 0.5, "the fold pushed the footer out")
        XCTAssertEqual(
            footer.frame.height,
            Design.Size.footerHeight,
            accuracy: 0.5,
            "the fold compressed the footer instead of stopping at what was left"
        )
    }

    /// The travel used to stop at the last row, on the reasoning that past the rows there is
    /// nothing more to show. What was under the hand was still a divider, though, and a divider
    /// that stops halfway down a pane with room plainly left under it reads as broken rather than
    /// as considerate — reported as "can't be expanded beyond the cells, feels buggy".
    ///
    /// The drag back still moves on its first point, which is what the old clamp was protecting:
    /// the running total is held between limits the fold can express, so there is no overshoot to
    /// cross before anything happens.
    func testTheFoldCanBeDraggedPastTheRowsThereAre() throws {
        let pane = try laidOutPane(
            showing: try writePNGs(count: 3, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 900)
        )
        let list = try list(in: pane.view)
        let rows = list.frame.height

        pane.foldDragged(by: 200)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            list.frame.height,
            rows + 200,
            accuracy: 1,
            "the fold stopped at the last row with pane still left under it"
        )

        pane.foldDragged(by: -40)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            list.frame.height,
            rows + 160,
            accuracy: 1,
            "the drag back had to cross an overshoot that was never on screen"
        )
    }

    /// A fold is how someone wants to *read* their attachments, which does not change between two
    /// conversations — so the next pane opens where the last one was left.
    func testThePaneOpensWhereTheFoldWasLeft() throws {
        let size = NSSize(width: 353, height: 420)
        let first = try laidOutPane(
            showing: try writePNGs(count: 20, size: NSSize(width: 40, height: 40)),
            size: size
        )
        first.foldDragged(by: -70)
        first.view.layoutSubtreeIfNeeded()
        let chosen = try list(in: first.view).frame.height

        let second = try laidOutPane(
            showing: try writePNGs(count: 20, size: NSSize(width: 40, height: 40)),
            size: size
        )

        XCTAssertEqual(
            try list(in: second.view).frame.height,
            chosen,
            accuracy: 1,
            "the second pane opened on its own share rather than on the fold's"
        )
    }

    /// A fold the reader placed is a **position**, and the pane's own opening answer is the only
    /// thing that is content-sized. A one-attachment session therefore opens at the fold with room
    /// under its row, rather than snapping back to the row — which is the same springing-back the
    /// case above removes, seen one session later.
    func testARememberedFoldIsWhereAOneRowListOpensTo() throws {
        AttachmentsListHeight.record(300)

        let pane = try laidOutPane(
            showing: try writePNG(size: NSSize(width: 400, height: 400)),
            size: NSSize(width: 353, height: 900)
        )

        XCTAssertEqual(
            try list(in: pane.view).frame.height,
            300,
            accuracy: 1,
            "a one-row list was pulled back to its row rather than opening at the fold"
        )
    }

    /// And the pane's *own* answer stays content-sized, which is the half of the old rule that was
    /// right: a session with three attachments opens as three rows, not as half a blank pane.
    func testAPaneWhoseFoldHasNeverMovedOpensOnItsRows() throws {
        let height: CGFloat = 900
        let pane = try laidOutPane(
            showing: try writePNGs(count: 3, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: height)
        )

        XCTAssertLessThan(
            try list(in: pane.view).frame.height,
            height * SessionAttachmentsDefaults.listShareOfPane,
            "an untouched fold opened on the pane's share rather than on the rows there are"
        )
    }

    /// The way out of a fold left somewhere unhelpful, without having to find the original
    /// position by hand: the same double-click `NSSplitView` answers.
    func testDoubleClickingTheFoldPutsThePaneBackOnItsOwnShare() throws {
        let height: CGFloat = 420
        let pane = try laidOutPane(
            showing: try writePNGs(count: 20, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: height)
        )
        let list = try list(in: pane.view)

        pane.foldDragged(by: -90)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(
            list.frame.height,
            height * SessionAttachmentsDefaults.listShareOfPane,
            accuracy: 1
        )

        pane.foldDidReset()
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            list.frame.height,
            height * SessionAttachmentsDefaults.listShareOfPane,
            accuracy: 1,
            "the pane did not place the fold again"
        )
        XCTAssertNil(AttachmentsListHeight.stored, "the reset left the chosen height behind")
    }

    /// The seam is also the grip, and the pane's own gap under it is what makes it one: a fold
    /// that became draggable by growing its own strip would have moved everything below it.
    func testTheFoldIsAGripWithoutHavingMovedThePreviewDown() throws {
        let pane = try laidOutPane(
            showing: try writePNGs(count: 8, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 900)
        )
        let fold = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? PaneFoldDivider }.first,
            "the pane grew no fold"
        )
        let list = try list(in: pane.view)
        let preview = try previewHost(in: pane.view)

        XCTAssertEqual(
            fold.frame.height,
            Design.Radius.border + PaneFoldDivider.Layout.grip,
            accuracy: 0.5,
            "the fold is a hairline again, which is a one-point drag target"
        )
        XCTAssertEqual(
            fold.frame.maxY,
            list.frame.minY,
            accuracy: 0.5,
            "the fold floats below the list it ends"
        )
        XCTAssertEqual(
            preview.frame.maxY,
            fold.frame.minY,
            accuracy: 0.5,
            "the preview left a second gap under the fold's own band"
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

        // The band is the pane's floor while it is there, so the footer stops above it rather
        // than sliding underneath the one control that explains it.
        let footer = try footerBand(in: pane.view)
        XCTAssertGreaterThanOrEqual(
            footer.frame.minY,
            band.frame.maxY - 0.5,
            "the pane's footer was laid out over the scope band"
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
        let table = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? NSTableView }.first
        )
        show.performClick()
        waitUntil { table.numberOfRows == 2 }
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(AppSettings.shared.includesAttachmentsOutsideProject)
        // The pane's own answer, not the store's: the point of the control is that the list in
        // front of the person who pressed it changes.
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

    // MARK: - Stress

    /// Opt-in end-to-end workload for every attachment preview family at the session cap.
    ///
    /// Detection-only profiling cannot see the expensive half of a format handler: row icons,
    /// full-image decode, PDFKit construction, Quick Look handoff, WebKit navigation, or source
    /// insertion into TextKit. Fixture files are generated and admitted before the clock starts;
    /// the reported phases cover the production pane's cold mount, layout/draw, and two complete
    /// selection passes so cold decoder cost stays distinguishable from warm switching.
    func testStressAttachmentFormatPipelineWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_ATTACHMENT_FORMAT_STRESS"] == "1",
            "Set THREADING_ATTACHMENT_FORMAT_STRESS=1 to run the format-preview sweep."
        )

        let environment = ProcessInfo.processInfo.environment
        let format = AttachmentStressFormat(
            rawValue: environment["THREADING_ATTACHMENT_FORMAT_STRESS_KIND"] ?? "mixed"
        ) ?? .mixed
        let requestedCount = environment["THREADING_ATTACHMENT_FORMAT_STRESS_FILES"]
            .flatMap(Int.init) ?? SessionAttachmentDefaults.maximumPerSession
        let fileCount = max(1, min(SessionAttachmentDefaults.maximumPerSession, requestedCount))
        let urls = try makeAttachmentStressFiles(format: format, count: fileCount)
        let sourceBytes = urls.reduce(UInt64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + UInt64(max(size, 0))
        }
        let sessionID = SessionID()
        let recorded = SessionAttachmentStore.shared.record(
            urls: urls,
            sessionID: sessionID,
            projectRoot: root
        )
        XCTAssertEqual(recorded.count, fileCount)
        let baselineMemory = Self.physicalFootprintBytes()

        let constructStarted = DispatchTime.now().uptimeNanoseconds
        let initStarted = DispatchTime.now().uptimeNanoseconds
        let pane = SessionAttachmentsViewController(sessionID: sessionID)
        let initEnded = DispatchTime.now().uptimeNanoseconds
        let viewLoadStarted = DispatchTime.now().uptimeNanoseconds
        _ = pane.view
        let viewLoadEnded = DispatchTime.now().uptimeNanoseconds
        let constructEnded = DispatchTime.now().uptimeNanoseconds
        let coldPreview = try XCTUnwrap(pane.firstPreviewTimingForTesting)
        let coldPreviewCalls = pane.previewPresentationCountForTesting
        XCTAssertEqual(
            coldPreviewCalls,
            1,
            "restoring the initial row presented its preview through both refresh and the delegate"
        )
        let constructNanoseconds = constructEnded - constructStarted
        let coldHTMLNavigationNanoseconds = pane.flushPendingHTMLNavigationForTesting()
        let coldHTMLInstallNanoseconds = pane.latestHTMLRendererInstallNanosecondsForTesting
        let shellNanoseconds = constructNanoseconds >= coldPreview.totalNanoseconds
            ? constructNanoseconds - coldPreview.totalNanoseconds
            : 0
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 760),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = pane
        let layoutStarted = DispatchTime.now().uptimeNanoseconds
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds

        let table = try attachmentsTable(in: pane.view)
        XCTAssertEqual(table.numberOfRows, fileCount)
        let bitmap = try XCTUnwrap(pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds))
        let coldDrawStarted = DispatchTime.now().uptimeNanoseconds
        pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
        let coldDrawEnded = DispatchTime.now().uptimeNanoseconds

        let coldSwitchStarted = DispatchTime.now().uptimeNanoseconds
        for row in 0..<table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            pane.flushPendingHTMLNavigationForTesting()
            pane.view.layoutSubtreeIfNeeded()
        }
        let coldSwitchEnded = DispatchTime.now().uptimeNanoseconds

        let warmSwitchStarted = DispatchTime.now().uptimeNanoseconds
        for row in (0..<table.numberOfRows).reversed() {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            pane.flushPendingHTMLNavigationForTesting()
            pane.view.layoutSubtreeIfNeeded()
        }
        let warmSwitchEnded = DispatchTime.now().uptimeNanoseconds
        let warmDrawStarted = DispatchTime.now().uptimeNanoseconds
        pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
        let warmDrawEnded = DispatchTime.now().uptimeNanoseconds

        let finalMemory = Self.physicalFootprintBytes()
        let footprint = finalMemory >= baselineMemory ? finalMemory - baselineMemory : 0

        // The app has already loaded AppKit and its design system long before a person opens a
        // second attachment pane. Keep a same-process reopen beside the fresh-process number so
        // framework/class initialization is not mistaken for repeatable pane work.
        let warmConstructStarted = DispatchTime.now().uptimeNanoseconds
        let warmPane = SessionAttachmentsViewController(sessionID: sessionID)
        _ = warmPane.view
        let warmConstructEnded = DispatchTime.now().uptimeNanoseconds
        let reopenedPreview = try XCTUnwrap(warmPane.firstPreviewTimingForTesting)
        let warmConstructNanoseconds = warmConstructEnded - warmConstructStarted
        let warmHTMLNavigationNanoseconds = warmPane.flushPendingHTMLNavigationForTesting()
        let warmHTMLInstallNanoseconds = warmPane.latestHTMLRendererInstallNanosecondsForTesting
        let warmShellNanoseconds = warmConstructNanoseconds >= reopenedPreview.totalNanoseconds
            ? warmConstructNanoseconds - reopenedPreview.totalNanoseconds
            : 0
        let warmWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 760),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        warmWindow.contentViewController = warmPane
        print(
            "THREADING_PERF attachment-formats "
                + "format=\(format.rawValue) files=\(fileCount) "
                + "source_mb=\(Self.megabytes(sourceBytes)) "
                + "construct_ms=\(Self.milliseconds(constructNanoseconds)) "
                + "init_ms=\(Self.milliseconds(initEnded - initStarted)) "
                + "view_load_ms=\(Self.milliseconds(viewLoadEnded - viewLoadStarted)) "
                + "shell_ms=\(Self.milliseconds(shellNanoseconds)) "
                + "preview_calls=\(coldPreviewCalls) "
                + "preview_total_ms=\(Self.milliseconds(coldPreview.totalNanoseconds)) "
                + "metadata_ms=\(Self.milliseconds(coldPreview.metadataNanoseconds)) "
                + "clear_ms=\(Self.milliseconds(coldPreview.clearNanoseconds)) "
                + "prepare_ms=\(Self.milliseconds(coldPreview.prepareNanoseconds)) "
                + "install_ms=\(Self.milliseconds(coldPreview.installNanoseconds)) "
                + "present_ms=\(Self.milliseconds(coldPreview.presentNanoseconds)) "
                + "deferred_html_install_ms=\(Self.milliseconds(coldHTMLInstallNanoseconds)) "
                + "deferred_html_ms=\(Self.milliseconds(coldHTMLNavigationNanoseconds)) "
                + "warm_construct_ms=\(Self.milliseconds(warmConstructNanoseconds)) "
                + "warm_shell_ms=\(Self.milliseconds(warmShellNanoseconds)) "
                + "warm_preview_ms=\(Self.milliseconds(reopenedPreview.totalNanoseconds)) "
                + "warm_install_ms=\(Self.milliseconds(reopenedPreview.installNanoseconds)) "
                + "warm_present_ms=\(Self.milliseconds(reopenedPreview.presentNanoseconds)) "
                + "warm_deferred_html_install_ms=\(Self.milliseconds(warmHTMLInstallNanoseconds)) "
                + "warm_deferred_html_ms=\(Self.milliseconds(warmHTMLNavigationNanoseconds)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - layoutStarted)) "
                + "cold_draw_ms=\(Self.milliseconds(coldDrawEnded - coldDrawStarted)) "
                + "cold_switch_ms=\(Self.milliseconds(coldSwitchEnded - coldSwitchStarted)) "
                + "warm_switch_ms=\(Self.milliseconds(warmSwitchEnded - warmSwitchStarted)) "
                + "warm_draw_ms=\(Self.milliseconds(warmDrawEnded - warmDrawStarted)) "
                + "descendants=\(descendants(of: pane.view).count) "
                + "footprint_delta_mb=\(Self.megabytes(footprint))"
        )
        Self.parkedQuickLookWindows.append(contentsOf: [window, warmWindow])
    }

    // MARK: - The Rows

    func testTurnHeadersSeparateAndCollapseVirtualAttachmentRows() throws {
        let fixture = try laidOutTurnPane(
            showing: try writePNGs(count: 3, size: NSSize(width: 40, height: 40)),
            size: NSSize(width: 353, height: 900)
        )
        let table = fixture.pane.tableViewForTesting

        XCTAssertEqual(table.numberOfRows, 5, "two headers did not separate the three files")
        let latestHeader = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? SessionAttachmentTurnHeaderView
        )
        XCTAssertEqual(latestHeader.sectionID, .checkpoint(fixture.latest.id))
        XCTAssertFalse(fixture.pane.tableView(table, shouldSelectRow: 0))
        XCTAssertTrue(fixture.pane.tableView(table, shouldSelectRow: 1))

        let previousHeader = try XCTUnwrap(
            table.view(atColumn: 0, row: 3, makeIfNecessary: true)
                as? SessionAttachmentTurnHeaderView
        )
        XCTAssertEqual(previousHeader.sectionID, .checkpoint(fixture.previous.id))
        XCTAssertTrue(previousHeader.disclosure.performPrimaryAction())

        XCTAssertEqual(table.numberOfRows, 4, "collapse still constructed the hidden file row")
        XCTAssertEqual(
            (table.view(atColumn: 0, row: 3, makeIfNecessary: true)
                as? SessionAttachmentTurnHeaderView)?.sectionID,
            .checkpoint(fixture.previous.id)
        )
    }

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

    private enum AttachmentStressFormat: String, CaseIterable {
        case image
        case pdf
        case html
        case archive
        case document
        case diagram
        case mixed
    }

    private func makeAttachmentStressFiles(
        format: AttachmentStressFormat,
        count: Int
    ) throws -> [URL] {
        try (0..<count).map { index in
            let resolved: AttachmentStressFormat
            if format == .mixed {
                let families: [AttachmentStressFormat] = [
                    .image, .pdf, .html, .archive, .document, .diagram
                ]
                resolved = families[index % families.count]
            } else {
                resolved = format
            }

            switch resolved {
            case .image:
                return try writePNG(
                    named: "stress-\(index).png",
                    size: NSSize(width: 1_600, height: 1_000),
                    color: index.isMultiple(of: 2) ? .systemBlue : .systemOrange
                )
            case .pdf:
                return try writePDF(named: "stress-\(index).pdf", pages: 12)
            case .html:
                let url = root.appendingPathComponent("stress-\(index).html")
                let rows = (0..<300).map {
                    "<tr><td>\($0)</td><td>Attachment preview row \(index)</td></tr>"
                }.joined()
                try Data("<html><body><table>\(rows)</table></body></html>".utf8).write(to: url)
                return url
            case .archive:
                let url = root.appendingPathComponent("stress-\(index).zip")
                var bytes = Data([0x50, 0x4B, 0x05, 0x06])
                bytes.append(Data(repeating: 0, count: 1_024))
                try bytes.write(to: url)
                return url
            case .document:
                let url = root.appendingPathComponent("stress-\(index).rtf")
                let paragraphs = String(
                    repeating: "\\par Attachment document performance row \(index). ",
                    count: 800
                )
                try Data("{\\rtf1\\ansi \(paragraphs)}".utf8).write(to: url)
                return url
            case .diagram:
                let url = root.appendingPathComponent("stress-\(index).mmd")
                let line = "node\(index) --> node\(index + 1)\n"
                let repetitions = max(
                    1,
                    (SessionAttachmentsDefaults.maximumSourcePreviewBytes - 1) / line.utf8.count
                )
                var source = Data(String(repeating: line, count: repetitions).utf8)
                if source.count >= SessionAttachmentsDefaults.maximumSourcePreviewBytes {
                    source = source.prefix(SessionAttachmentsDefaults.maximumSourcePreviewBytes - 1)
                }
                try source.write(to: url)
                return url
            case .mixed:
                preconditionFailure("mixed resolves to a concrete format before file creation")
            }
        }
    }

    private func writePDF(named name: String, pages: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: CGFloat(page % 5) / 8 + 0.2, alpha: 1))
            context.fill(mediaBox.insetBy(dx: 36, dy: 36))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func physicalFootprintBytes() -> UInt64 {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        return ProcessUtility.getResourceUsage(forPid: pid)?.memoryBytes ?? 0
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}
