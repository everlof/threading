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

    /// The same pane, held at a width the way a split view holds the sidebar's: by a constraint
    /// a shade above `defaultLow`, which anything inside the column can outrank and push.
    private func column(width: CGFloat) -> (
        column: NSView,
        bottom: NSLayoutYAxisAnchor,
        window: NSWindow
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root

        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        let held = column.widthAnchor.constraint(equalToConstant: width)
        held.priority = SidebarDefaults.holdingPriority

        let footer = PaneFooterView()
        column.addSubview(footer)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            held,
            footer.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: column.bottomAnchor)
        ])
        root.layoutSubtreeIfNeeded()
        return (column, footer.topAnchor, window)
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

    /// The band floats *in* a column; it does not get to decide how wide that column is.
    ///
    /// The sidebar holds its width with a constraint one step above `defaultLow`, and a wrapping
    /// label resists compression at 750 — so a chain of required pins carried the receipt's own
    /// text out to the split view, and the sidebar jumped wider as the band arrived and snapped
    /// back six seconds later when it left. The column here is held exactly the way the split
    /// view holds the real one, and the band has more words than fit in it.
    func testTheBandDoesNotWidenTheColumnItFloatsIn() throws {
        let (column, bottom, _) = column(width: SidebarDefaults.minWidth)
        let presenter = ToastPresenter(host: column, above: bottom)

        presenter.present(archiveRequest(
            message: "Archived “Rewrite the rollout discovery so Codex reports its own id”",
            detail: "The agent stopped. Restore it from Settings ▸ Archived."
        ))
        column.superview?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            column.frame.width,
            SidebarDefaults.minWidth,
            accuracy: 0.5,
            "the receipt's own words widened the column it was reporting into"
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(presenter.current).frame.width,
            SidebarDefaults.minWidth - ToastDefaults.hostInset * 2 + 0.5,
            "the band overhung the column instead of wrapping inside it"
        )
    }

    /// The same rule from the other side: the divider has no maximum, so a column can be wider
    /// than the band's cap plus its insets. The presenter's own fill pin is breakable so the cap
    /// can win — but at `defaultHigh` it outranked the column's holding priority, and a pin the
    /// *band* was not allowed to satisfy was satisfied with the column instead: the sidebar
    /// snapped in to meet the cap as the receipt arrived, and sprang back out when it left.
    func testTheBandDoesNotNarrowAWideColumnToMeetItsOwnCap() throws {
        let width = ToastDefaults.maxWidth + ToastDefaults.hostInset * 2 + 60
        let (column, bottom, _) = column(width: width)
        let presenter = ToastPresenter(host: column, above: bottom)

        presenter.present(archiveRequest())
        column.superview?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            column.frame.width,
            width,
            accuracy: 0.5,
            "the band's fill pin dragged the column in to meet the band's own cap"
        )
        XCTAssertEqual(
            try XCTUnwrap(presenter.current).frame.width,
            ToastDefaults.maxWidth,
            accuracy: 0.5,
            "the band stopped short of its cap in a column with room for it"
        )
    }

    /// A receipt is a band, not a bubble: in a column with more room than its words need, it
    /// still fills the width it is given, up to its cap. The words are silenced in *both*
    /// directions — a label's hugging outranking the fill pin would shrink-wrap the band to
    /// whatever its message happened to be.
    func testTheBandFillsANarrowColumnEvenWhenItsWordsAreShort() throws {
        let (column, bottom, _) = column(width: SidebarDefaults.minWidth)
        let presenter = ToastPresenter(host: column, above: bottom)

        presenter.present(ToastRequest(message: "Archived “P”"))
        column.superview?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            try XCTUnwrap(presenter.current).frame.width,
            SidebarDefaults.minWidth - ToastDefaults.hostInset * 2,
            accuracy: 0.5,
            "the band shrank to its words instead of filling the column"
        )
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

    /// A receipt for something nobody just did has to outlast the glance that finds it: the six
    /// seconds are measured from a click, and an agent archiving its own session is the same
    /// band arriving with no click behind it. The length belongs to the request, because it is a
    /// fact about who caused the thing rather than about the pane it appears in.
    func testABandMayAskToHoldLongerThanThePaneWouldKeepIt() throws {
        XCTAssertGreaterThan(ToastDefaults.unattendedDwell, ToastDefaults.dwell)

        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 0.02

        var request = archiveRequest()
        request.dwell = 30
        presenter.present(request)

        waitForRunLoop(0.3)

        XCTAssertNotNil(
            presenter.current,
            "the band left on the pane's clock instead of on its own"
        )
        presenter.dismiss()
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

    // MARK: - The clock, drawn

    /// The band is the one surface in the window whose *remaining* time is worth knowing, so it
    /// shows it: the rail runs while the clock does, and stops with it.
    func testTheBandShowsACountdownForItsOwnDwellAndStopsItUnderThePointer() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)
        XCTAssertTrue(toast.isDwellRunning)
        XCTAssertTrue(toast.showsDwellCountdown)

        toast.mouseEntered(with: NSEvent())
        XCTAssertFalse(toast.isDwellRunning, "the rail kept draining on a clock that had stopped")
        XCTAssertTrue(toast.showsDwellCountdown, "what is left of the band's time vanished with it")

        toast.mouseExited(with: NSEvent())
        XCTAssertTrue(toast.isDwellRunning, "the clock restarted and the rail did not")
        presenter.dismiss()
    }

    /// Under Reduce Motion the rail goes rather than freezing full: a still line is not a slower
    /// countdown, it is a band claiming a clock it is not showing. The dwell is unchanged.
    func testReduceMotionTakesTheRailAwayAndLeavesTheClockAlone() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)

        XCTAssertFalse(toast.showsDwellCountdown)
        XCTAssertTrue(toast.isDwellRunning, "Reduce Motion shortened the band's life instead")
        presenter.dismiss()
    }

    // MARK: - A burst

    /// Four archives in a row are four separate ways back. A receipt overwritten a moment after
    /// it lands is one whose action nobody ever gets to press — and that action is the whole
    /// reason the archive stopped asking first.
    func testAReceiptWithAWayBackIsQueuedRatherThanOverwritten() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        var undone: [String] = []
        presenter.present(archiveRequest(message: "Archived “One”") { undone.append("One") })
        presenter.present(archiveRequest(message: "Archived “Two”") { undone.append("Two") })

        XCTAssertEqual(presenter.current?.request.message, "Archived “One”")
        XCTAssertEqual(presenter.queued.map(\.message), ["Archived “Two”"])
        XCTAssertEqual(
            descendants(of: host).compactMap { $0 as? ToastView }.count,
            1,
            "both bands were on screen at once"
        )

        // The first leaves — its clock, its button, it makes no difference — and the second
        // takes the pane it was holding.
        presenter.dismiss()
        waitForRunLoop(0.2)
        let second = try XCTUnwrap(presenter.current)
        XCTAssertEqual(second.request.message, "Archived “Two”")
        XCTAssertTrue(presenter.queued.isEmpty)

        try XCTUnwrap(buttons(in: second).first).performClick()
        XCTAssertEqual(undone, ["Two"], "the queue ran the wrong receipt's undo")
    }

    /// Nothing to lose, so nothing waits: the newer report is the one that describes the state
    /// the user is in — the navigator's error arriving behind its own progress line.
    func testAReceiptWithNothingToOfferIsReplacedWhereItStands() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)

        presenter.present(ToastRequest(message: "Loading the navigator"))
        presenter.present(ToastRequest(message: "The navigator extension stopped"))

        XCTAssertEqual(presenter.current?.request.message, "The navigator extension stopped")
        XCTAssertTrue(presenter.queued.isEmpty)
        XCTAssertEqual(descendants(of: host).compactMap { $0 as? ToastView }.count, 1)
    }

    /// A queue is measured in dwells, so it is bounded — and what falls off the end is the
    /// oldest receipt waiting, the one whose consequence the user has had longest to notice.
    func testABurstLongerThanTheQueueKeepsTheMostRecentReceipts() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        for index in 0...(ToastDefaults.queueLimit + 2) {
            presenter.present(archiveRequest(message: "Archived “\(index)”"))
        }

        XCTAssertEqual(presenter.current?.request.message, "Archived “0”")
        XCTAssertEqual(presenter.queued.count, ToastDefaults.queueLimit)
        XCTAssertEqual(
            presenter.queued.last?.message,
            "Archived “\(ToastDefaults.queueLimit + 2)”",
            "the newest receipt was the one dropped"
        )
        presenter.dismiss()
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
