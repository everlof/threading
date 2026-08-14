import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import Threading

/// Exporting a comparison: the zip writer, the document the recipient opens, and the value the
/// tab freezes into. The point of the feature is that it works on a machine without Threading on
/// it, so most of these assert the *bytes* — an archive a real `unzip` can expand, a page that
/// carries its images rather than referring to files only this Mac has.
final class CompareExportTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ThreadingExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - The zip writer

    func testTheArchiveIsOneRealUnzipCanExpand() throws {
        let document = Data(String(repeating: "<p>hello</p>\n", count: 400).utf8)
        let picture = Self.pngData(width: 8, height: 8, color: .systemRed)

        let archive = try ZipArchive.archive(
            [
                ZipArchive.Entry(path: "index.html", data: document),
                ZipArchive.Entry(path: "old/picture.png", data: picture)
            ],
            modified: Date(timeIntervalSince1970: 1_770_000_000)
        )

        let file = root.appendingPathComponent("export.zip")
        try archive.write(to: file)
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        try Self.unzip(file, into: expanded)

        XCTAssertEqual(
            try Data(contentsOf: expanded.appendingPathComponent("index.html")), document
        )
        XCTAssertEqual(
            try Data(contentsOf: expanded.appendingPathComponent("old/picture.png")), picture
        )
    }

    /// The known vector for the standard reflected CRC-32. A wrong table still writes an archive
    /// — one that every extractor refuses at the end, which is a bug found by the recipient.
    func testTheChecksumMatchesTheStandardVector() {
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipArchive.crc32(Data()), 0)
    }

    func testCompressibleBytesShrinkAndCompressedOnesAreStoredRatherThanGrown() throws {
        let repetitive = Data(String(repeating: "a", count: 20_000).utf8)
        let png = Self.pngData(width: 64, height: 64, color: .systemBlue)

        let text = try ZipArchive.archive(
            [ZipArchive.Entry(path: "a.txt", data: repetitive)], modified: Date()
        )
        let image = try ZipArchive.archive(
            [ZipArchive.Entry(path: "a.png", data: png)], modified: Date()
        )

        // Deflate earns its place on the document…
        XCTAssertLessThan(text.count, repetitive.count / 2)
        // …and is declined on bytes that are already compressed, which it would only enlarge.
        // The overhead is the two headers and the end record, not a failed compression pass.
        XCTAssertGreaterThanOrEqual(image.count, png.count)
        XCTAssertLessThan(image.count - png.count, 200)
    }

    /// A path that climbs out of the folder it is expanded into is the oldest bug this format
    /// has. Nothing builds one today, which is when to prove it cannot be built.
    func testAnEntryPathCannotClimbOutOfTheArchive() {
        XCTAssertEqual(ZipArchive.Entry(path: "../../etc/passwd", data: Data()).path, "etc/passwd")
        XCTAssertEqual(ZipArchive.Entry(path: "/absolute/name", data: Data()).path, "absolute/name")
    }

    // MARK: - The document

    func testTheSinglePageCarriesBothImagesInsteadOfPointingAtThisMac() throws {
        let export = Self.imageExport(
            old: Self.pngData(width: 10, height: 10, color: .systemRed),
            new: Self.pngData(width: 20, height: 20, color: .systemBlue)
        )

        let html = try Self.text(
            of: CompareExportPage.document(for: export, assets: .inline)
        )

        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"))
        XCTAssertFalse(html.contains("old/"), "an inlined page must not refer to archive paths")
        // Every mode the surface has, so the recipient can ask the same questions.
        for mode in ImageCompareMode.allCases {
            XCTAssertTrue(html.contains("data-mode=\"\(mode.rawValue)\""), mode.rawValue)
        }
        // Nothing is fetched: a page that needs a CDN stops working on a plane.
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
    }

    func testThePageOpensOnTheModeTheTabWasLeftIn() throws {
        let export = Self.imageExport(
            old: Self.pngData(width: 4, height: 4, color: .systemRed),
            new: Self.pngData(width: 4, height: 4, color: .systemBlue),
            mode: .difference
        )

        let html = try Self.text(of: CompareExportPage.document(for: export, assets: .inline))

        XCTAssertTrue(html.contains("<html lang=\"\(L10n.preferredLanguages.first ?? "en")\" data-mode=\"difference\""))
        XCTAssertTrue(html.contains("data-mode=\"difference\" aria-pressed=\"true\""))
    }

    /// Both sides fit against the union of the two pixel sizes, so a resized asset stays visibly
    /// resized instead of being normalised into "looks identical" — `ImageCompareLayout`'s rule,
    /// restated in the one language a browser has.
    func testTheTwoSidesShareOneScaleInTheExportedPageToo() throws {
        let export = Self.imageExport(
            old: Self.pngData(width: 50, height: 50, color: .systemRed),
            new: Self.pngData(width: 100, height: 100, color: .systemBlue)
        )

        let html = try Self.text(of: CompareExportPage.document(for: export, assets: .inline))

        XCTAssertTrue(html.contains("--union-width: 100.0000"))
        XCTAssertTrue(html.contains("--image-width: 50.0000%"), "the old side is half the union")
        XCTAssertTrue(html.contains("--image-width: 100.0000%"), "the new side fills it")
    }

    func testATitleCannotLeaveItsElement() throws {
        let export = Self.imageExport(
            old: Self.pngData(width: 4, height: 4, color: .systemRed),
            new: Self.pngData(width: 4, height: 4, color: .systemBlue),
            newTitle: "<script>alert('x')</script>.png"
        )

        let html = try Self.text(of: CompareExportPage.document(for: export, assets: .inline))

        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;.png"))
    }

    func testTheArchivedPageReferencesTheFilesBesideItRatherThanInliningThem() throws {
        let export = Self.imageExport(
            old: Self.pngData(width: 4, height: 4, color: .systemRed),
            new: Self.pngData(width: 4, height: 4, color: .systemBlue)
        )

        let entries = CompareExportPackager.entries(for: export)
        let html = try Self.text(of: XCTUnwrap(entries.first { $0.path == "index.html" }).data)

        XCTAssertEqual(entries.map(\.path), ["index.html", "old/old.png", "new/new.png"])
        XCTAssertTrue(html.contains("src=\"old/old.png\""))
        XCTAssertTrue(html.contains("src=\"new/new.png\""))
        XCTAssertFalse(html.contains("base64"))
    }

    func testATextComparisonExportsItsHunksAndTheSourcesBesideThem() throws {
        let old = try write("a.txt", Data("one\ntwo\nthree\n".utf8))
        let new = try write("b.txt", Data("one\nTWO\nthree\n".utf8))
        guard case .text(let files) = CompareViewController.compare(
            oldPath: old.path, newPath: new.path
        ) else {
            return XCTFail("Differing text files compare as a diff")
        }
        let export = try XCTUnwrap(
            CompareViewController.makeExport(
                .text(files),
                oldPath: old.path,
                newPath: new.path,
                oldTitle: "a.txt",
                newTitle: "b.txt",
                mode: .wipeHorizontal
            )
        )

        let html = try Self.text(of: CompareExportPage.document(for: export, assets: .files))
        // The page is read on someone else's machine: it names the files, and says nothing
        // about where they sat on this one. `git diff --no-index` reports absolute paths.
        XCTAssertFalse(html.contains(root.path), "the export must not carry this Mac's paths")
        XCTAssertTrue(html.contains("class=\"path\">b.txt</span>"))
        XCTAssertTrue(html.contains("class=\"code\">two</td>"))
        XCTAssertTrue(html.contains("class=\"code\">TWO</td>"))
        XCTAssertTrue(html.contains("tr class=\"removed\""))
        XCTAssertTrue(html.contains("tr class=\"added\""))
        // The recipient gets the two files as well as the diff of them.
        XCTAssertEqual(
            CompareExportPackager.entries(for: export).map(\.path),
            ["index.html", "old/a.txt", "new/b.txt"]
        )
    }

    // MARK: - What the tab freezes

    func testAnImagePairFreezesWithItsPixelSizesAndItsBytes() throws {
        let oldData = Self.pngData(width: 12, height: 6, color: .systemRed)
        let newData = Self.pngData(width: 24, height: 12, color: .systemBlue)
        let old = try write("icon.png", oldData)
        let new = try write("icon@2x.png", newData)

        let export = try XCTUnwrap(
            CompareViewController.makeExport(
                CompareViewController.compare(oldPath: old.path, newPath: new.path),
                oldPath: old.path,
                newPath: new.path,
                oldTitle: "icon.png",
                newTitle: "icon@2x.png",
                mode: .fade
            )
        )

        guard case .images(let oldSide, let newSide) = export.body else {
            return XCTFail("Two images freeze as an image comparison")
        }
        XCTAssertEqual(oldSide?.pixelSize, CGSize(width: 12, height: 6))
        XCTAssertEqual(newSide?.pixelSize, CGSize(width: 24, height: 12))
        XCTAssertEqual(oldSide?.mediaType, "image/png")
        // The bytes travel as they are: a PNG pair arrives as the actual files.
        XCTAssertEqual(oldSide?.data, oldData)
        XCTAssertEqual(export.suggestedFileName, "icon-vs-icon@2x")
    }

    /// Safari draws a TIFF and Chrome does not, so a comparison of two would arrive at half the
    /// recipients as two broken image icons — which looks like the files were empty rather than
    /// like the format was wrong.
    func testAnImageBrowsersCannotDrawIsReEncodedRatherThanExportedBroken() throws {
        let tiff = try XCTUnwrap(
            NSImage(data: Self.pngData(width: 8, height: 8, color: .systemGreen))?
                .tiffRepresentation
        )
        let old = try write("shot.tiff", tiff)
        let new = try write("shot2.tiff", tiff)

        let export = try XCTUnwrap(
            CompareViewController.makeExport(
                CompareViewController.compare(oldPath: old.path, newPath: new.path),
                oldPath: old.path,
                newPath: new.path,
                oldTitle: "shot.tiff",
                newTitle: "shot2.tiff",
                mode: .wipeHorizontal
            )
        )

        guard case .images(let oldSide, _) = export.body else {
            return XCTFail("Two images freeze as an image comparison")
        }
        XCTAssertEqual(oldSide?.mediaType, "image/png")
        XCTAssertEqual(oldSide?.fileName, "shot.png")
        XCTAssertEqual(CompareExportImageType.mediaType(of: try XCTUnwrap(oldSide?.data)), "image/png")
    }

    func testThereIsNothingToExportFromAMessage() {
        XCTAssertNil(
            CompareViewController.makeExport(
                .message("The files are identical."),
                oldPath: "/tmp/a", newPath: "/tmp/b",
                oldTitle: "a", newTitle: "b", mode: .fade
            )
        )
    }

    func testTheSuggestedNameSurvivesBeingAnAttachment() {
        XCTAssertEqual(
            Self.imageExport(old: Data(), new: Data(), oldTitle: "a b/c.png", newTitle: "d:e.png")
                .suggestedFileName,
            "a-b-c-vs-d-e"
        )
        // One name is enough when both sides are the same file at two revisions.
        XCTAssertEqual(
            Self.imageExport(old: Data(), new: Data(), oldTitle: "icon.png", newTitle: "icon.png")
                .suggestedFileName,
            "icon"
        )
    }

    // MARK: - Reviewable output

    /// Writes the two documents out so the export can be reviewed the way everything else drawn
    /// in this app is: by looking at it. `THREADING_RENDER_OUT` redirects them beside the PNG
    /// fixtures; without it they land in the temporary directory and are deleted with it.
    ///
    /// The assertions are the same ones the tests above make — this exists for the artefact.
    func testTheExportedPagesAreWrittenWhereTheyCanBeLookedAt() throws {
        // The two sides differ in one place only, which is what makes the sample worth looking
        // at: the wipe has something to reveal and difference has something to answer.
        let images = Self.imageExport(
            old: Self.pngData(
                width: 320, height: 200, color: .systemIndigo,
                mark: NSRect(x: 40, y: 60, width: 80, height: 80)
            ),
            new: Self.pngData(
                width: 320, height: 200, color: .systemIndigo,
                mark: NSRect(x: 200, y: 60, width: 80, height: 80)
            )
        )
        let old = try write("before.txt", Data("one\ntwo\nthree\nfour\n".utf8))
        let new = try write("after.txt", Data("one\nTWO\nthree\nfour\nfive\n".utf8))
        guard case .text(let files) = CompareViewController.compare(
            oldPath: old.path, newPath: new.path
        ) else {
            return XCTFail("Differing text files compare as a diff")
        }
        let text = try XCTUnwrap(
            CompareViewController.makeExport(
                .text(files),
                oldPath: old.path, newPath: new.path,
                oldTitle: "before.txt", newTitle: "after.txt",
                mode: .wipeHorizontal
            )
        )

        let directory = Self.renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imagePage = directory.appendingPathComponent("compare-export-images.html")
        let textPage = directory.appendingPathComponent("compare-export-text.html")
        try CompareExportPage.document(for: images, assets: .inline).write(to: imagePage)
        try CompareExportPage.document(for: text, assets: .inline).write(to: textPage)

        XCTAssertGreaterThan(try Data(contentsOf: imagePage).count, 0)
        XCTAssertGreaterThan(try Data(contentsOf: textPage).count, 0)
    }

    private static var renderDirectory: URL {
        if let out = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            return URL(fileURLWithPath: out, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    // MARK: - The tab's header

    @MainActor
    func testTheTabPutsTheSurfacesOwnControlsInItsHeaderRatherThanCopyingThem() throws {
        let old = try write("one.png", Self.pngData(width: 8, height: 8, color: .systemRed))
        let new = try write("two.png", Self.pngData(width: 8, height: 8, color: .systemBlue))
        let controller = CompareViewController(
            sessionID: SessionID(),
            oldPath: old.path,
            newPath: new.path,
            oldTitle: nil,
            newTitle: nil,
            mode: .wipeHorizontal
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        controller.refresh(force: true)

        let loaded = expectation(description: "compare loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        controller.view.layoutSubtreeIfNeeded()

        let surface = try XCTUnwrap(Self.compareView(in: controller.view))
        XCTAssertFalse(
            surface.carriesControls,
            "the surface gives its row up when a host takes the controls"
        )
        // The chip is the surface's own object, moved — not a second chip driving a copy.
        let chip = try XCTUnwrap(Self.chip(in: controller.view))
        XCTAssertFalse(chip.isDescendant(of: surface))
        XCTAssertTrue(controller.canExportComparison)
    }

    // MARK: - The save panel's accessory

    /// The format row is inside the system panel rather than beside it, so it is built from the
    /// panel's own kind of control. A themed one there could not even open its list — see the
    /// geometry test below.
    @MainActor
    func testTheFormatRowIsBuiltFromTheSystemPanelsOwnControls() throws {
        let session = CompareExportPanel(suggestedName: "Untitled")
        session.configure()

        let accessory = try XCTUnwrap(session.panel.accessoryView)
        XCTAssertTrue(session.chooser.isDescendant(of: accessory))
        XCTAssertEqual(session.chooser.itemTitles, CompareExportFormat.allCases.map(\.title))
        XCTAssertNil(
            Self.themedComponent(in: accessory),
            "an app-owned control inside a save panel's accessory window cannot open its menu"
        )
    }

    @MainActor
    func testChoosingTheArchiveRetypesBothTheNameAndWhatThePanelAccepts() throws {
        let session = CompareExportPanel(suggestedName: "Report")
        session.configure()
        XCTAssertEqual(session.panel.nameFieldStringValue, "Report.html")
        XCTAssertEqual(session.panel.allowedContentTypes, [.html])

        let archive = try XCTUnwrap(CompareExportFormat.allCases.firstIndex(of: .archive))
        session.chooser.selectItem(at: archive)
        XCTAssertTrue(
            NSApp.sendAction(
                try XCTUnwrap(session.chooser.action),
                to: session.chooser.target,
                from: session.chooser
            ),
            "the chooser reaches the session through the target and action it was given"
        )

        XCTAssertEqual(session.format, .archive)
        XCTAssertEqual(session.panel.nameFieldStringValue, "Report.zip")
        XCTAssertEqual(session.panel.allowedContentTypes, [.zip])
    }

    /// The panel opens on the comparison's own name. AppKit hands out a save panel that is
    /// already called Untitled, and the name the export suggested was being dropped on the floor
    /// — every comparison was offered as `Untitled.html`.
    @MainActor
    func testThePanelOpensOnTheNameTheComparisonSuggested() {
        let session = CompareExportPanel(suggestedName: "one-vs-two")
        session.configure()

        XCTAssertEqual(session.panel.nameFieldStringValue, "one-vs-two.html")
    }

    /// A retype takes off the extension this panel wrote, not whatever follows the last dot in
    /// the name the user typed.
    @MainActor
    func testARetypeKeepsADottedNameWhole() throws {
        let session = CompareExportPanel(suggestedName: "one-vs-two")
        session.configure()
        session.panel.nameFieldStringValue = "v1.2.html"

        session.chooseFormat(at: try XCTUnwrap(CompareExportFormat.allCases.firstIndex(of: .archive)))

        XCTAssertEqual(session.panel.nameFieldStringValue, "v1.2.zip")
    }

    /// Why that row cannot be a `ThemedPopUp`: an app-owned dropdown is a view inside its source
    /// window, and AppKit gives an accessory a window exactly as tall as the accessory. Laid out
    /// in that strip the menu has room for none of its rows — what shipped was a two-point sliver
    /// of the panel's own border sitting under the closed control.
    @MainActor
    func testAnAppOwnedDropdownWouldHaveNoRoomInTheAccessoryStrip() throws {
        let session = CompareExportPanel(suggestedName: "Untitled")
        session.configure()
        let accessory = try XCTUnwrap(session.panel.accessoryView)
        accessory.layoutSubtreeIfNeeded()

        let strip = NSRect(origin: .zero, size: accessory.frame.size)
        let control = session.chooser.convert(session.chooser.bounds, to: accessory)
        let entries = CompareExportFormat.allCases.map {
            ThemedMenuEntry.item(ThemedMenuItem(title: $0.title))
        }
        let wanted = NSSize(
            width: ThemedMenuMetrics.width(
                for: entries, minimum: control.width, selectedEntryIndex: 0
            ),
            height: ThemedMenuMetrics.height(for: entries)
        )

        let frame = ThemedMenuLayout.frame(
            anchor: control,
            desiredSize: wanted,
            in: strip,
            flipped: accessory.isFlipped,
            whenClipped: { ThemedMenuMetrics.clippedHeight(for: entries, atMost: $0) }
        )

        XCTAssertTrue(
            strip.contains(frame),
            "the overlay is a view in the window, so the list cannot reach past the strip"
        )
        let firstRow = ThemedMenuMetrics.verticalOuterInset * 2
            + (ThemedMenuMetrics.heights(for: entries).first ?? 0)
        XCTAssertLessThan(frame.height, firstRow, "not even the first row fits in the strip")
    }

    // MARK: - Helpers

    @MainActor
    private static func themedComponent(in view: NSView) -> NSView? {
        if view is ThemedComponent { return view }
        for subview in view.subviews {
            if let found = themedComponent(in: subview) { return found }
        }
        return nil
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func text(of data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private static func imageExport(
        old: Data,
        new: Data,
        oldTitle: String = "old.png",
        newTitle: String = "new.png",
        mode: ImageCompareMode = .wipeHorizontal
    ) -> CompareExport {
        CompareExport(
            oldTitle: oldTitle,
            newTitle: newTitle,
            mode: mode,
            body: .images(
                old: CompareExport.ImageSide(
                    title: oldTitle,
                    fileName: "old.png",
                    data: old,
                    pixelSize: CompareExportImageType.pixelSize(of: old) ?? CGSize(width: 1, height: 1),
                    mediaType: "image/png"
                ),
                new: CompareExport.ImageSide(
                    title: newTitle,
                    fileName: "new.png",
                    data: new,
                    pixelSize: CompareExportImageType.pixelSize(of: new) ?? CGSize(width: 1, height: 1),
                    mediaType: "image/png"
                )
            ),
            exportedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    /// The system's own extractor, which is the only opinion that matters about an archive.
    private static func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archive.path, "-d", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip refused the archive")
    }

    @MainActor
    private static func compareView(in view: NSView) -> ImageCompareView? {
        if let found = view as? ImageCompareView { return found }
        for subview in view.subviews {
            if let found = compareView(in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private static func chip(in view: NSView) -> ChipView? {
        if let found = view as? ChipView { return found }
        for subview in view.subviews {
            if let found = chip(in: subview) { return found }
        }
        return nil
    }

    /// A real picture at an exact pixel size.
    ///
    /// Drawn through a graphics context rather than by `setColor(atX:y:)`, which writes nothing
    /// into a premultiplied rep and silently yields a fully transparent image — invisible to a
    /// test that only classifies the bytes, and very visible in a page exported for review.
    ///
    /// `lockFocus` is not used either: it draws at the screen's backing scale, so a fixture asked
    /// for 12×6 would come back 24×12 on this machine and 12×6 on a build server.
    private static func pngData(
        width: Int,
        height: Int,
        color: NSColor,
        mark: NSRect? = nil
    ) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        if let mark {
            NSColor.white.setFill()
            mark.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
