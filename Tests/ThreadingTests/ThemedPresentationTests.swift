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

    private func renderedPNG(of view: NSView) throws -> Data {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
