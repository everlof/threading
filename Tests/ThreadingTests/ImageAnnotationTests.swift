import AppKit
import XCTest
@testable import Threading

/// Marking a picture: the geometry every surface shares, the two views that show the marks, and
/// what the marks become in a report.
///
/// The geometry cases are the point of this file. A mark is made on a preview scaled to fit a
/// column, read again in the fullscreen inspector at 400% with a pan offset, burned into a copy
/// at the file's own pixel size, and quoted as a coordinate in prose — four rectangles for one
/// mark. Everything here is about those four agreeing.
final class ImageAnnotationTests: XCTestCase {

    // MARK: - Geometry

    /// The inspector's canvas is flipped and the report sheet's picture is not. A mark placed
    /// under the wrong assumption lands mirrored across the horizontal, which reads as "roughly
    /// right" until somebody marks a corner.
    @MainActor
    func testAMarkSurvivesTheRoundTripInBothCoordinateSpaces() throws {
        let rect = NSRect(x: 20, y: 40, width: 400, height: 200)
        let annotation = ImageAnnotation(point: CGPoint(x: 0.25, y: 0.75))

        for isFlipped in [true, false] {
            let point = ImageAnnotationGeometry.viewPoint(
                for: annotation,
                in: rect,
                isFlipped: isFlipped
            )
            let back = try XCTUnwrap(ImageAnnotationGeometry.normalizedPoint(
                for: point,
                in: rect,
                isFlipped: isFlipped
            ))
            XCTAssertEqual(back.x, annotation.point.x, accuracy: 0.0001, "flipped: \(isFlipped)")
            XCTAssertEqual(back.y, annotation.point.y, accuracy: 0.0001, "flipped: \(isFlipped)")
        }
    }

    @MainActor
    func testTheTwoSpacesDisagreeAboutTheSameMark() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 100)
        let annotation = ImageAnnotation(point: CGPoint(x: 0.5, y: 0.1))

        let flipped = ImageAnnotationGeometry.viewPoint(for: annotation, in: rect, isFlipped: true)
        let upright = ImageAnnotationGeometry.viewPoint(for: annotation, in: rect, isFlipped: false)

        XCTAssertEqual(flipped.y, 10, accuracy: 0.001, "a flipped view measures down from the top")
        XCTAssertEqual(upright.y, 90, accuracy: 0.001, "an upright view measures up from the bottom")
    }

    @MainActor
    func testAClickOffThePictureMarksNothing() {
        let rect = NSRect(x: 100, y: 100, width: 50, height: 50)
        XCTAssertNil(ImageAnnotationGeometry.normalizedPoint(
            for: NSPoint(x: 10, y: 10),
            in: rect,
            isFlipped: false
        ))
    }

    /// A click a point outside a rectangle whose size was floored by the fitting maths is a
    /// click on the picture as far as the user is concerned; refusing it makes the last row of
    /// pixels unmarkable.
    @MainActor
    func testTheVeryEdgeIsStillThePicture() throws {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 100)
        let point = try XCTUnwrap(ImageAnnotationGeometry.normalizedPoint(
            for: NSPoint(x: 100.5, y: -0.5),
            in: rect,
            isFlipped: true
        ))
        XCTAssertEqual(point.x, 1, accuracy: 0.001)
        XCTAssertEqual(point.y, 0, accuracy: 0.001)
    }

    /// Two pins overlapping is ordinary on a dense screenshot, and the one on top is the one the
    /// pointer is aiming at.
    @MainActor
    func testTheMarkOnTopIsTheMarkYouHit() {
        let rect = NSRect(x: 0, y: 0, width: 200, height: 200)
        let under = ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5))
        let over = ImageAnnotation(point: CGPoint(x: 0.505, y: 0.5))

        let hit = ImageAnnotationGeometry.annotationID(
            at: NSPoint(x: 100, y: 100),
            among: [under, over],
            in: rect,
            isFlipped: true
        )

        XCTAssertEqual(hit, over.id)
    }

    @MainActor
    func testAClickNowhereNearAPinHitsNothing() {
        let rect = NSRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertNil(ImageAnnotationGeometry.annotationID(
            at: NSPoint(x: 10, y: 190),
            among: [ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5))],
            in: rect,
            isFlipped: true
        ))
    }

    // MARK: - Prose

    /// Both halves are load-bearing: the flattened picture shows *where*, and the coordinate lets
    /// a reader measuring the PNG land on the same spot without eyeballing a disc.
    @MainActor
    func testEachMarkIsQuotedInThePicturesOwnPixels() {
        let lines = ImageAnnotationSummary.lines(
            [
                ImageAnnotation(point: CGPoint(x: 0.5, y: 0.25), note: "too tight"),
                ImageAnnotation(point: CGPoint(x: 0, y: 1))
            ],
            imageSize: NSSize(width: 2560, height: 1440)
        )

        XCTAssertEqual(lines.first, "1 at (1280, 360) — too tight")
        XCTAssertEqual(lines.last, "2 at (0, 1440)", "a mark with no note is still a statement")
    }

    @MainActor
    func testNoMarksMeansNoSection() {
        XCTAssertNil(ImageAnnotationSummary.section([], imageSize: NSSize(width: 10, height: 10)))
    }

    // MARK: - Flattening

    @MainActor
    func testNothingMarkedLeavesTheOriginalUntouched() {
        let image = swatch()
        XCTAssertTrue(
            ImageAnnotationFlattening.flattened(image, annotations: []) === image,
            "an unmarked capture was re-encoded for nothing"
        )
    }

    @MainActor
    func testAFlattenedCopyKeepsTheFilesOwnSizeAndDrawsTheMarks() throws {
        let image = swatch()
        let flattened = try XCTUnwrap(ImageAnnotationFlattening.flattened(
            image,
            annotations: [ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5))]
        ))

        XCTAssertFalse(flattened === image, "the original was drawn on")
        XCTAssertEqual(flattened.size, image.size, "the copy is not the file's own size")

        let before = try XCTUnwrap(colour(of: image, atUnit: CGPoint(x: 0.5, y: 0.5)))
        let after = try XCTUnwrap(colour(of: flattened, atUnit: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertNotEqual(
            before.description,
            after.description,
            "nothing was drawn where the mark was put"
        )
    }

    @MainActor
    func testTheFlattenedCopyIsNamedAfterTheOriginal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-flatten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try XCTUnwrap(ImageAnnotationFlattening.writeFlattenedPNG(
            swatch(),
            annotations: [ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5))],
            basedOn: URL(fileURLWithPath: "/tmp/Screenshot 2026-08-14.png"),
            directory: directory
        ))

        XCTAssertEqual(url.lastPathComponent, "Screenshot 2026-08-14-annotated.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - The Picture

    /// A click on bare picture marks it; a click on an existing pin selects that one instead.
    /// Marking the same control twice used to stack two discs at one place, leaving a rail with
    /// two fields nobody could tell apart.
    @MainActor
    func testAClickMarksThePictureAndAClickOnAMarkSelectsIt() {
        let view = AnnotatedImageView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.image = swatch()

        var added: [CGPoint] = []
        var selected: [ImageAnnotation.ID?] = []
        view.onAddAnnotation = { added.append($0) }
        view.onSelectAnnotation = { selected.append($0) }

        let centre = NSPoint(x: view.imageRect.midX, y: view.imageRect.midY)
        view.mouseDown(with: click(at: centre, in: view))
        XCTAssertEqual(added.count, 1, "a click on the picture did not mark it")

        let annotation = ImageAnnotation(point: try! XCTUnwrap(added.first))
        view.annotations = [annotation]
        view.mouseDown(with: click(at: centre, in: view))

        XCTAssertEqual(added.count, 1, "a click on an existing mark stacked a second one")
        XCTAssertEqual(selected.last, annotation.id)
        XCTAssertEqual(view.selectedAnnotationID, annotation.id)
    }

    @MainActor
    func testAnAnnotationThatGoesAwayTakesTheSelectionWithIt() {
        let view = AnnotatedImageView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.image = swatch()
        let annotation = ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5))
        view.annotations = [annotation]
        view.selectedAnnotationID = annotation.id

        view.annotations = []

        XCTAssertNil(view.selectedAnnotationID, "a removed mark stayed selected")
    }

    // MARK: - The Rail

    @MainActor
    func testTheRailStatesOneFieldPerMarkAndReportsWhatIsTypedInIt() throws {
        let rail = ImageAnnotationRailView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let first = ImageAnnotation(point: .zero, note: "one")
        let second = ImageAnnotation(point: .zero)
        rail.setAnnotations([first, second])

        let fields = allSubviews(of: rail).compactMap { $0 as? ThemedTextField }
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first?.stringValue, "one")

        var reported: [(ImageAnnotation.ID, String)] = []
        rail.onNoteChange = { reported.append(($0, $1)) }

        let field = try XCTUnwrap(fields.last)
        field.stringValue = "two"
        rail.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: field
        ))

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.0, second.id)
        XCTAssertEqual(reported.first?.1, "two")
    }

    /// Rebuilding the rail on every keystroke would take the caret away mid-word. The rows are
    /// rebuilt only when the *list* changes.
    @MainActor
    func testTypingDoesNotRebuildTheRowYouAreTypingIn() {
        let rail = ImageAnnotationRailView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let annotation = ImageAnnotation(point: .zero)
        rail.setAnnotations([annotation])

        let before = allSubviews(of: rail).compactMap { $0 as? ThemedTextField }.first
        rail.setAnnotations([ImageAnnotation(id: annotation.id, point: .zero, note: "typed")])
        let after = allSubviews(of: rail).compactMap { $0 as? ThemedTextField }.first

        XCTAssertTrue(before === after, "the field was rebuilt under the caret")
        XCTAssertEqual(after?.stringValue, "typed")
    }

    /// A reopened document used to grow its zero-height scroll document downward, leaving every
    /// row below the viewport until collection navigation forced another layout pass.
    @MainActor
    func testSeveralSavedAnnotationsAreVisibleOnTheFirstLayoutPass() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
        let pane = ImageAnnotationPaneView(frame: .zero)
        host.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: host.topAnchor),
            pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        pane.setAnnotations(
            (0..<4).map { index in
                ImageAnnotation(point: .zero, note: "note \(index)")
            },
            sharingState: .local,
            showsChatActions: true,
            canShare: true
        )

        host.layoutSubtreeIfNeeded()

        let scroll = try XCTUnwrap(
            allSubviews(of: pane).compactMap { $0 as? NSScrollView }.first
        )
        let fields = allSubviews(of: pane).compactMap { $0 as? ThemedTextField }
        XCTAssertEqual(fields.count, 4)
        for field in fields {
            let frameInClip = field.convert(field.bounds, to: scroll.contentView)
            XCTAssertTrue(
                scroll.contentView.bounds.intersects(frameInClip),
                "a saved annotation began outside the initial viewport: \(frameInClip); "
                    + "clip: \(scroll.contentView.bounds); document: \(scroll.documentView?.frame ?? .zero)"
            )
        }
    }

    // MARK: - Live Theme Switch

    /// An assigned `textColor` freezes onto a label exactly as a `CGColor` freezes onto a layer,
    /// and the sweep re-resolves a recorded font role rather than an assigned ink. Both halves of
    /// this rail assign something, so both are held to repainting when the theme moves.
    @MainActor
    func testTheRailAndItsBadgesFollowALiveThemeSwitch() throws {
        defer { AppThemePalette.set(.system) }

        let rail = ImageAnnotationRailView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
        rail.setAnnotations([ImageAnnotation(point: .zero, note: "one")])
        rail.layoutSubtreeIfNeeded()

        AppThemePalette.set(.system)
        AppThemeRefresh.repaint(rail)
        let before = try XCTUnwrap(render(rail))

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        AppThemeRefresh.repaint(rail)
        let after = try XCTUnwrap(render(rail))

        XCTAssertNotEqual(before, after, "the rail kept the palette it was built under")
    }

    @MainActor
    private func render(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - The Report

    @MainActor
    func testAMarkedReportCarriesItsMarksAndTheCapCannotBePassed() {
        let sheet = makeSheet()
        sheet.loadView()

        sheet.applyAnnotations([
            ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5), note: "here")
        ])

        XCTAssertTrue(sheet.details.contains("## Annotations"), sheet.details)
        XCTAssertTrue(sheet.details.contains("1 at (320, 200) — here"), sheet.details)

        sheet.applyAnnotations((0..<ImageAnnotationDefaults.maximumCount).map { index in
            ImageAnnotation(point: CGPoint(x: 0.5, y: Double(index) / 100))
        })
        XCTAssertEqual(sheet.annotations.count, ImageAnnotationDefaults.maximumCount)
    }

    /// The private report's preview is the only picture it carries, and one showing none of the
    /// marks its own text refers to would leave a reader looking for a pin that is not there.
    @MainActor
    func testThePrivateReportsPictureCarriesTheMarks() throws {
        let sheet = makeSheet()
        sheet.loadView()
        let bare = try XCTUnwrap(sheet.annotatedScreenshot)

        sheet.applyAnnotations([ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5))])
        let marked = try XCTUnwrap(sheet.annotatedScreenshot)

        XCTAssertNotEqual(
            colour(of: bare, atUnit: CGPoint(x: 0.5, y: 0.5))?.description,
            colour(of: marked, atUnit: CGPoint(x: 0.5, y: 0.5))?.description,
            "the filed picture shows no mark"
        )
    }

    // MARK: - Fixture

    @MainActor
    private func makeSheet() -> InspectorReportViewController {
        InspectorReportViewController(
            heading: InspectorStrings.elementHeading,
            subheading: "UsageReadingLabel",
            markdown: "- Element: UsageReadingLabel",
            environment: "- Threading 1.0 (1)",
            screenshot: swatch()
        )
    }

    @MainActor
    private func swatch() -> NSImage {
        let image = NSImage(size: NSSize(width: 640, height: 400))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        image.unlockFocus()
        return image
    }

    /// Reads one pixel, in unit coordinates from the top-left, through a bitmap of the image.
    @MainActor
    private func colour(of image: NSImage, atUnit point: CGPoint) -> NSColor? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let x = Int((CGFloat(bitmap.pixelsWide - 1) * point.x).rounded())
        let y = Int((CGFloat(bitmap.pixelsHigh - 1) * point.y).rounded())
        return bitmap.colorAt(x: x, y: y)
    }

    @MainActor
    private func click(at point: NSPoint, in view: NSView) -> NSEvent {
        // Built against the view's own window-space so `convert(_:from: nil)` lands where the
        // test means. A detached fixture's window space is its bounds.
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func allSubviews(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { allSubviews(of: $0) }
    }
}
