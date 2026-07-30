import AppKit
import XCTest
@testable import Threading

/// The band that reports something already done, and the clock behind it.
///
/// Everything that goes wrong with a transient surface is about time rather than drawing — two
/// of them stacking, one expiring under the pointer that was reaching for its button, one
/// outliving the thing it reports — so most of this file is the presenter rather than the view.
/// Reduce Motion is forced on throughout, so the arrival and the departure take no time at all
/// and the only waiting left in here is the dwell itself.
@MainActor
final class ToastTests: XCTestCase {

    private var previousTheme: AppTheme!

    override func setUp() {
        super.setUp()
        previousTheme = AppThemeLibrary.current
        Design.Motion.reduceMotionOverrideForTesting = true
    }

    override func tearDown() {
        AppThemeLibrary.apply(previousTheme)
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: - Fixture

    /// A pane the size of the sidebar with a footer band at the bottom, which is the shape the
    /// presenter is actually used in. Unshown, like every other fixture window here.
    private func pane() -> (host: NSView, bottom: NSLayoutYAxisAnchor, window: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SidebarDefaults.defaultWidth, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        let footer = PaneFooterView()
        host.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        return (host, footer.topAnchor, window)
    }

    private func archiveRequest(
        message: String = "Archived “Refactor the parser”",
        detail: String? = "The agent stopped. Restore it from Settings ▸ Archived.",
        undo: (() -> Void)? = nil
    ) -> ToastRequest {
        ToastRequest(
            message: message,
            detail: detail,
            actionTitle: "Undo",
            action: undo ?? {},
            identifier: "sidebar.toast.archive"
        )
    }

    // MARK: - The band

    func testTheBandShowsItsMessageItsDetailAndItsAction() throws {
        let toast = ToastView(request: archiveRequest())
        let labels = descendants(of: toast).compactMap { $0 as? NSTextField }

        XCTAssertTrue(labels.contains { $0.stringValue.contains("Refactor the parser") })
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Settings ▸ Archived") })
        XCTAssertEqual(buttons(in: toast).map(\.title), ["Undo"])
    }

    /// A toast with nothing to offer is a receipt, and must not grow an empty control row.
    func testAToastWithoutAnActionDrawsNoButton() {
        let toast = ToastView(request: ToastRequest(message: "Archived “Parser”"))

        XCTAssertTrue(buttons(in: toast).isEmpty)
        XCTAssertFalse(toast.request.hasAction)
    }

    /// The band takes no focus and leaves by itself, so its accessible name is the only thing
    /// VoiceOver ever gets — which means it has to be the whole receipt, not just the verb.
    func testTheBandReadsOutTheWholeReceipt() throws {
        let toast = ToastView(request: archiveRequest())

        XCTAssertTrue(toast.isAccessibilityElement())
        XCTAssertEqual(toast.accessibilityRole(), .group)
        let label = try XCTUnwrap(toast.accessibilityLabel())
        XCTAssertTrue(label.contains("Archived"))
        XCTAssertTrue(label.contains("The agent stopped"))
    }

    /// The way back is a real button rather than a drawn glyph, which is what gives it a
    /// keyboard route and an accessible name without this view stating either.
    func testTheWayBackIsAControlAndNotJustSomethingToClick() throws {
        let toast = ToastView(request: archiveRequest())
        let undo = try XCTUnwrap(buttons(in: toast).first)

        XCTAssertTrue(undo.isAccessibilityElement())
        XCTAssertTrue(undo.canBecomeKeyView || undo.acceptsFirstResponder)
        XCTAssertEqual(undo.accessibilityIdentifier(), "sidebar.toast.archive.action")
    }

    /// The band floats over a list, so its fill is the elevated role rather than a translucent
    /// control surface — the mistake that once let a conversation's own text run through the
    /// middle of the git card.
    func testTheBandDrawsOnAnOpaqueSurface() throws {
        let toast = ToastView(request: archiveRequest())
        let fill = try XCTUnwrap(toast.layer?.backgroundColor)

        XCTAssertEqual(fill.alpha, 1, accuracy: 0.001, "content underneath will read through it")
    }

    /// A theme switch re-resolves the recorded surface. Assigning a `CGColor` is how a themed
    /// view stops being themed, so the check is that the fill actually moved.
    func testTheBandFollowsALiveThemeSwitch() throws {
        AppThemePalette.set(.system)
        let toast = ToastView(request: archiveRequest())
        toast.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
        let before = try XCTUnwrap(toast.layer?.backgroundColor)

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        AppThemeRefresh.repaint(toast)
        let after = try XCTUnwrap(toast.layer?.backgroundColor)

        XCTAssertNotEqual(before, after, "the band kept the previous theme's fill")
        AppThemePalette.set(.system)
    }

    // MARK: - The clock

    func testPresentingPutsTheBandAboveThePanesFooter() throws {
        let (host, bottom, window) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)

        presenter.present(archiveRequest())
        host.layoutSubtreeIfNeeded()

        let toast = try XCTUnwrap(presenter.current)
        XCTAssertTrue(toast.isDescendant(of: host))
        XCTAssertLessThanOrEqual(
            toast.frame.width,
            ToastDefaults.maxWidth,
            "the band grew past its cap"
        )
        XCTAssertGreaterThan(toast.frame.minY, 0, "the band landed on top of the footer")
        XCTAssertEqual(window.contentView, host)
    }

    /// Pressing the way back runs the caller's undo exactly once and takes the band with it —
    /// an undo left on screen after it has been taken is an offer to undo the undo.
    func testTheActionRunsOnceAndDismissesTheBand() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)

        var undone = 0
        presenter.present(archiveRequest { undone += 1 })
        let toast = try XCTUnwrap(presenter.current)

        try XCTUnwrap(buttons(in: toast).first).performClick()

        XCTAssertEqual(undone, 1)
        XCTAssertNil(presenter.current)

        // The band leaves through its own departure animation, so the view itself is gone one
        // turn of the run loop later even when Reduce Motion has collapsed that to nothing.
        waitForRunLoop(0.1)
        XCTAssertNil(toast.superview, "the band stayed in the pane after its action was taken")
    }

    /// Two bands in a column is a queue nobody asked for, and the second report is always the
    /// one that describes the state the user is in.
    func testASecondToastReplacesTheFirstRatherThanStacking() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)

        presenter.present(archiveRequest(message: "Archived “One”"))
        let first = try XCTUnwrap(presenter.current)
        presenter.present(archiveRequest(message: "Archived “Two”"))

        XCTAssertNil(first.superview)
        XCTAssertEqual(descendants(of: host).compactMap { $0 as? ToastView }.count, 1)
        XCTAssertEqual(presenter.current?.request.message, "Archived “Two”")
    }

    func testTheBandLeavesOnItsOwnWhenTheDwellRunsOut() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 0.05

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)

        waitForRunLoop(0.4)

        XCTAssertNil(presenter.current)
        XCTAssertNil(toast.superview)
    }

    /// A way back that expires while it is being reached for is worse than no way back, because
    /// the reach is the moment the decision was already made.
    ///
    /// Asserted on the clock rather than by waiting out the dwell: a test's pointer is wherever
    /// the developer left it, so the band's own staleness correction — right in the app, where
    /// the pointer really is on it — would take a synthesised hover straight back off again.
    func testThePointerHoldsTheBandsClockAndReleasingItRestartsIt() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 0.05

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)
        XCTAssertFalse(presenter.isHeldOpen, "a band nobody is pointing at has to be on a clock")

        toast.mouseEntered(with: NSEvent())
        XCTAssertTrue(presenter.isHeldOpen, "the band kept counting down under the pointer")

        toast.mouseExited(with: NSEvent())
        XCTAssertFalse(presenter.isHeldOpen, "the clock never restarted, so the band is forever")

        waitForRunLoop(0.4)
        XCTAssertNil(presenter.current)
    }

    // MARK: - Helpers

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func buttons(in view: NSView) -> [ThemedButton] {
        descendants(of: view).compactMap { $0 as? ThemedButton }
    }

    private func waitForRunLoop(_ interval: TimeInterval) {
        let settled = expectation(description: "the run loop advanced")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { settled.fulfill() }
        wait(for: [settled], timeout: interval + 5)
    }
}
