import AppKit
import XCTest
@testable import Threading

/// Behaviour, accessibility, theme-boundary, live-theme, and rendered-state coverage for the
/// app-owned replacement for the floating Quick Look workflow.
@MainActor
final class MediaInspectorTests: XCTestCase {

    func testCanvasBeginsFittedAndTogglesToActualSize() {
        let canvas = MediaInspectorCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        canvas.configure(
            image: solidImage(size: NSSize(width: 800, height: 400), color: .systemTeal),
            title: "wide.png"
        )

        XCTAssertEqual(canvas.zoomMode, .fit)
        XCTAssertEqual(canvas.fitScale, 0.4, accuracy: 0.001)
        XCTAssertEqual(canvas.imageRect.size, NSSize(width: 320, height: 160))

        canvas.toggleFitAndActualSize()
        XCTAssertEqual(canvas.zoomMode, .actualSize)
        XCTAssertEqual(canvas.displayedScale, 1)
        XCTAssertEqual(canvas.imageRect.size, NSSize(width: 800, height: 400))

        canvas.toggleFitAndActualSize()
        XCTAssertEqual(canvas.zoomMode, .fit)
        XCTAssertEqual(canvas.panOffset, .zero)
    }

    func testCanvasZoomAnchorsAndPanCannotLoseTheImage() {
        let canvas = MediaInspectorCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        canvas.configure(
            image: solidImage(size: NSSize(width: 800, height: 400), color: .systemOrange),
            title: "large.png"
        )
        canvas.showActualSize()
        canvas.pan(by: NSPoint(x: 10_000, y: -10_000))

        XCTAssertEqual(canvas.panOffset.x, 220, accuracy: 0.001)
        XCTAssertEqual(canvas.panOffset.y, -120, accuracy: 0.001)

        canvas.zoomOut()
        XCTAssertEqual(canvas.zoomMode, .custom)
        XCTAssertEqual(canvas.displayedScale, 0.8, accuracy: 0.001)
        XCTAssertEqual(canvas.panOffset.x, 140, accuracy: 0.001)
        XCTAssertEqual(canvas.panOffset.y, -80, accuracy: 0.001)
    }

    func testCanvasExposesZoomToAccessibility() {
        let canvas = MediaInspectorCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.configure(
            image: solidImage(size: NSSize(width: 800, height: 600), color: .systemPurple),
            title: "accessible.png"
        )

        XCTAssertEqual(canvas.accessibilityRole(), .image)
        XCTAssertEqual(canvas.accessibilityLabel(), "accessible.png")
        XCTAssertNotNil(canvas.accessibilityHelp())
        let before = canvas.displayedScale
        XCTAssertTrue(canvas.accessibilityPerformIncrement())
        XCTAssertGreaterThan(canvas.displayedScale, before)
        XCTAssertTrue(canvas.accessibilityPerformDecrement())
        XCTAssertTrue(canvas.accessibilityPerformPress())
        XCTAssertEqual(canvas.zoomMode, .fit)
    }

    func testEscapeDismissesFromTheSurfaceAndItsPreferredCanvas() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let inspector = MediaInspectorView(items: fixture.items, selectedIndex: 0)
        inspector.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        inspector.layoutSubtreeIfNeeded()
        XCTAssertFalse(inspector.showsCollectionRail)
        XCTAssertEqual(inspector.collectionThumbnailCount, 0)
        let escape = try keyEvent("\u{1b}", keyCode: 53)
        var dismissals = 0
        inspector.onDismiss = { dismissals += 1 }

        XCTAssertTrue(inspector.performKeyEquivalent(with: escape))
        XCTAssertEqual(dismissals, 1)

        let canvas = try XCTUnwrap(
            descendants(of: inspector).compactMap { $0 as? MediaInspectorCanvas }.first
        )
        canvas.keyDown(with: escape)
        XCTAssertEqual(dismissals, 2)
    }

    func testVisibleImageSourceHasHoverFeedbackAndAccessibleActivation() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preview = ThemedImagePreview(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
        preview.image = fixture.items[0].image
        preview.fileURL = fixture.items[0].url
        let resting = try XCTUnwrap(render(preview))

        preview.mouseEntered(with: try crossingEvent(type: .mouseEntered))
        let hovered = try XCTUnwrap(render(preview))

        XCTAssertTrue(preview.isHovered)
        XCTAssertNotEqual(resting, hovered, "the clickable image gave no visual hover response")
        XCTAssertEqual(preview.accessibilityRole(), .image)
        XCTAssertNotNil(preview.accessibilityHelp())

        preview.mouseExited(with: try crossingEvent(type: .mouseExited))
        XCTAssertFalse(preview.isHovered)
    }

    /// A picture drawn flush inside a panel is clipped by the panel's corner, so the silhouette it
    /// draws has to *be* that corner.
    ///
    /// Rounding it at `control` inside a `panel` clip put an 8pt shape inside a 12pt one, and the
    /// clip took away the two corners the picture was flush with outright: the hover ring lost its
    /// top-left and its top-right arc — both straight edges fading out over twelve points into
    /// nothing — while the two bottom corners, sitting in the middle of the host where nothing
    /// clips them, drew perfectly. Asserted on the geometry rather than on pixels because the clip
    /// is a *layer* corner, and `cacheDisplay` renders the view tree without one.
    func testPictureFillingAPanelIsRoundedByThePanelThatClipsIt() {
        let host = panelHost(radius: .panel)
        let preview = installedPreview(in: host)

        // Far wider than it is tall, so fitting it across the width leaves it flush against the
        // host's two top corners — which is exactly where the clip is.
        preview.image = solidImage(size: NSSize(width: 1200, height: 400), color: .systemIndigo)
        host.layoutSubtreeIfNeeded()

        // A panel with no corner of its own clips nothing, so the picture keeps its own.
        let clipped = Design.Radius.panel > 0 ? Design.Radius.panel : Design.Radius.control
        XCTAssertEqual(preview.imageRect.width, preview.bounds.width, accuracy: 1)
        XCTAssertEqual(
            preview.silhouetteRadius(for: preview.imageRect),
            clipped,
            "a picture flush inside a panel drew a corner the panel's clip cuts away"
        )

        // A picture the panel does not reach is a smaller thing nested inside it, and keeps the
        // nested corner it has always had.
        preview.image = solidImage(size: NSSize(width: 80, height: 60), color: .systemIndigo)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThan(preview.imageRect.width, preview.bounds.width)
        XCTAssertEqual(preview.silhouetteRadius(for: preview.imageRect), Design.Radius.control)
    }

    /// The display panel hosts its image on a square surface. Nothing clips the picture there, so
    /// nothing should have widened its corner either.
    func testPictureInASquareHostKeepsTheNestedCorner() {
        let host = panelHost(radius: .fixed(0))
        let preview = installedPreview(in: host)
        preview.image = solidImage(size: NSSize(width: 1200, height: 400), color: .systemIndigo)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(preview.imageRect.width, preview.bounds.width, accuracy: 1)
        XCTAssertEqual(preview.silhouetteRadius(for: preview.imageRect), Design.Radius.control)
    }

    func testCollectionNavigationAndThumbnailRailShareSelection() throws {
        let fixture = try imageFiles(count: 3)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let inspector = MediaInspectorView(items: fixture.items, selectedIndex: 0)
        inspector.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertTrue(inspector.showsCollectionRail)
        XCTAssertEqual(inspector.selectedIndex, 0)
        inspector.move(by: -1)
        XCTAssertEqual(inspector.selectedIndex, 0, "navigation should stop at the first item")
        inspector.move(by: 1)
        XCTAssertEqual(inspector.selectedIndex, 1)
        inspector.move(by: 1)
        XCTAssertEqual(inspector.selectedIndex, 2)
        inspector.move(by: 1)
        XCTAssertEqual(inspector.selectedIndex, 2, "navigation should stop at the last item")

        let thumbnailRoles = descendants(of: inspector).filter {
            $0.accessibilityRole() == .radioButton
        }
        XCTAssertGreaterThanOrEqual(thumbnailRoles.count, 3)

        inspector.move(by: -2)
        thumbnailRoles[0].keyDown(with: try keyEvent(
            String(UnicodeScalar(NSRightArrowFunctionKey)!),
            keyCode: 124
        ))
        XCTAssertEqual(inspector.selectedIndex, 1, "radio-style arrow navigation did not move")
    }

    /// A long filmstrip must arrive at its settled geometry. Selecting a thumbnail may change
    /// which item is visible, but it must not be the first event that lays the strip out.
    func testLongCollectionRailDoesNotMoveOnFirstSelection() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let image = try XCTUnwrap(fixture.items.first?.image)
        let items = (0..<27).map { index in
            MediaInspectorItem(
                url: fixture.items[0].url,
                title: "Frame \(index + 1).png",
                image: image
            )
        }

        let root = ThemedSurfaceView()
        root.frame = NSRect(x: 0, y: 0, width: 1_960, height: 1_040)
        root.translatesAutoresizingMaskIntoConstraints = true
        let source = ThemedImagePreview(frame: NSRect(x: 20, y: 20, width: 200, height: 160))
        source.translatesAutoresizingMaskIntoConstraints = true
        source.image = image
        source.fileURL = items[0].url
        source.inspectorSelectionProvider = {
            MediaInspectorSelection(items: items, selectedIndex: 0)
        }
        root.addSubview(source)

        let window = fullSizeContentWindow(hosting: root)
        defer { MediaInspectorPresenter.dismiss(in: window) }
        XCTAssertTrue(source.performPrimaryAction())
        root.layoutSubtreeIfNeeded()

        let inspector = try XCTUnwrap(
            root.subviews.compactMap { $0 as? MediaInspectorView }.first
        )
        let thumbnailLabels = Set(items.map(\.title))
        let thumbnails = descendants(of: inspector)
            .filter {
                $0.accessibilityRole() == .radioButton
                    && thumbnailLabels.contains($0.accessibilityLabel() ?? "")
            }
            .sorted { inspector.convert($0.frame, from: $0.superview).minX
                < inspector.convert($1.frame, from: $1.superview).minX }
        XCTAssertEqual(thumbnails.count, items.count)
        let firstThumbnail = try XCTUnwrap(thumbnails.first)
        let before = thumbnails.map { inspector.convert($0.frame, from: $0.superview) }
        for frame in before {
            XCTAssertEqual(
                frame.width,
                Design.Size.mediaInspectorThumbnail,
                accuracy: 0.5,
                "the first layout compressed a fixed-size thumbnail"
            )
            XCTAssertEqual(
                frame.height,
                Design.Size.mediaInspectorThumbnail,
                accuracy: 0.5,
                "the first layout compressed a fixed-size thumbnail"
            )
        }
        for (leading, trailing) in zip(before, before.dropFirst()) {
            XCTAssertEqual(
                trailing.minX - leading.maxX,
                Design.Spacing.small,
                accuracy: 0.5,
                "the first layout did not preserve the filmstrip spacing"
            )
        }

        XCTAssertTrue(firstThumbnail.accessibilityPerformPress())
        root.layoutSubtreeIfNeeded()
        let after = thumbnails.map { inspector.convert($0.frame, from: $0.superview) }

        XCTAssertEqual(before, after, "the first selection settled stale thumbnail frames")
    }

    /// The filmstrip is part of the inspector, including the spacing between its thumbnails.
    /// Only the dimmed ground *outside* the surface is a dismissal target; a transparent gap in
    /// a child view must not turn into a hole through to that ground.
    func testClickingBetweenCollectionThumbnailsKeepsTheInspectorOpen() throws {
        let fixture = try imageFiles(count: 3)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let root = ThemedSurfaceView()
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        root.translatesAutoresizingMaskIntoConstraints = true
        let source = ThemedImagePreview(frame: NSRect(x: 20, y: 20, width: 200, height: 160))
        source.translatesAutoresizingMaskIntoConstraints = true
        source.image = fixture.items[0].image
        source.fileURL = fixture.items[0].url
        source.inspectorSelectionProvider = {
            MediaInspectorSelection(items: fixture.items, selectedIndex: 0)
        }
        root.addSubview(source)

        let window = fullSizeContentWindow(hosting: root)
        defer { MediaInspectorPresenter.dismiss(in: window) }
        XCTAssertTrue(source.performPrimaryAction())
        root.layoutSubtreeIfNeeded()

        let inspector = try XCTUnwrap(
            root.subviews.compactMap { $0 as? MediaInspectorView }.first
        )
        let thumbnailLabels = Set(fixture.items.map(\.title))
        let thumbnails = descendants(of: inspector)
            .filter {
                $0.accessibilityRole() == .radioButton
                    && thumbnailLabels.contains($0.accessibilityLabel() ?? "")
            }
            .sorted { inspector.convert($0.frame, from: $0.superview).minX
                < inspector.convert($1.frame, from: $1.superview).minX }
        XCTAssertEqual(thumbnails.count, 3)

        let first = inspector.convert(thumbnails[0].frame, from: thumbnails[0].superview)
        let second = inspector.convert(thumbnails[1].frame, from: thumbnails[1].superview)
        let gap = NSPoint(x: (first.maxX + second.minX) / 2, y: first.midY)
        let inWindow = inspector.convert(gap, to: nil)
        let target = try XCTUnwrap(root.hitTest(inWindow))
        let scrim = try XCTUnwrap(scrims(in: root).first)

        XCTAssertFalse(
            target.identifier == InWindowOverlay.scrimIdentifier,
            "the filmstrip gutter hit the dismissal scrim"
        )
        // Exercise the backstop as well as the ordinary hit test. The running app reported this
        // exact transparent child gap reaching the sibling scrim underneath; the scrim still has
        // to distinguish a point geometrically inside its covering surface from outside ground.
        scrim.mouseDown(with: try mouseEvent(.leftMouseDown, at: gap, in: inspector))

        XCTAssertTrue(
            MediaInspectorPresenter.isPresenting(in: window),
            "an inert filmstrip gutter dismissed the inspector"
        )
    }

    func testPresentationIsInWindowRestoresFocusAndReplacesItself() throws {
        let fixture = try imageFiles(count: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let root = ThemedSurfaceView()
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        root.translatesAutoresizingMaskIntoConstraints = true
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        let source = ThemedImagePreview(frame: NSRect(x: 20, y: 20, width: 200, height: 160))
        source.translatesAutoresizingMaskIntoConstraints = true
        source.image = fixture.items[0].image
        source.fileURL = fixture.items[0].url
        source.inspectorSelectionProvider = {
            MediaInspectorSelection(items: fixture.items, selectedIndex: 0)
        }
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeFirstResponder(source)

        XCTAssertTrue(source.performPrimaryAction())
        XCTAssertTrue(MediaInspectorPresenter.isPresenting(in: window))
        XCTAssertEqual(root.subviews.compactMap { $0 as? MediaInspectorView }.count, 1)
        XCTAssertEqual(scrims(in: root).count, 1)
        XCTAssertTrue(source.performPrimaryAction())
        XCTAssertEqual(
            root.subviews.compactMap { $0 as? MediaInspectorView }.count,
            1,
            "a second activation should replace, not stack, the inspector"
        )
        XCTAssertEqual(
            scrims(in: root).count,
            1,
            "a second activation left the first presentation's wash behind"
        )
        XCTAssertTrue(ThemeBoundaryAudit.violations(in: root).isEmpty)

        MediaInspectorPresenter.dismiss(in: window)
        XCTAssertFalse(MediaInspectorPresenter.isPresenting(in: window))
        XCTAssertTrue(window.firstResponder === source)
        XCTAssertEqual(
            root.subviews.compactMap { $0 as? MediaInspectorView }.count,
            0,
            "closing left the surface in the window"
        )
        XCTAssertEqual(scrims(in: root).count, 0, "closing left the window dimmed")
    }

    /// The window behind a covering surface has to *be* behind it.
    ///
    /// The app's own header band — session tabs, panel toggles, the sidebar's top corner — is the
    /// one part of the window a full-height inspector does not cover, because the surface stops
    /// below the strip the traffic lights float over. Left lit it stacked directly on the
    /// inspector's own header with a hairline between them, and a picture of the running app read
    /// as two rows of one window's chrome rather than as something opened in front of it. The wash
    /// therefore takes the *whole* content view while the surface keeps its own, smaller, area.
    func testTheDimmingWashCoversTheWholeContentViewUnderTheSurface() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
        let source = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 90))
        root.addSubview(source)
        let window = fullSizeContentWindow(hosting: root)
        defer { MediaInspectorPresenter.dismiss(in: window) }

        XCTAssertTrue(MediaInspectorPresenter.present(fixture.items[0], from: source))
        root.layoutSubtreeIfNeeded()

        let scrim = try XCTUnwrap(
            scrims(in: root).first, "the inspector opened with nothing behind it"
        )
        let inspector = try XCTUnwrap(root.subviews.compactMap { $0 as? MediaInspectorView }.first)

        XCTAssertEqual(scrim.frame, root.bounds, "the wash left part of the window lit")
        XCTAssertGreaterThan(
            scrim.frame.maxY,
            inspector.frame.maxY,
            "the wash stopped where the surface does, which leaves the band above it lit"
        )
        XCTAssertLessThan(
            try XCTUnwrap(root.subviews.firstIndex(of: scrim)),
            try XCTUnwrap(root.subviews.firstIndex(of: inspector)),
            "the wash was ordered over the surface it is meant to be under"
        )
        XCTAssertTrue(ThemeBoundaryAudit.violations(in: root).isEmpty)
    }

    /// The dimmed ground is a way out, the way it is in every other app: the same dismissal the
    /// close button and Escape run, focus included.
    func testClickingTheDimmedGroundClosesTheInspectorAndRestoresFocus() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let root = ThemedSurfaceView()
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        root.translatesAutoresizingMaskIntoConstraints = true
        let source = ThemedImagePreview(frame: NSRect(x: 20, y: 20, width: 200, height: 160))
        source.translatesAutoresizingMaskIntoConstraints = true
        source.image = fixture.items[0].image
        source.fileURL = fixture.items[0].url
        root.addSubview(source)

        let window = fullSizeContentWindow(hosting: root)
        window.makeFirstResponder(source)
        defer { MediaInspectorPresenter.dismiss(in: window) }

        XCTAssertTrue(source.performPrimaryAction())
        let scrim = try XCTUnwrap(scrims(in: root).first)
        let inspector = try XCTUnwrap(
            root.subviews.compactMap { $0 as? MediaInspectorView }.first
        )
        root.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scrim.frame.maxY, inspector.frame.maxY)
        let outsideSurface = NSPoint(
            x: scrim.frame.midX,
            y: (scrim.frame.maxY + inspector.frame.maxY) / 2
        )

        scrim.mouseDown(with: try mouseEvent(
            .leftMouseDown,
            at: outsideSurface,
            in: root
        ))

        XCTAssertFalse(MediaInspectorPresenter.isPresenting(in: window))
        XCTAssertTrue(
            window.firstResponder === source,
            "closing from the ground did not hand focus back to the source"
        )
        XCTAssertTrue(scrims(in: root).isEmpty, "the wash outlived the surface it dimmed for")
    }

    /// The canvas is made first responder the instant the inspector opens — the arrow keys, the
    /// zoom keys and Escape all belong there — and it fills the surface, so an unconditional focus
    /// ring drew an accent rectangle around the whole window before the user had done anything.
    /// Keyboard traversal still shows it, because that is the one case it says something.
    func testTheCanvasDrawsNoFocusRingUntilFocusArrivesFromTheKeyboard() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
        let source = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 90))
        root.addSubview(source)
        let window = fullSizeContentWindow(hosting: root)
        defer { MediaInspectorPresenter.dismiss(in: window) }

        XCTAssertTrue(MediaInspectorPresenter.present(fixture.items[0], from: source))
        root.layoutSubtreeIfNeeded()

        let inspector = try XCTUnwrap(root.subviews.compactMap { $0 as? MediaInspectorView }.first)
        let canvas = try XCTUnwrap(
            descendants(of: inspector).compactMap { $0 as? MediaInspectorCanvas }.first
        )

        XCTAssertTrue(
            window.firstResponder === canvas, "the inspector did not open holding the picture"
        )
        XCTAssertFalse(
            canvas.showsKeyboardFocusRing, "opening the inspector outlined the entire picture"
        )
        let quiet = try XCTUnwrap(render(canvas))

        canvas.focusArrived(from: try keyEvent("\t", keyCode: 48))
        XCTAssertTrue(
            canvas.showsKeyboardFocusRing, "keyboard traversal left focus with nothing to see"
        )
        XCTAssertNotEqual(
            quiet, try XCTUnwrap(render(canvas)), "the ring never reached the pixels"
        )

        // Every key the canvas owns keeps working either way — the ring is a decision about
        // drawing, not about who is handling the keys.
        canvas.keyDown(with: try keyEvent("z", keyCode: 6))
        XCTAssertEqual(canvas.zoomMode, .actualSize)
        canvas.keyDown(with: try keyEvent("z", keyCode: 6))
        XCTAssertEqual(canvas.zoomMode, .fit)
    }

    /// The header opened *under* the traffic lights: the window draws its content full-size
    /// beneath a transparent titlebar, and the inspector pinned itself to that view's own top.
    /// The strip is the platform's, so the surface clears it by the safe area rather than by a
    /// measurement anyone here would have to keep.
    func testTheInspectorOpensBelowTheWindowsTitlebarStrip() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
        let source = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 90))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.contentView = root
        defer { MediaInspectorPresenter.dismiss(in: window) }

        XCTAssertTrue(MediaInspectorPresenter.present(fixture.items[0], from: source))
        root.layoutSubtreeIfNeeded()

        let inspector = try XCTUnwrap(root.subviews.compactMap { $0 as? MediaInspectorView }.first)
        XCTAssertGreaterThan(
            root.safeAreaInsets.top, 0, "the fixture window has no titlebar strip to clear"
        )
        XCTAssertEqual(
            inspector.frame.maxY,
            root.bounds.maxY - root.safeAreaInsets.top,
            accuracy: 1,
            "the inspector's header opened under the window's own buttons"
        )
    }

    func testDocumentRendererNamesAndContainsItsSystemChrome() {
        let document = MediaInspectorDocumentView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        document.layoutSubtreeIfNeeded()

        XCTAssertFalse(document.hasPDFRendererForTesting)
        XCTAssertFalse(document.hasQuickLookRendererForTesting)
        XCTAssertTrue(document.subviews.isEmpty, "an unused document host eagerly built a renderer")
        XCTAssertTrue(document.subviews.allSatisfy { document.permitsSystemChrome($0) })
        XCTAssertTrue(ThemeBoundaryAudit.violations(in: document).isEmpty)
    }

    /// The crash of 2026-08-13, as a test. Quick Look closes a `QLPreviewView` with the window it
    /// is in, and setting an item on a closed one aborts the process — so a document view that
    /// outlives a window (the Attachments tab detached into its own window, then closed, which
    /// hands the same controller back to the display panel) must not keep its renderer.
    func testAClosedWindowLeavesTheDocumentViewAbleToPreviewAgain() throws {
        let file = try documentFile(named: "notes.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let window = quickLookFixtureWindow()
        let document = MediaInspectorDocumentView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView?.addSubview(document)

        XCTAssertTrue(document.display(file))
        XCTAssertTrue(document.hasQuickLookRendererForTesting)

        window.close()
        XCTAssertFalse(
            document.hasQuickLookRendererForTesting,
            "a renderer Quick Look closed with its window was kept for the next document"
        )

        // The line that used to abort: the same view, asked for the same file, after the window
        // that owned its renderer went away.
        XCTAssertTrue(document.display(file))
        XCTAssertTrue(document.hasQuickLookRendererForTesting)
    }

    /// The move production actually makes: a tab's controller is unparented and installed
    /// somewhere else, which takes its renderer with it. The document has to survive that on its
    /// own — nothing re-runs the pane's preview for a tab that merely came back.
    func testADocumentViewCarriesItsPreviewBetweenWindows() throws {
        let file = try documentFile(named: "handover.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let document = MediaInspectorDocumentView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let first = quickLookFixtureWindow()
        first.contentView?.addSubview(document)

        XCTAssertTrue(document.display(file))
        XCTAssertTrue(document.hasQuickLookRendererForTesting)

        document.removeFromSuperview()
        XCTAssertFalse(
            document.hasQuickLookRendererForTesting,
            "a renderer outlived the window it was built in"
        )

        let second = quickLookFixtureWindow()
        second.contentView?.addSubview(document)
        XCTAssertTrue(
            document.hasQuickLookRendererForTesting,
            "a document view that changed windows came back with an empty preview"
        )
        XCTAssertTrue(document.subviews.allSatisfy { document.permitsSystemChrome($0) })

        document.clear()
        document.removeFromSuperview()
        first.contentView?.addSubview(document)
        XCTAssertFalse(
            document.hasQuickLookRendererForTesting,
            "a cleared preview came back when the view changed windows"
        )
    }

    /// The same rule from the other door: the lightbox closes its renderer when it goes away, and
    /// the next document it is asked for gets a new one rather than the closed one.
    func testAClosedDocumentViewPreviewsAgainWithoutItsClosedRenderer() throws {
        let file = try documentFile(named: "receipt.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let document = MediaInspectorDocumentView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))

        XCTAssertTrue(document.display(file))
        XCTAssertTrue(document.hasQuickLookRendererForTesting)

        document.close()
        XCTAssertFalse(
            document.hasQuickLookRendererForTesting,
            "closing kept the renderer it had just closed"
        )

        XCTAssertTrue(document.display(file))
        XCTAssertTrue(document.hasQuickLookRendererForTesting)
        XCTAssertTrue(document.subviews.allSatisfy { document.permitsSystemChrome($0) })
    }

    func testInspectorTreeIsThemeClean() throws {
        let fixture = try imageFiles(count: 3)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let inspector = MediaInspectorView(items: fixture.items, selectedIndex: 1)
        inspector.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            ThemeBoundaryAudit.violations(in: inspector).isEmpty,
            ThemeBoundaryAudit.violations(in: inspector).map(\.description).joined(separator: "\n")
        )
    }

    func testAStandingInspectorChangesPixelsAcrossALiveThemeSwitch() throws {
        let fixture = try imageFiles(count: 2)
        defer {
            AppThemePalette.set(.system)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let inspector = MediaInspectorView(items: fixture.items, selectedIndex: 0)
        inspector.frame = NSRect(x: 0, y: 0, width: 800, height: 560)

        AppThemePalette.set(.system)
        AppThemeRefresh.repaint(inspector)
        let system = try XCTUnwrap(render(inspector))

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        AppThemeRefresh.repaint(inspector)
        let cyberpunk = try XCTUnwrap(render(inspector))

        XCTAssertNotEqual(system, cyberpunk, "the open inspector kept the previous theme's pixels")
    }

    func testRendersInspectorStorybook() throws {
        let fixture = try imageFiles(count: 3)
        defer {
            AppThemePalette.set(.system)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let directory = renderDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let themes: [(String, AppTheme)] = [
            ("system", .system),
            ("cyberpunk", AppThemeStyles.cyberpunk),
            ("swiss", AppThemeStyles.swissMinimalist)
        ]
        let appearances: [(String, NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]

        var written = 0
        for (themeName, theme) in themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in appearances {
                let inspector = MediaInspectorView(items: fixture.items, selectedIndex: 1)
                inspector.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
                inspector.appearance = NSAppearance(named: appearanceID)
                AppThemeRefresh.repaint(inspector)
                let data = try XCTUnwrap(render(inspector))
                try data.write(to: directory.appendingPathComponent(
                    "media-inspector-\(themeName)-\(appearanceName).png"
                ))
                written += 1
            }
        }

        XCTAssertEqual(written, themes.count * appearances.count)
        print("Rendered media inspector storybook to \(directory.path)")
    }

    /// The shipping overlay on its first frame, with enough items to overflow the filmstrip.
    /// This is deliberately captured before any thumbnail or navigation interaction.
    func testRendersLongCollectionRailOnFirstLayout() throws {
        let fixture = try imageFiles(count: 1)
        defer {
            AppThemePalette.set(.system)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let image = try XCTUnwrap(fixture.items.first?.image)
        let items = (0..<27).map { index in
            MediaInspectorItem(
                url: fixture.items[0].url,
                title: "Frame \(index + 1).png",
                image: image
            )
        }
        let directory = renderDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        AppThemePalette.set(.system)
        let root = ThemedSurfaceView()
        root.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        root.translatesAutoresizingMaskIntoConstraints = true
        root.appearance = NSAppearance(named: .darkAqua)
        root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        let source = ThemedImagePreview(frame: NSRect(x: 20, y: 20, width: 120, height: 90))
        source.translatesAutoresizingMaskIntoConstraints = true
        source.image = image
        source.fileURL = items[0].url
        root.addSubview(source)

        let window = fullSizeContentWindow(hosting: root)
        window.appearance = root.appearance
        defer { MediaInspectorPresenter.dismiss(in: window) }
        XCTAssertTrue(MediaInspectorPresenter.present(
            MediaInspectorSelection(items: items, selectedIndex: 0),
            from: source
        ))

        AppThemeRefresh.repaint(root)
        let data = try XCTUnwrap(render(root))
        let output = directory.appendingPathComponent(
            "media-inspector-long-filmstrip-system-dark.png"
        )
        try data.write(to: output)
        print("Rendered long media inspector filmstrip to \(output.path)")
    }

    /// The picture the wash exists for: the strip of window a full-height surface cannot cover,
    /// with the app's own lit chrome in it. A tonal claim is reviewed by looking at it — this one
    /// shipped as two rows of chrome separated by a hairline, and no assertion anybody would have
    /// written said so.
    func testRendersTheDimmedWindowBehindTheInspector() throws {
        let fixture = try imageFiles(count: 2)
        defer {
            AppThemePalette.set(.system)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let directory = renderDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        AppThemePalette.set(.system)
        for (name, appearanceID) in [
            ("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)
        ] {
            let root = ThemedSurfaceView()
            root.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
            root.translatesAutoresizingMaskIntoConstraints = true
            root.appearance = NSAppearance(named: appearanceID)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let source = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 90))
            root.addSubview(source)

            let window = fullSizeContentWindow(hosting: root)
            window.appearance = NSAppearance(named: appearanceID)
            defer { MediaInspectorPresenter.dismiss(in: window) }

            XCTAssertTrue(MediaInspectorPresenter.present(
                MediaInspectorSelection(items: fixture.items, selectedIndex: 0),
                from: source
            ))
            AppThemeRefresh.repaint(root)
            let data = try XCTUnwrap(render(root))
            try data.write(
                to: directory.appendingPathComponent("media-inspector-scrim-\(name).png")
            )
        }
        print("Rendered the dimmed window behind the inspector to \(directory.path)")
    }

    /// An image shown at 100% is larger than the canvas by design — that is what the zoom is for
    /// — and a view is no longer held to its own bounds when it draws. So the picture climbed out
    /// of the canvas and up over the header, and the file's name, its dimensions, the Fit/100%
    /// control and the close button were left standing on the image itself.
    func testActualSizeDrawsNothingOverTheInspectorHeader() throws {
        let fixture = try imageFile(
            named: "Oversized.png",
            size: NSSize(width: 1_040, height: 640),
            color: .systemTeal
        )
        defer {
            AppThemePalette.set(.system)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        AppThemePalette.set(.system)
        let inspector = MediaInspectorView(items: [fixture.item], selectedIndex: 0)
        inspector.frame = NSRect(x: 0, y: 0, width: 1_050, height: 620)
        inspector.appearance = NSAppearance(named: .darkAqua)
        AppThemeRefresh.repaint(inspector)
        inspector.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            descendants(of: inspector).compactMap { $0 as? MediaInspectorCanvas }.first
        )
        canvas.showActualSize()
        XCTAssertGreaterThan(
            canvas.imageRect.height,
            canvas.bounds.height,
            "the fixture image fits the canvas, so nothing here could overflow it"
        )

        // The band above the canvas, sampled between the title on its left and the zoom control
        // on its right, where the header carries nothing but its own surface.
        let header = try XCTUnwrap(headerSaturations(of: inspector))
        XCTAssertFalse(header.isEmpty, "the header sample read no pixels")
        XCTAssertTrue(
            header.allSatisfy { $0 < 0.1 },
            "the image drew over the inspector's header at 100%"
        )
    }

    // MARK: - Fixtures

    /// How coloured each pixel is in the strip of header the inspector draws above its canvas,
    /// sampled from the middle of the row where it carries no text and no control. The header is
    /// drawn from the palette's greys, so any colour there arrived from the picture.
    private func headerSaturations(of inspector: MediaInspectorView) -> [CGFloat]? {
        guard let rep = inspector.bitmapImageRepForCachingDisplay(in: inspector.bounds) else {
            return nil
        }
        inspector.cacheDisplay(in: inspector.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / inspector.bounds.width
        let rows = stride(
            from: Int(Design.Spacing.large * scale),
            to: Int((Design.Size.inspectorHeaderHeight - Design.Spacing.large) * scale),
            by: 2
        )
        let columns = stride(
            from: Int(inspector.bounds.midX * scale) - 100,
            to: Int(inspector.bounds.midX * scale) + 100,
            by: 2
        )
        return rows.flatMap { row in
            columns.compactMap { column -> CGFloat? in
                guard let colour = rep.colorAt(x: column, y: row)?
                    .usingColorSpace(.sRGB) else { return nil }
                let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                guard let high = channels.max(), let low = channels.min(), high > 0 else {
                    return 0
                }
                return (high - low) / high
            }
        }
    }

    private func imageFile(named name: String, size: NSSize, color: NSColor) throws
        -> (directory: URL, item: MediaInspectorItem) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-media-inspector-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = solidImage(size: size, color: color)
        let url = directory.appendingPathComponent(name)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return (directory, MediaInspectorItem(url: url, image: image))
    }

    private func renderDirectory() -> URL {
        ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
            URL(fileURLWithPath: $0)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingRenders",
            isDirectory: true
        )
    }

    /// Quick Look completes display-bundle activation asynchronously, so a fixture window that
    /// held a `QLPreviewView` is retained past teardown — the same parking
    /// `SessionAttachmentsLayoutTests` keeps for its archive fixture.
    private static var parkedQuickLookWindows: [NSWindow] = []

    /// An unshown window, parked for the process's lifetime: a fixture that held a `QLPreviewView`
    /// is never released inside XCTest's teardown.
    private func quickLookFixtureWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        Self.parkedQuickLookWindows.append(window)
        return window
    }

    /// A file Quick Look renders and Threading does not, which is what routes a preview through
    /// `QLPreviewView` rather than PDFKit or the canvas.
    private func documentFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-media-inspector-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("A document the app has no renderer of its own for.\n".utf8).write(to: url)
        return url
    }

    // MARK: - Annotating

    /// The host is asked for the marks and told of every change. Closing is deliberately not a
    /// publication gesture; chat publication has its own explicit callback.
    @MainActor
    private final class FakeAnnotationHost: MediaInspectorAnnotationHost {
        var marks: [ImageAnnotation] = []
        private(set) var changeCount = 0
        private(set) var closedWith: [ImageAnnotation]?
        var presentsChatActions = false
        var canShare = true
        var state: ImageAnnotationSharingState = .local

        func annotations(for item: MediaInspectorItem) -> [ImageAnnotation] { marks }

        func inspector(
            didChange annotations: [ImageAnnotation],
            for item: MediaInspectorItem,
            image: NSImage?
        ) {
            marks = annotations
            changeCount += 1
        }

        func inspectorDidClose(
            with annotations: [ImageAnnotation],
            for item: MediaInspectorItem,
            image: NSImage?
        ) {
            closedWith = annotations
        }

        func sharingState(for item: MediaInspectorItem) -> ImageAnnotationSharingState { state }
        func showsChatActions(for item: MediaInspectorItem) -> Bool { presentsChatActions }
        func canShareAnnotations(for item: MediaInspectorItem) -> Bool { canShare }
    }

    @MainActor
    func testMarkingIsOfferedOnlyWhenSomebodyWillTakeTheMarks() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let unhosted = MediaInspectorView(items: fixture.items, selectedIndex: 0)
        unhosted.setAnnotating(true)
        XCTAssertFalse(
            unhosted.isAnnotating,
            "an inspector with nowhere to send marks offered to collect them"
        )

        // Held in a local on purpose: the view's reference to its host is weak, so an inline
        // `FakeAnnotationHost()` is deallocated before the next line runs — which is the same
        // lifetime `MediaInspectorSession` exists to supply for the chat host.
        let host = FakeAnnotationHost()
        let hosted = MediaInspectorView(
            items: fixture.items,
            selectedIndex: 0,
            annotationHost: host
        )
        hosted.setAnnotating(true)
        XCTAssertTrue(hosted.isAnnotating)
        XCTAssertTrue(host.marks.isEmpty)
    }

    /// A click marks the picture and reaches durable ownership at once. Closing is not sending.
    @MainActor
    func testAMarkReachesTheHostAndClosingDoesNotPublishIt() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let host = FakeAnnotationHost()
        let inspector = MediaInspectorView(
            items: fixture.items,
            selectedIndex: 0,
            annotationHost: host
        )
        inspector.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        inspector.layoutSubtreeIfNeeded()
        inspector.setAnnotating(true)
        inspector.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            descendants(of: inspector).compactMap { $0 as? MediaInspectorCanvas }.first
        )
        XCTAssertTrue(canvas.isAnnotating, "the canvas was not put into marking mode")

        let centre = NSPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY)
        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: centre, in: canvas))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: centre, in: canvas))

        XCTAssertEqual(host.marks.count, 1, "a click in marking mode did not mark the picture")
        XCTAssertEqual(host.changeCount, 1)
        XCTAssertEqual(canvas.annotations.count, 1, "the pin was not drawn on the canvas")

        inspector.prepareForRemoval()
        XCTAssertNil(host.closedWith, "closing the inspector published user-authored marks")
    }

    func testRendersDurableAnnotationInspector() throws {
        let fixture = try imageFiles(count: 1)
        defer {
            AppThemePalette.set(.system)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let directory = renderDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let themes: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ]

        for (name, theme, appearance) in themes {
            let host = FakeAnnotationHost()
            host.marks = [
                ImageAnnotation(point: CGPoint(x: 0.24, y: 0.28), note: "Align this title with the toolbar"),
                ImageAnnotation(point: CGPoint(x: 0.72, y: 0.36), note: "This action needs a clearer label"),
                ImageAnnotation(point: CGPoint(x: 0.54, y: 0.72), note: "Reduce the empty space below")
            ]
            host.presentsChatActions = true
            host.state = .changedInChat
            AppThemePalette.set(theme)
            let inspector = MediaInspectorView(
                items: fixture.items,
                selectedIndex: 0,
                annotationHost: host
            )
            inspector.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
            inspector.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(inspector)
            let data = try XCTUnwrap(render(inspector))
            try data.write(to: directory.appendingPathComponent(
                "image-annotations-\(name).png"
            ))
        }
        AppThemePalette.set(.system)
        for (name, appearance) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua)
        ] {
            let surface = ThemedSurfaceView()
            surface.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
            surface.translatesAutoresizingMaskIntoConstraints = true
            surface.appearance = NSAppearance(named: appearance)
            surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let preview = ThemedImagePreview()
            preview.image = fixture.items[0].image
            let receipt = ImageAnnotationReceiptView()
            receipt.configure(count: 3, state: .changedInChat, canShare: true)
            let stack = NSStackView(views: [preview, receipt])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = Design.Spacing.small
            stack.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: Design.Spacing.inset),
                stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: Design.Spacing.inset),
                stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -Design.Spacing.inset),
                stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -Design.Spacing.inset),
                preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
                receipt.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
            AppThemeRefresh.repaint(surface)
            let data = try XCTUnwrap(render(surface))
            try data.write(to: directory.appendingPathComponent(
                "image-annotations-attachment-receipt-\(name).png"
            ))
        }
        print("Rendered durable image annotations to \(directory.path)")
    }

    /// A drag pans; only a click marks. A zoomed picture is exactly when somebody wants to pan
    /// *and* has a reason to mark a detail, and deciding on the way down dropped a pin at the
    /// start of every pan.
    @MainActor
    func testPanningAZoomedPictureDoesNotLeaveAPinWhereTheDragBegan() throws {
        let fixture = try imageFiles(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let host = FakeAnnotationHost()
        let inspector = MediaInspectorView(
            items: fixture.items,
            selectedIndex: 0,
            annotationHost: host
        )
        inspector.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        inspector.layoutSubtreeIfNeeded()
        inspector.setAnnotating(true)
        inspector.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(
            descendants(of: inspector).compactMap { $0 as? MediaInspectorCanvas }.first
        )
        canvas.showActualSize()

        let start = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let end = NSPoint(x: start.x + 60, y: start.y + 40)
        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: end, in: canvas))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: end, in: canvas))

        XCTAssertTrue(host.marks.isEmpty, "panning left a pin behind")
        XCTAssertNotEqual(canvas.panOffset, .zero, "the drag did not pan")
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in view: NSView
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func imageFiles(count: Int) throws
        -> (directory: URL, items: [MediaInspectorItem]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-media-inspector-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let colors: [NSColor] = [.systemTeal, .systemOrange, .systemPurple, .systemGreen]
        let items = try (0..<count).map { index -> MediaInspectorItem in
            let size = NSSize(width: 720 + index * 80, height: 420 + index * 40)
            let image = solidImage(size: size, color: colors[index % colors.count])
            let url = directory.appendingPathComponent("Frame \(index + 1).png")
            let bitmap = try XCTUnwrap(
                image.representations.first as? NSBitmapImageRep
                    ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data())
            )
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            return MediaInspectorItem(url: url, image: image)
        }
        return (directory, items)
    }

    private func solidImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        Design.Text.on(color).label.setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: size.width * 0.18,
                y: size.height * 0.2,
                width: size.width * 0.64,
                height: size.height * 0.6
            ),
            xRadius: Design.Radius.control,
            yRadius: Design.Radius.control
        ).fill()
        image.unlockFocus()
        return image
    }

    /// The attachments pane's preview host: a surface with a themed corner, holding one preview
    /// pinned to all four of its edges. Both halves matter — the corner is what clips, and being
    /// pinned is what puts the picture in reach of it.
    private func panelHost(radius: SurfaceRadius) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        host.applySurface(fill: Design.Surface.ground, radius: radius)
        return host
    }

    private func installedPreview(in host: NSView) -> ThemedImagePreview {
        let preview = ThemedImagePreview()
        host.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: host.topAnchor),
            preview.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        return preview
    }

    private func render(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    /// The wash `InWindowOverlay` puts under a covering surface. Found by the name the installer
    /// gives it, because the view itself is private to that file — which is the point: nothing
    /// outside it may build one, and nothing may remove one without the surface.
    private func scrims(in root: NSView) -> [NSView] {
        root.subviews.filter { $0.identifier == InWindowOverlay.scrimIdentifier }
    }

    /// An unshown window dressed like the app's: content drawn full-size under a transparent
    /// titlebar, so the strip the traffic lights float over is real and the surface has something
    /// to clear.
    private func fullSizeContentWindow(hosting root: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.contentView = root
        return window
    }

    private func keyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func crossingEvent(type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }
}
