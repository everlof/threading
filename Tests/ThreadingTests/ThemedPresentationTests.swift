import AppKit
import XCTest
@testable import Threading

/// The interaction contract shared by app-owned alerts and popovers.
///
/// These are presentation components, not just painted cards: edge placement, Escape, focus
/// return, accessibility, theme refresh, and the absence of stock chrome are the behavior.
@MainActor
final class ThemedPresentationTests: XCTestCase {

    // MARK: - Popover geometry

    func testPopoverFlipsAwayFromTheScreenEdge() {
        let placement = ThemedPopoverLayout.place(
            anchor: NSRect(x: 970, y: 280, width: 20, height: 30),
            contentSize: NSSize(width: 220, height: 120),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            preferredEdge: .maxX
        )

        XCTAssertEqual(placement.edge, .minX)
        XCTAssertLessThan(placement.panelFrame.maxX, 970)
    }

    func testPopoverClampsToTheVisibleScreenAndKeepsItsArrowOnTheAnchor() {
        let anchor = NSRect(x: 2, y: 2, width: 18, height: 18)
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let placement = ThemedPopoverLayout.place(
            anchor: anchor,
            contentSize: NSSize(width: 280, height: 180),
            visibleFrame: screen,
            preferredEdge: .minY
        )

        XCTAssertGreaterThanOrEqual(placement.panelFrame.minX, screen.minX + 8)
        XCTAssertGreaterThanOrEqual(placement.panelFrame.minY, screen.minY + 8)
        XCTAssertLessThanOrEqual(placement.panelFrame.maxX, screen.maxX - 8)
        XCTAssertLessThanOrEqual(placement.panelFrame.maxY, screen.maxY - 8)

        let globalTip = NSPoint(
            x: placement.panelFrame.minX + placement.arrowTip.x,
            y: placement.panelFrame.minY + placement.arrowTip.y
        )
        XCTAssertGreaterThanOrEqual(globalTip.x, anchor.minX)
        XCTAssertLessThanOrEqual(globalTip.x, anchor.maxX)
        XCTAssertEqual(globalTip.y, anchor.maxY + ThemedPopoverLayout.anchorGap, accuracy: 0.5)
    }

    // MARK: - Popover chrome drawing

    /// The border must run unbroken through the two junctions where the arrow leaves the body.
    ///
    /// The chrome used to fill and stroke the body and the arrow as two paths and repaint
    /// their seam in surface colour — which also erased the tails of the arrow's own stroked
    /// sides, leaving gaps at exactly those junctions. The gap was visible in a picture and in
    /// no assertion, so this samples the drawn pixels along the outline itself.
    func testPopoverBorderRunsUnbrokenThroughTheArrowJunctions() throws {
        let placement = ThemedPopoverLayout.place(
            anchor: NSRect(x: 40, y: 300, width: 20, height: 20),
            contentSize: NSSize(width: 220, height: 140),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            preferredEdge: .maxX
        )
        XCTAssertEqual(placement.edge, .maxX, "the fixture wants the arrow on the left edge")

        let chrome = ThemedPopoverChromeView(
            frame: NSRect(origin: .zero, size: placement.panelFrame.size)
        )
        chrome.placement = placement
        let rep = try rendered(chrome, scale: 3)
        try writeRender(of: rep, named: "popover-chrome-left-arrow")

        let body = placement.bodyFrame
        let inset = Design.Radius.border / 2
        let wallX = body.minX + inset
        let tip = NSPoint(x: inset, y: placement.arrowTip.y)
        let half = ThemedPopoverLayout.arrowBreadth / 2
        let baseTop = NSPoint(x: wallX, y: tip.y + half)
        let baseBottom = NSPoint(x: wallX, y: tip.y - half)
        let surface = try pixel(of: rep, at: NSPoint(x: body.midX, y: body.midY), in: chrome)

        let samples: [(NSPoint, String)] = [
            (NSPoint(x: wallX, y: baseTop.y + 8), "the wall above the arrow"),
            (NSPoint(x: wallX, y: baseBottom.y - 8), "the wall below the arrow"),
            (along(baseTop, tip, 0.5), "the arrow's upper side"),
            (along(baseBottom, tip, 0.5), "the arrow's lower side"),
            // The two junctions — the exact pixels the seam repaint used to erase.
            (along(baseTop, tip, 0.05), "the upper junction"),
            (along(baseBottom, tip, 0.05), "the lower junction")
        ]
        for (point, place) in samples {
            let sample = try pixel(of: rep, at: point, in: chrome)
            XCTAssertGreaterThan(
                contrast(sample, surface), 0.03,
                "\(place) shows no border ink at (\(point.x), \(point.y))"
            )
        }
    }

    func testPopoverChromeRendersEveryArrowEdge() throws {
        let screen = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let anchors: [(NSRectEdge, NSRect)] = [
            (.maxX, NSRect(x: 300, y: 390, width: 20, height: 20)),
            (.minX, NSRect(x: 880, y: 390, width: 20, height: 20)),
            (.maxY, NSRect(x: 590, y: 240, width: 20, height: 20)),
            (.minY, NSRect(x: 590, y: 560, width: 20, height: 20)),
        ]
        var renders = Set<Data>()

        for (edge, anchor) in anchors {
            let placement = ThemedPopoverLayout.place(
                anchor: anchor,
                contentSize: NSSize(width: 220, height: 140),
                visibleFrame: screen,
                preferredEdge: edge
            )
            XCTAssertEqual(placement.edge, edge)
            let chrome = ThemedPopoverChromeView(
                frame: NSRect(origin: .zero, size: placement.panelFrame.size)
            )
            chrome.placement = placement
            let rep = try rendered(chrome, scale: 2)
            try writeRender(of: rep, named: "popover-chrome-\(edge.rawValue)-arrow")
            renders.insert(try XCTUnwrap(rep.representation(using: .png, properties: [:])))
        }

        XCTAssertEqual(renders.count, anchors.count, "an arrow edge rendered as another edge")
    }

    // MARK: - Dismissal and focus

    func testPopoverEscapeClosesOnceAndReturnsFocus() throws {
        let window = testWindow()
        defer { window.close() }
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        XCTAssertTrue(window.makeFirstResponder(anchor))

        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        content.preferredContentSize = content.view.frame.size

        let popover = ThemedPopover()
        popover.contentViewController = content
        var closes = 0
        popover.onClose = { closes += 1 }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        XCTAssertTrue(popover.isShown)
        let panel = try XCTUnwrap(popover.presentedWindow)
        panel.makeKey()
        panel.cancelOperation(nil)

        XCTAssertFalse(popover.isShown)
        XCTAssertNil(popover.presentedWindow)
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(window.firstResponder === anchor)

        popover.close()
        XCTAssertEqual(closes, 1, "closing an already closed surface must be idempotent")
    }

    func testPopoverClosesWhenItsAnchorLeavesTheHierarchy() throws {
        let window = testWindow()
        defer { window.close() }
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        content.preferredContentSize = content.view.frame.size
        let popover = ThemedPopover()
        popover.animates = false
        popover.contentViewController = content
        var closes = 0
        popover.onClose = { closes += 1 }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        anchor.removeFromSuperview()
        popover.reposition()

        XCTAssertFalse(popover.isShown)
        XCTAssertNil(popover.presentedWindow)
        XCTAssertEqual(closes, 1)
    }

    func testDroppingPopoverOwnerDetachesAndTearsDownItsPanel() throws {
        let window = testWindow()
        defer { window.close() }
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        content.preferredContentSize = content.view.frame.size

        var popover: ThemedPopover? = ThemedPopover()
        popover?.animates = false
        popover?.contentViewController = content
        popover?.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let panel = try XCTUnwrap(popover?.presentedWindow)
        XCTAssertTrue(window.childWindows?.contains(panel) == true)

        popover = nil
        let detached = expectation(description: "panel detached on owner deinit")
        DispatchQueue.main.async {
            XCTAssertNil(panel.parent)
            XCTAssertFalse(panel.isVisible)
            XCTAssertNil(panel.contentViewController)
            detached.fulfill()
        }
        wait(for: [detached], timeout: 1)
    }

    func testAlertEscapeEndsTheSheetAndReturnsFocus() throws {
        let window = testWindow()
        defer { window.close() }
        let source = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        XCTAssertTrue(window.makeFirstResponder(source))

        let alert = ThemedAlert()
        alert.messageText = "Leave this dialog?"
        alert.informativeText = "Escape is always a way out."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let dismissed = expectation(description: "sheet dismissed")
        alert.beginSheetModal(for: window) { response in
            XCTAssertEqual(response, .abort)
            dismissed.fulfill()
        }

        let panel = try XCTUnwrap(alert.presentedWindow)
        panel.cancelOperation(nil)
        wait(for: [dismissed], timeout: 1)

        XCTAssertNil(alert.presentedWindow)
        XCTAssertTrue(window.firstResponder === source)
    }

    // MARK: - Semantics and themes

    func testAlertTreeExposesTheDialogCopyButtonsAndSuppressionChoice() throws {
        let alert = ThemedAlert()
        alert.messageText = "Remove project?"
        alert.informativeText = "The folder stays on disk."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let root = sized(alert.makeContentView())
        let tree = [root] + descendants(in: root)
        let buttons = tree.filter { $0.accessibilityRole() == .button }
        let checkboxes = tree.filter { $0.accessibilityRole() == .checkBox }

        XCTAssertEqual(root.accessibilityLabel(), "Remove project?")
        XCTAssertEqual(Set(buttons.compactMap { $0.accessibilityTitle() }), ["Remove", "Cancel"])
        XCTAssertEqual(checkboxes.first?.accessibilityTitle(), "Don't ask again")
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: root), [])
    }

    /// Prominence follows Return everywhere else, and must not here.
    ///
    /// `ConfirmationAlert.applyDefaultButton` deliberately moves Return to Cancel for an
    /// `.irreversible` prompt, so the accent fill went with it: the loudest thing in a delete
    /// dialog was the button that does not delete, and on a theme whose accent is its negative
    /// colour it was the reddest thing too. Filling the *action* instead was rejected — it makes
    /// the irreversible button the most clickable thing on a sheet meant to slow the user down —
    /// so a destructive confirmation fills neither, and the two come out the same size.
    func testADestructiveAlertFillsNeitherButtonAndSizesThemAlike() throws {
        let root = sized(destructiveAlert().makeContentView())
        let buttons = themedButtons(in: root)
        let delete = try XCTUnwrap(buttons.first { $0.title == "Delete" })
        let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })

        XCTAssertEqual(delete.emphasis, .secondary)
        XCTAssertEqual(cancel.emphasis, .secondary, "Cancel is wearing the accent fill")
        XCTAssertEqual(
            delete.frame.height,
            cancel.frame.height,
            "a filled button's focus ring is stroked inside its own silhouette, "
                + "so the prominent one read shorter than the bordered one beside it"
        )
        XCTAssertNotNil(delete.contentTintColor, "the destructive action says so in its title")
        XCTAssertNil(cancel.contentTintColor)
    }

    /// The other half of the rule: an ordinary confirmation — a grant, an OK — still fills the
    /// button Return activates, because there the default *is* the action.
    func testAnOrdinaryAlertStillFillsTheButtonReturnActivates() throws {
        let alert = ThemedAlert()
        alert.messageText = "Allow this tool?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")

        let buttons = themedButtons(in: sized(alert.makeContentView()))

        XCTAssertEqual(buttons.first { $0.title == "Allow" }?.emphasis, .primary)
        XCTAssertEqual(buttons.first { $0.title == "Cancel" }?.emphasis, .secondary)
    }

    /// The picture, under the theme that showed it. Swiss Minimalist sets `accent` and
    /// `statusNegative` to the same `#D6180B`, which is what collapsed "this is the action" and
    /// "this is destructive" into one signal wearing the wrong label.
    func testSwissMinimalistLeavesTheCancelOfADeleteDialogOnPaper() throws {
        let previous = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previous)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previous.id))
        }
        let swiss = AppThemeStyles.swissMinimalist
        AppThemePalette.set(swiss)
        NotificationCenter.default.post(AppThemeDidChange(themeID: swiss.id))

        let root = sized(destructiveAlert().makeContentView())
        root.appearance = NSAppearance(named: .aqua)
        root.layoutSubtreeIfNeeded()

        let rep = try rendered(root, scale: 2)
        try writeRender(of: rep, named: "alert-destructive-swiss")

        let cancel = try XCTUnwrap(themedButtons(in: root).first { $0.title == "Cancel" })
        let centre = cancel.convert(
            NSPoint(x: cancel.bounds.midX, y: cancel.bounds.midY),
            to: root
        )

        XCTAssertGreaterThan(
            contrast(try pixel(of: rep, at: centre, in: root), Design.Surface.accent),
            0.3,
            "Cancel is filled with the accent in a dialog whose action is Delete"
        )
    }

    func testPresentationChromeChangesLiveAcrossDistinctThemes() throws {
        let previous = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previous)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previous.id))
        }

        let alert = ThemedAlert()
        alert.messageText = "Presentation chrome"
        alert.informativeText = "The surface, type, controls, and status icon follow the app theme."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let root = sized(alert.makeContentView())
        root.appearance = NSAppearance(named: .darkAqua)

        let themes: [AppTheme] = [
            .system,
            AppThemeStyles.swissMinimalist,
            AppThemeStyles.cyberpunk
        ]
        var renders: [Data] = []
        for theme in themes {
            AppThemePalette.set(theme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
            root.layoutSubtreeIfNeeded()
            renders.append(try renderedPNG(of: root))
        }

        XCTAssertEqual(Set(renders).count, themes.count, "presentation chrome ignored a live theme")
    }

    // MARK: - Helpers

    private func testWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 420, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        let source = ThemedButton(title: "Source", target: nil, action: nil)
        source.frame = NSRect(x: 40, y: 80, width: 100, height: Design.Size.chipHeight)
        root.addSubview(source)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func sized(_ view: NSView) -> NSView {
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func themedButtons(in root: NSView) -> [ThemedButton] {
        ([root] + descendants(in: root)).compactMap { $0 as? ThemedButton }
    }

    /// The alert `ConfirmationAlert` builds for an `.irreversible` prompt: the action first, the
    /// way out second, `hasDestructiveAction` on the action and Return moved off it.
    private func destructiveAlert() -> ThemedAlert {
        let alert = ThemedAlert()
        alert.messageText = "Delete “our custom popover got stuck”?"
        alert.informativeText =
            "The agent will stop and the session is removed from Threading. The saved "
            + "conversation on disk is not deleted, so it could still be imported again later."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        return alert
    }

    private func renderedPNG(of view: NSView) throws -> Data {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// The view drawn at a magnification, so a one-point border is several pixels a sample
    /// can land inside rather than a blend it has to guess at.
    private func rendered(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = view.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        view.displayIgnoringOpacity(view.bounds, in: context)
        return rep
    }

    /// The rep's colour under a point given in the view's own (unflipped) coordinates.
    private func pixel(
        of rep: NSBitmapImageRep,
        at point: NSPoint,
        in view: NSView
    ) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let x = Int((point.x * scale).rounded(.down))
        let y = Int(((view.bounds.height - point.y) * scale).rounded(.down))
        return try XCTUnwrap(rep.colorAt(
            x: min(max(x, 0), rep.pixelsWide - 1),
            y: min(max(y, 0), rep.pixelsHigh - 1)
        ))
    }

    /// The largest per-channel difference — enough to say "this pixel is not that surface".
    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let a = a.usingColorSpace(.deviceRGB),
              let b = b.usingColorSpace(.deviceRGB) else { return 0 }
        return max(
            abs(a.redComponent - b.redComponent),
            abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent),
            abs(a.alphaComponent - b.alphaComponent)
        )
    }

    private func along(_ from: NSPoint, _ to: NSPoint, _ t: CGFloat) -> NSPoint {
        NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    /// Saves the render where the other render tests put theirs, for appearance review.
    private func writeRender(of rep: NSBitmapImageRep, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] else {
            return
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url.appendingPathComponent("\(name).png"))
    }
}
