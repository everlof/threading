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
        XCTAssertTrue(source.performPrimaryAction())
        XCTAssertEqual(
            root.subviews.compactMap { $0 as? MediaInspectorView }.count,
            1,
            "a second activation should replace, not stack, the inspector"
        )
        XCTAssertTrue(ThemeBoundaryAudit.violations(in: root).isEmpty)

        MediaInspectorPresenter.dismiss(in: window)
        XCTAssertFalse(MediaInspectorPresenter.isPresenting(in: window))
        XCTAssertTrue(window.firstResponder === source)
    }

    func testDocumentRendererNamesAndContainsItsSystemChrome() {
        let document = MediaInspectorDocumentView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        document.layoutSubtreeIfNeeded()

        XCTAssertTrue(document.subviews.allSatisfy { document.permitsSystemChrome($0) })
        XCTAssertTrue(ThemeBoundaryAudit.violations(in: document).isEmpty)
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
        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
            URL(fileURLWithPath: $0)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingRenders",
            isDirectory: true
        )
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

    // MARK: - Fixtures

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

    private func render(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
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
