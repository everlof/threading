import AppKit
import XCTest
@testable import Threading

/// Who owns the pointer's shape while a surface covers the window's content.
///
/// Reported against the dropdown: with a menu open and the pointer inside it, the cursor turned
/// into the split view's resize arrows wherever a pane seam ran behind the panel. A menu drawn as
/// a view rather than as a window inherits none of a window's cursor boundary, so the seam's
/// rectangle kept answering for a strip of window nothing could click. See `CoveredWindowCursor`.
@MainActor
final class CoveredWindowCursorTests: XCTestCase {

    // MARK: - Fixtures

    /// A window shaped like this app's: panes with a themed split view between them, and a
    /// control to open a menu from. Never ordered on screen — cursor-rectangle *management* is a
    /// window property, and turning it off is what this file is about.
    private func makeWindow() -> (window: NSWindow, root: NSView, source: NSView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))

        let split = ThemedSplitView(frame: root.bounds)
        split.autoresizingMask = [.width, .height]
        split.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 260)))
        split.addSubview(NSView(frame: NSRect(x: 201, y: 0, width: 219, height: 260)))
        root.addSubview(split)

        let source = NSView(frame: NSRect(x: 24, y: 200, width: 140, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        return (window, root, source)
    }

    private func presentMenu(
        from source: NSView,
        title: String = "Rename",
        onDismiss: @escaping () -> Void = {}
    ) throws -> AnyObject {
        try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [.item(ThemedMenuItem(title: title))],
                minimumWidth: source.bounds.width
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: onDismiss
        ))
    }

    // MARK: - The Reported Bug

    func testAnOpenDropdownTakesTheCursorRectsOfTheWindowItCovers() throws {
        let (window, _, source) = makeWindow()
        defer { window.close() }

        XCTAssertTrue(window.areCursorRectsEnabled)

        let token = try presentMenu(from: source)
        XCTAssertFalse(
            window.areCursorRectsEnabled,
            "the seam behind the panel could still answer the pointer inside it"
        )
        XCTAssertTrue(CoveredWindowCursor.isClaimed(window))

        ThemedMenuPresenter.dismiss(token)
        XCTAssertTrue(
            window.areCursorRectsEnabled,
            "the window never got its own cursor back"
        )
        XCTAssertFalse(CoveredWindowCursor.isClaimed(window))
    }

    /// The presenter closes a window's open menu before attaching its replacement — the
    /// secondary-click route does not pass through the first menu's dismissing overlay. The claim
    /// has to survive that handoff, and end with the second menu rather than with the first.
    func testAReplacingDropdownKeepsTheClaimThroughTheHandoff() throws {
        let (window, root, source) = makeWindow()
        defer { window.close() }

        let other = NSView(frame: NSRect(x: 220, y: 80, width: 140, height: 26))
        root.addSubview(other)

        let first = try presentMenu(from: source, title: "Pane Context")
        _ = first
        let second = try presentMenu(from: other, title: "Row Context")
        XCTAssertFalse(
            window.areCursorRectsEnabled,
            "the replaced menu's release handed back a window the new one still covers"
        )

        ThemedMenuPresenter.dismiss(second)
        XCTAssertTrue(window.areCursorRectsEnabled)
    }

    // MARK: - The Count AppKit Does Not Keep

    /// Measured on `NSWindow`: two disables and one enable leave cursor management **on**. A
    /// surface closing inside another one would therefore hand back a window the outer surface is
    /// still covering, which is the whole reason claims are counted here.
    func testTheSurfaceStillCoveringTheWindowKeepsItsCursorClaim() {
        let (window, root, _) = makeWindow()
        defer { window.close() }

        let outer = NSView(frame: root.bounds)
        let inner = NSView(frame: root.bounds)
        root.addSubview(outer)
        root.addSubview(inner)
        defer {
            CoveredWindowCursor.release(outer)
            CoveredWindowCursor.release(inner)
        }

        CoveredWindowCursor.claim(outer, covering: window)
        CoveredWindowCursor.claim(inner, covering: window)
        XCTAssertFalse(window.areCursorRectsEnabled)

        CoveredWindowCursor.release(inner)
        XCTAssertFalse(
            window.areCursorRectsEnabled,
            "the inner surface's release spoke for the outer one still covering the window"
        )

        CoveredWindowCursor.release(outer)
        XCTAssertTrue(window.areCursorRectsEnabled)
    }

    /// Claiming twice from one surface is one claim, not two — otherwise a re-entrant path leaves
    /// a count that only a matching number of releases can ever unwind.
    func testASurfaceClaimingTwiceStillReleasesInOne() {
        let (window, root, _) = makeWindow()
        defer { window.close() }

        let surface = NSView(frame: root.bounds)
        root.addSubview(surface)
        defer { CoveredWindowCursor.release(surface) }

        CoveredWindowCursor.claim(surface, covering: window)
        CoveredWindowCursor.claim(surface, covering: window)
        CoveredWindowCursor.release(surface)

        XCTAssertTrue(window.areCursorRectsEnabled)
    }

    func testWindowsAreCountedApart() {
        let covered = makeWindow()
        let untouched = makeWindow()
        defer {
            covered.window.close()
            untouched.window.close()
        }

        let surface = NSView(frame: covered.root.bounds)
        covered.root.addSubview(surface)
        defer { CoveredWindowCursor.release(surface) }

        CoveredWindowCursor.claim(surface, covering: covered.window)

        XCTAssertFalse(covered.window.areCursorRectsEnabled)
        XCTAssertTrue(untouched.window.areCursorRectsEnabled)
        XCTAssertFalse(CoveredWindowCursor.isClaimed(untouched.window))
    }

    // MARK: - The Backstop

    /// A surface that leaves its window without releasing stops counting. The owners here each
    /// release from one teardown funnel, so this is the failure that must not be survivable: a
    /// window whose cursor never answers again for the rest of the session.
    func testASurfaceThatLeftItsWindowStopsHoldingTheCursor() {
        let (window, root, _) = makeWindow()
        defer { window.close() }

        let abandoned = NSView(frame: root.bounds)
        root.addSubview(abandoned)
        CoveredWindowCursor.claim(abandoned, covering: window)
        XCTAssertFalse(window.areCursorRectsEnabled)

        abandoned.removeFromSuperview()

        // Any later claim re-asks who is actually covering what; the departed surface is not.
        let real = NSView(frame: root.bounds)
        root.addSubview(real)
        CoveredWindowCursor.claim(real, covering: window)
        CoveredWindowCursor.release(real)

        XCTAssertTrue(
            window.areCursorRectsEnabled,
            "a surface that left without releasing held the window's cursor forever"
        )
        XCTAssertFalse(CoveredWindowCursor.isClaimed(window))
    }
}
