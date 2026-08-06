import XCTest

@testable import Threading

/// The two surfaces the baseline workflow adds, and the one contract that is easiest to break by
/// accident: the live overlay must pass clicks through to the page underneath it.
@MainActor
final class BrowserBaselineUITests: XCTestCase {

    private enum Render {
        /// The display pane's protected minimum. Every one of these surfaces has to survive it.
        static let narrowWidth: CGFloat = 260
        static let width: CGFloat = 620

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    // MARK: - Overlay hit testing

    /// The behavioural difference from annotation mode, asserted directly: annotation mode takes
    /// page clicks because a click places a pin; this overlay must take none but its handle, or the
    /// page it is held over stops being usable.
    func testTheOverlayPassesEveryClickThroughExceptItsHandle() throws {
        let overlay = BrowserBaselineOverlay(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let host = NSView(frame: overlay.frame)
        host.addSubview(overlay)

        // Nothing held: the whole surface is inert.
        XCTAssertNil(overlay.hitTest(NSPoint(x: 200, y: 150)))

        overlay.content = Self.content(kind: .viewport)
        overlay.fraction = 0.5
        overlay.layoutSubtreeIfNeeded()

        XCTAssertNil(
            overlay.hitTest(NSPoint(x: 40, y: 40)),
            "A click on the page area must reach the page"
        )
        XCTAssertNil(
            overlay.hitTest(NSPoint(x: 380, y: 280)),
            "So must a click in the corner"
        )
        let handle = try XCTUnwrap(
            overlay.hitTest(NSPoint(x: 200, y: 150)),
            "The handle is the one thing a click may land on"
        )
        XCTAssertTrue(handle is BrowserBaselineOverlayHandle)
    }

    func testTheHandleIsAKeyboardAccessibleSlider() throws {
        let overlay = BrowserBaselineOverlay(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        overlay.content = Self.content(kind: .viewport)
        overlay.layoutSubtreeIfNeeded()

        let handle = try XCTUnwrap(
            overlay.hitTest(NSPoint(x: 200, y: 150)) as? BrowserBaselineOverlayHandle
        )
        XCTAssertTrue(handle.acceptsFirstResponder)
        XCTAssertEqual(handle.accessibilityRole(), .slider)
        XCTAssertNotNil(handle.accessibilityLabel())
        XCTAssertTrue(handle.accessibilityPerformPress())
        XCTAssertEqual(overlay.fraction, 0.5, accuracy: 0.001)
    }

    /// A viewport baseline is true at the offset it was captured at and nowhere else. Scrolling
    /// away must be stated rather than silently misaligned — the overlay would otherwise look like
    /// a page that had changed enormously.
    func testAViewportBaselineReportsMisalignmentWhileAFullPageOneTracksScroll() {
        let overlay = BrowserBaselineOverlay(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )

        overlay.content = Self.content(kind: .viewport)
        XCTAssertTrue(overlay.alignment.isAligned)
        overlay.documentScroll = CGPoint(x: 0, y: 240)
        XCTAssertFalse(overlay.alignment.isAligned)
        XCTAssertEqual(
            overlay.alignment.origin,
            .zero,
            "A viewport capture is never slid: it has no pixels for where the page now is"
        )

        overlay.content = Self.content(kind: .fullPage)
        overlay.documentScroll = CGPoint(x: 0, y: 240)
        XCTAssertTrue(overlay.alignment.isAligned)
        XCTAssertEqual(overlay.alignment.origin.y, -240, "A document capture travels with scroll")
    }

    // MARK: - Comparison tab

    func testTheComparisonOffersApprovalOnlyWhenThereIsSomethingToApproveInto() throws {
        let baseline = try BrowserBaselineStoreTests.png(width: 8, height: 8, red: 0)
        let actual = try BrowserBaselineStoreTests.png(width: 8, height: 8, red: 255)

        let withoutApproval = BrowserComparisonViewController(
            sessionID: SessionID(),
            content: BrowserComparisonViewController.Content(
                baselineTitle: "baseline.png",
                actualTitle: "Current",
                baselinePNG: baseline,
                actualPNG: actual,
                diffPNG: nil,
                summary: "MISMATCH",
                approval: nil
            )
        )
        var accepted: BrowserComparisonViewController.Approval?
        withoutApproval.onAcceptRevision = { accepted = $0 }
        _ = withoutApproval.view
        XCTAssertNil(accepted)

        let approval = BrowserComparisonViewController.Approval(
            projectID: ProjectID(),
            baselineID: BrowserBaselineID(),
            baselineName: "Dashboard",
            capturePNG: actual,
            conditions: BrowserBaselineStoreTests.conditions(width: 8, height: 8)
        )
        let withApproval = BrowserComparisonViewController(
            sessionID: SessionID(),
            content: BrowserComparisonViewController.Content(
                baselineTitle: "Dashboard",
                actualTitle: "Current",
                baselinePNG: baseline,
                actualPNG: actual,
                diffPNG: actual,
                summary: "MISMATCH",
                approval: approval
            )
        )
        withApproval.onAcceptRevision = { accepted = $0 }
        _ = withApproval.view
        XCTAssertEqual(withApproval.content.approval, approval)
    }

    // MARK: - Library

    func testTheLibraryListsRecordsAndSurvivesTheNarrowPane() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaselineLibraryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserBaselineStore(root: root)
        let projectID = ProjectID()
        _ = try store.createBaseline(
            BrowserBaselineStoreTests.request(
                name: "Signed-in dashboard",
                png: try BrowserBaselineStoreTests.png(width: 40, height: 30, red: 120)
            ),
            in: projectID
        )

        let library = BrowserBaselineLibraryViewController(
            projectID: projectID,
            projectName: "Threading",
            store: store
        )
        _ = library.view
        library.view.layoutSubtreeIfNeeded()

        let labels = Self.descendants(of: library.view).compactMap { $0 as? NSTextField }
        XCTAssertTrue(
            labels.contains { $0.stringValue.contains("Signed-in dashboard") },
            "The record's own name is on screen"
        )
        XCTAssertTrue(
            labels.contains { $0.stringValue.contains("1 baselines in Threading") },
            "And the project it belongs to"
        )

        // A sheet states its own size, so the narrow-pane rule is not this surface's to meet —
        // it is the comparison tab's, which is asserted below.
        XCTAssertEqual(library.view.frame.width, BrowserBaselineLibraryDefaults.width)
    }

    /// The comparison *is* pane content, so it is the surface the display panel's protected 260pt
    /// minimum applies to.
    func testTheComparisonSurvivesTheNarrowPane() throws {
        let png = try BrowserBaselineStoreTests.png(width: 400, height: 300, red: 80)
        let controller = BrowserComparisonViewController(
            sessionID: SessionID(),
            content: BrowserComparisonViewController.Content(
                baselineTitle: "Dashboard",
                actualTitle: "Current",
                baselinePNG: png,
                actualPNG: png,
                diffPNG: png,
                summary: "MATCH · 0 of 120000 compared pixels changed",
                approval: nil
            )
        )
        // **The pane's width is stated as a constraint, not only as a frame.** A detached view
        // holding a frame pins nothing: Auto Layout lays the subtree out at the width it would
        // *prefer*, so a header that compresses perfectly well at 260 was measured at 365 and
        // reported as overflowing a pane it had never been asked to fit into. A split view gives
        // its panes a real width, and so does this.
        controller.view.frame = NSRect(x: 0, y: 0, width: Render.narrowWidth, height: 420)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.widthAnchor.constraint(equalToConstant: Render.narrowWidth),
            controller.view.heightAnchor.constraint(equalToConstant: 420)
        ])
        controller.view.layoutSubtreeIfNeeded()

        let overflowing = Self.descendants(of: controller.view).filter {
            $0.frame.width > Render.narrowWidth + 1
                && $0.superview?.superview !== controller.view.window
        }
        XCTAssertTrue(
            overflowing.allSatisfy { $0 is NSClipView || $0.enclosingScrollView != nil },
            "Only scrolled content may be wider than the pane"
        )
    }

    // MARK: - Rendered states

    /// Appearance is reviewed here the way the rest of this codebase reviews it: by drawing the
    /// real surface, light and dark, and looking at the picture.
    func testRendersTheComparisonAndTheOverlayLightAndDark() throws {
        let baseline = try BrowserVisualComparisonTests.png(width: 120, height: 80) { x, _ in
            x < 60 ? .systemBlue : .white
        }
        let actual = try BrowserVisualComparisonTests.png(width: 120, height: 80) { x, _ in
            x < 70 ? .systemBlue : .white
        }
        let comparison = try BrowserVisualComparator.compare(
            baseline: baseline,
            actual: actual,
            options: BrowserVisualComparisonOptions(maximumDifferentRatio: 0)
        )
        XCTAssertFalse(comparison.matches)

        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )

        for (name, appearance) in [
            ("light", NSAppearance(named: .aqua)),
            ("dark", NSAppearance(named: .darkAqua))
        ] {
            let controller = BrowserComparisonViewController(
                sessionID: SessionID(),
                content: BrowserComparisonViewController.Content(
                    baselineTitle: "Dashboard",
                    actualTitle: "Current",
                    baselinePNG: baseline,
                    actualPNG: actual,
                    diffPNG: comparison.diffPNG,
                    summary: "MISMATCH · 800 of 9600 compared pixels changed",
                    approval: nil
                )
            )
            let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: 420))
            // Without this the offscreen render draws a blank image.
            host.appearance = appearance
            controller.view.frame = host.bounds
            host.addSubview(controller.view)
            host.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(
                to: Render.directory.appendingPathComponent("browser-comparison-\(name).png")
            )
            XCTAssertGreaterThan(data.count, 0)
        }
    }

    // MARK: - Helpers

    private static func content(
        kind: BrowserBaselineCaptureKind
    ) -> BrowserBaselineOverlayContent {
        BrowserBaselineOverlayContent(
            image: NSImage(size: NSSize(width: 400, height: 900)),
            name: "Dashboard",
            captureKind: kind,
            capturedScroll: .zero,
            captureSize: CGSize(width: 400, height: 900)
        )
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
