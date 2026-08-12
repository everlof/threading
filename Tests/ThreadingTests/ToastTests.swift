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
///
/// **Every test that sets a long `dwell` must end with `presenter.invalidate()`**, and this is
/// not tidiness. The dwell is a real `Timer` on the main run loop. `deinit` cancels it, but
/// `invalidate()`'s own documentation says why that is not enough here: AppKit may extend a
/// local object's lifetime past its lexical scope while its layer work is committed, so a
/// presenter left to fall out of scope can still be alive with a 30-second timer armed. What
/// fires 30 seconds later fires inside whatever *other* test is running by then, against a
/// fixture that has been torn down.
///
/// It read exactly like an environment problem: `ToastTests` dying mid-run with no crash report
/// and no failing assertion, passing whenever it was run on its own, and naming a different test
/// than the one that armed the timer. Four tests here already called `invalidate()`; five did
/// not, and those five are the ones that set `dwell = 30`.
@MainActor
final class ToastTests: XCTestCase {

    private var previousTheme: AppTheme!
    /// `NSView.window` is weak. Most tests need only the host and anchor, but the never-shown
    /// window must still outlive the run-loop work they exercise or AppKit can tear its graphics
    /// context down while a toast is being committed.
    private var fixtureWindows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        previousTheme = AppThemeLibrary.current
        Design.Motion.reduceMotionOverrideForTesting = true
    }

    override func tearDown() {
        AppThemeLibrary.apply(previousTheme)
        Design.Motion.reduceMotionOverrideForTesting = nil
        fixtureWindows.removeAll()
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
        fixtureWindows.append(window)
        return (host, footer.topAnchor, window)
    }

    /// The same pane, held at a width the way a split view holds the sidebar's: by a constraint
    /// a shade above `defaultLow`, which anything inside the column can outrank and push.
    private func column(
        width: CGFloat,
        footerLeading: [NSView] = []
    ) -> (
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

        let footer = PaneFooterView(leading: footerLeading, margin: .paneEdge)
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
        fixtureWindows.append(window)
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
    ///
    /// It still has a way out, and the band is still tall enough to hold it: one short line of
    /// text is shorter than the ✕ beside it, so without a floor the corner control would hang out
    /// of the card it belongs to.
    func testAToastWithoutAnActionDrawsNoButton() throws {
        let toast = ToastView(request: ToastRequest(message: "Archived “Parser”"))

        XCTAssertTrue(buttons(in: toast).isEmpty)
        XCTAssertFalse(toast.request.hasAction)

        toast.frame = NSRect(x: 0, y: 0, width: 220, height: 0)
        toast.frame.size.height = toast.fittingSize.height
        toast.layoutSubtreeIfNeeded()

        let close = try XCTUnwrap(iconButtons(in: toast).first)
        XCTAssertTrue(
            toast.bounds.contains(close.frame),
            "the way out hangs off a band with only one line on it"
        )
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

    /// The same rule from the other side: the divider has no maximum, so a column can be dragged
    /// far wider than the app ever opens it. The band spans that column too — it once stopped at
    /// a 320-point cap and left the rest of the column empty beside it, which read as a card
    /// stranded next to the list it was reporting on — and the column keeps the width it had,
    /// because the fill pin is still weaker than the column's own hold on itself.
    func testTheBandSpansAColumnDraggedWideWithoutResizingIt() throws {
        let width = SidebarDefaults.maxWidth + 60
        let (column, bottom, _) = column(width: width)
        let presenter = ToastPresenter(host: column, above: bottom)

        presenter.present(archiveRequest())
        column.superview?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            column.frame.width,
            width,
            accuracy: 0.5,
            "the band's fill pin dragged the column in to meet the band"
        )
        XCTAssertEqual(
            try XCTUnwrap(presenter.current).frame.width,
            width - ToastDefaults.hostInset * 2,
            accuracy: 0.5,
            "the band stopped short of the column instead of spanning it"
        )
    }

    /// A receipt is a band, not a bubble: in a column with more room than its words need, it
    /// still fills the width it is given. The words are silenced in *both* directions — a
    /// label's hugging outranking the fill pin would shrink-wrap the band to whatever its
    /// message happened to be.
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

    /// The band stands on the same leading edge as the footer directly under it.
    ///
    /// Its inset was `Spacing.medium` while the footer stands its first control's ink at
    /// `Spacing.inset`, so the card's edge sat two points inside the gear it was stacked on —
    /// close enough to read as a miss rather than as a decision. Asserted against the footer's
    /// own answer rather than against the number, because the number is the thing that drifted.
    func testTheBandStandsOnTheFootersLeadingInk() throws {
        let settings = ThemedButton()
        settings.title = "Settings"
        settings.isBordered = false
        let (column, bottom, _) = column(
            width: SidebarDefaults.defaultWidth,
            footerLeading: [settings]
        )
        let presenter = ToastPresenter(host: column, above: bottom)

        presenter.present(archiveRequest())
        column.superview?.layoutSubtreeIfNeeded()

        let toast = try XCTUnwrap(presenter.current)
        XCTAssertEqual(
            toast.frame.minX,
            settings.frame.minX + settings.opticalHorizontalInset,
            accuracy: 0.5,
            "the band's edge missed the ink column the footer under it aligns down"
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
            toast.frame.maxX,
            host.bounds.width - ToastDefaults.hostInset + 0.5,
            "the band overhung the pane it floats in"
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

        XCTAssertEqual(presenter.scheduledDwell, 30)
        XCTAssertNotNil(
            presenter.current,
            "the band left on the pane's clock instead of on its own"
        )
        presenter.invalidate()
    }

    /// A presenter belongs to its pane owner, not to the run loop. Tearing that owner down must
    /// synchronously cancel both clocks and layer work rather than leaving an off-screen render
    /// committed against a view tree that no longer exists.
    func testPresenterTeardownStopsTheClockAndRemovesTheBand() {
        let (host, bottom, _) = pane()
        var presenter: ToastPresenter? = ToastPresenter(host: host, above: bottom)
        var request = archiveRequest()
        request.dwell = 30
        presenter?.present(request)

        let toast = presenter?.current
        XCTAssertNotNil(toast)

        presenter?.invalidate()

        XCTAssertNil(toast?.superview)
        XCTAssertFalse(host.subviews.contains { $0 is ToastView })
        presenter = nil
    }

    /// A way back that expires while it is being reached for is worse than no way back, because
    /// the reach is the moment the decision was already made.
    ///
    /// Asserted on the clock rather than by waiting out the dwell: a test's pointer is wherever
    /// the developer left it, so the band's own staleness correction — right in the app, where
    /// the pointer really is on it — would take a synthesised hover straight back off again.
    func testThePointerHoldsTheBandsClockAndReleasingItPutsTheBandBackOnOne() throws {
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

    /// The pointer *pauses* the dwell rather than refunding it. A band released after being leant
    /// on goes back on the clock it came off: crossing a receipt on the way somewhere else must
    /// not buy it a second full dwell, and a band leant on twice would then never have to leave.
    func testReleasingTheBandResumesItsClockRatherThanRestartingIt() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)
        XCTAssertEqual(presenter.scheduledDwell, 30)

        let spent: TimeInterval = 0.3
        waitForRunLoop(spent)
        toast.mouseEntered(with: NSEvent())

        // Held time is not spent time: were it charged, what is left below would be short by this
        // as well, which is what tells the two apart.
        let held: TimeInterval = 0.5
        waitForRunLoop(held)
        toast.mouseExited(with: NSEvent())

        let resumed = try XCTUnwrap(presenter.scheduledDwell)
        XCTAssertLessThan(
            resumed,
            presenter.dwell - spent / 2,
            "the pointer leaving handed the band a fresh dwell"
        )
        XCTAssertGreaterThan(
            resumed,
            presenter.dwell - spent - held / 2,
            "the band was charged for the time the pointer held it"
        )
        presenter.invalidate()
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
        XCTAssertTrue(toast.isDwellRunning, "the clock resumed and the rail did not")
        presenter.dismiss()
        presenter.invalidate()
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
        presenter.invalidate()
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
        presenter.invalidate()
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
        presenter.invalidate()
    }

    // MARK: - The stack

    /// A band with something waiting behind it must not look like the last thing that happened.
    /// The queue is why a receipt is never thrown away, and undrawn it is a promise nobody can
    /// see: the user who turns away as the first band lands is turning away from more than one.
    func testAWaitingReceiptStandsBehindTheBandAsACardEdge() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest(message: "Archived “One”"))
        XCTAssertTrue(presenter.stackEdges.isEmpty, "a band with nothing behind it drew a stack")

        presenter.present(archiveRequest(message: "Archived “Two”"))
        host.layoutSubtreeIfNeeded()

        let toast = try XCTUnwrap(presenter.current)
        let edge = try XCTUnwrap(presenter.stackEdges.first)
        XCTAssertEqual(presenter.stackEdges.count, 1, "one waiting receipt, one edge")
        XCTAssertGreaterThan(
            edge.frame.maxY,
            toast.frame.maxY,
            "the edge is entirely behind the band, so nothing says another is coming"
        )
        XCTAssertLessThan(
            edge.frame.width,
            toast.frame.width,
            "the card behind is as wide as the one in front, which reads as one thick band"
        )
        XCTAssertEqual(
            edge.frame.midX,
            toast.frame.midX,
            accuracy: 0.5,
            "stepped in on one side only, the stack reads as a band slipping rather than a deck"
        )

        // The deck lives in the presenter's lane, so the z-order that carries the illusion is
        // the lane's subview order.
        let order = try XCTUnwrap(toast.superview).subviews
        XCTAssertLessThan(
            try XCTUnwrap(order.firstIndex(of: edge)),
            try XCTUnwrap(order.firstIndex(of: toast)),
            "the waiting receipt drew over the one being read"
        )
        presenter.invalidate()
    }

    /// The stack answers *is this the only one*, not *how many* — and it is the only honest
    /// answer, since the queue drops from the front when a burst overruns its bound.
    func testTheStackStopsAtItsDepthHoweverManyAreWaiting() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        for index in 0...(ToastDefaults.queueLimit + 1) {
            presenter.present(archiveRequest(message: "Archived “\(index)”"))
        }
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(presenter.queued.count, ToastDefaults.queueLimit)
        XCTAssertEqual(presenter.stackEdges.count, ToastDefaults.stackDepth)

        // Each one further up and further in than the one in front of it, and behind it in the
        // lane — three facts that are the same illusion.
        let cards: [NSView] = [try XCTUnwrap(presenter.current)] + presenter.stackEdges
        let order = try XCTUnwrap(presenter.current?.superview).subviews
        for (front, behind) in zip(cards, cards.dropFirst()) {
            XCTAssertGreaterThan(behind.frame.maxY, front.frame.maxY)
            XCTAssertLessThan(behind.frame.width, front.frame.width)
            XCTAssertLessThan(
                try XCTUnwrap(order.firstIndex(of: behind)),
                try XCTUnwrap(order.firstIndex(of: front))
            )
        }
        presenter.invalidate()
    }

    /// The stack thins as the queue does, and the last band stands alone — an edge left behind a
    /// receipt with nothing after it promises a report that never arrives.
    func testTheStackThinsAsTheQueueDoesAndLeavesWithTheLastBand() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        for index in 0..<3 {
            presenter.present(archiveRequest(message: "Archived “\(index)”"))
        }
        XCTAssertEqual(presenter.stackEdges.count, 2)

        presenter.dismiss()
        waitForRunLoop(0.2)
        XCTAssertEqual(presenter.current?.request.message, "Archived “1”")
        XCTAssertEqual(presenter.stackEdges.count, 1, "the stack kept an edge for a receipt shown")

        presenter.dismiss()
        waitForRunLoop(0.2)
        XCTAssertEqual(presenter.current?.request.message, "Archived “2”")
        XCTAssertTrue(presenter.stackEdges.isEmpty)

        presenter.dismiss()
        waitForRunLoop(0.2)
        XCTAssertNil(presenter.current)
        XCTAssertEqual(host.subviews.count, 1, "the stack outlived every band it stood behind")
        presenter.invalidate()
    }

    /// Teardown takes the stack with the band, synchronously — the presenter's own reason for
    /// `invalidate()`, and the edges are pinned to a band that is about to stop existing.
    func testTeardownTakesTheStackWithTheBand() {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest(message: "Archived “One”"))
        presenter.present(archiveRequest(message: "Archived “Two”"))
        XCTAssertEqual(presenter.stackEdges.count, 1)

        presenter.invalidate()

        XCTAssertTrue(presenter.stackEdges.isEmpty)
        XCTAssertEqual(host.subviews.count, 1, "an edge was left standing behind nothing")
    }

    // MARK: - The deck, opened

    /// A queue whose size you can see and whose contents you cannot tells you only that you are
    /// behind. Opened, the deck is the *whole* queue — including the receipt the resting stack
    /// keeps no edge for, because two of three is the dishonest answer once each card has words.
    func testOpeningTheDeckLiftsEveryWaitingReceiptAndNamesIt() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        for index in 0...ToastDefaults.queueLimit {
            presenter.present(archiveRequest(message: "Archived “\(index)”"))
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(presenter.stackEdges.count, ToastDefaults.stackDepth)

        presenter.openDeck(true)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(presenter.isDeckOpen)
        XCTAssertEqual(
            presenter.stackEdges.count,
            ToastDefaults.queueLimit,
            "the open deck stood fewer cards than there are receipts waiting"
        )
        XCTAssertEqual(
            presenter.stackEdges.compactMap { labelTexts(in: $0).first },
            presenter.queued.map(\.message),
            "the open deck named its receipts in an order the queue does not have"
        )

        // Each card uncovers exactly one step of itself, which is the strip its line is read in.
        let cards: [NSView] = [try XCTUnwrap(presenter.current)] + presenter.stackEdges
        for (front, behind) in zip(cards, cards.dropFirst()) {
            XCTAssertEqual(
                behind.frame.maxY - front.frame.maxY,
                ToastDefaults.peekStep,
                accuracy: 0.5,
                "a card in the open deck stands where its own words cannot be read"
            )
        }

        presenter.openDeck(false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            presenter.stackEdges.count,
            ToastDefaults.stackDepth,
            "the closed deck kept the card it only stands while it is open"
        )
        presenter.invalidate()
    }

    /// Opening a deck with nothing in it is not an empty fan, it is nothing: there is no card to
    /// lift, and the grip the pointer would have reached into is not there either.
    func testTheDeckDoesNotOpenOverABandWithNothingBehindIt() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        presenter.openDeck(true)

        XCTAssertFalse(presenter.isDeckOpen)
        XCTAssertTrue(presenter.stackEdges.isEmpty)
        presenter.invalidate()
    }

    /// The point of opening the deck: the way back people wanted was on the third card, not the
    /// first. Pressing it takes that receipt back and leaves the band in front alone — it is
    /// reporting something else.
    func testAWaitingCardCarriesTheWayBackOfTheReceiptItStandsFor() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        var undone: [String] = []
        presenter.present(archiveRequest(message: "Archived “Band”"))
        presenter.present(archiveRequest(message: "Archived “One”", undo: { undone.append("One") }))
        presenter.present(archiveRequest(message: "Archived “Two”", undo: { undone.append("Two") }))
        presenter.openDeck(true)
        host.layoutSubtreeIfNeeded()

        let second = try XCTUnwrap(presenter.stackEdges.last)
        try XCTUnwrap(buttons(in: second).first).performClick()
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(undone, ["Two"], "the way back on a card took a different card's receipt")
        XCTAssertEqual(presenter.queued.map(\.message), ["Archived “One”"])
        XCTAssertEqual(
            presenter.current?.request.message,
            "Archived “Band”",
            "taking back a waiting receipt took the band in front with it"
        )
        XCTAssertEqual(presenter.stackEdges.count, 1)
        presenter.invalidate()
    }

    /// Taking back the last one leaves nothing to stand: the deck closes itself rather than
    /// hanging an empty fan over a band whose clock it is still holding.
    func testTakingBackTheLastWaitingReceiptClosesTheDeckAndStartsTheClock() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest(message: "Archived “Band”"))
        presenter.present(archiveRequest(message: "Archived “One”", undo: {}))
        presenter.openDeck(true)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(presenter.isHeldOpen)

        let card = try XCTUnwrap(presenter.stackEdges.first)
        try XCTUnwrap(buttons(in: card).first).performClick()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(presenter.queued.isEmpty)
        XCTAssertTrue(presenter.stackEdges.isEmpty)
        XCTAssertFalse(presenter.isDeckOpen)
        XCTAssertFalse(presenter.isHeldOpen, "the band's clock stayed stopped under an empty deck")
        presenter.invalidate()
    }

    /// The fan is pinned to the band under it and every card in it carries a way back, so the
    /// clock stops while it is open — and goes back on the remainder it came off, not on a fresh
    /// dwell, for the same reason a held band does.
    func testTheOpenDeckHoldsTheBandsClockAndGivesBackItsRemainder() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest(message: "Archived “Band”"))
        presenter.present(archiveRequest(message: "Archived “One”"))
        XCTAssertFalse(presenter.isHeldOpen)
        waitForRunLoop(0.2)

        presenter.openDeck(true)
        XCTAssertTrue(presenter.isHeldOpen, "the deck opened over a clock that kept running")

        presenter.openDeck(false)
        XCTAssertFalse(presenter.isHeldOpen)
        XCTAssertLessThan(
            try XCTUnwrap(presenter.scheduledDwell),
            30,
            "the band went back on a whole fresh dwell rather than on what was left of its own"
        )
        presenter.invalidate()
    }

    /// The deck is drawn against the band — every card is pinned to its edges — so a band leaving
    /// takes the fan with it rather than leaving a list hanging over the slot its own successor
    /// is rising into.
    func testTheDeckClosesWithTheBandItWasFannedAbove() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        for index in 0..<3 {
            presenter.present(archiveRequest(message: "Archived “\(index)”"))
        }
        presenter.openDeck(true)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(presenter.isDeckOpen)

        presenter.dismiss()
        waitForRunLoop(0.2)

        XCTAssertFalse(presenter.isDeckOpen)
        XCTAssertEqual(presenter.current?.request.message, "Archived “1”")
        XCTAssertEqual(presenter.stackEdges.count, 1)
        presenter.invalidate()
    }

    /// A card in the deck is read out only while it is readable. At rest it is a four-point
    /// sliver standing for a receipt VoiceOver is already promised when its turn comes; open, it
    /// is the receipt, and the ear should be able to reach what the eye just did.
    func testAWaitingCardIsAnAccessibilityElementOnlyWhileTheDeckIsOpen() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest(message: "Archived “Band”"))
        presenter.present(archiveRequest(message: "Archived “One”"))
        host.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(presenter.stackEdges.first)
        XCTAssertFalse(card.isAccessibilityElement())

        presenter.openDeck(true)
        XCTAssertTrue(card.isAccessibilityElement())
        XCTAssertEqual(card.accessibilityLabel(), presenter.queued.first?.announcement)

        presenter.openDeck(false)
        XCTAssertFalse(card.isAccessibilityElement())
        presenter.invalidate()
    }

    /// The region that opens the deck lies over the whole fan, so a pointer travelling up it
    /// never leaves the thing holding it open — and it must therefore take no click at all, or it
    /// would be the surface every way back in the deck was pressed through.
    func testTheGripCoversTheDeckAndTakesNoClickOffIt() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest(message: "Archived “Band”"))
        presenter.present(archiveRequest(message: "Archived “One”", undo: {}))
        presenter.openDeck(true)
        host.layoutSubtreeIfNeeded()

        let band = try XCTUnwrap(presenter.current)
        let lane = try XCTUnwrap(band.superview)
        let card = try XCTUnwrap(presenter.stackEdges.first)
        let cards = Set(presenter.stackEdges.map { ObjectIdentifier($0) })
        let grip = try XCTUnwrap(
            lane.subviews.first {
                $0 !== band && !cards.contains(ObjectIdentifier($0))
            },
            "the open deck had no grip over it"
        )

        XCTAssertGreaterThanOrEqual(
            grip.frame.maxY,
            band.frame.maxY,
            "the grip started above the band it opens the deck over"
        )
        XCTAssertGreaterThanOrEqual(
            grip.frame.maxY,
            card.frame.maxY,
            "a pointer on the top card of the fan is outside the region holding the fan open"
        )
        XCTAssertNil(
            grip.hitTest(NSPoint(x: grip.frame.midX, y: grip.frame.midY)),
            "the grip took a click of its own"
        )

        // The way back on the card under it is still what a press there lands on.
        let button = try XCTUnwrap(buttons(in: card).first)
        let centre = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        let hit = lane.hitTest(button.convert(centre, to: host))
        XCTAssertTrue(
            hit?.isDescendant(of: card) ?? false,
            "the grip swallowed the press aimed at a waiting receipt's way back"
        )
        presenter.invalidate()
    }

    // MARK: - The lane

    /// The lane the deck rides in stretches over the whole pane, and covering is all it may do:
    /// a click on a card is the card's, and a click anywhere else belongs to the list the lane
    /// is stretched over. Without the pass-through, presenting one receipt would make an entire
    /// sidebar unclickable for six seconds — invisibly, since the lane draws nothing to blame.
    func testTheLaneTakesNoClickOfItsOwn() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        host.layoutSubtreeIfNeeded()
        let toast = try XCTUnwrap(presenter.current)
        let lane = try XCTUnwrap(toast.superview)

        let onBand = lane.convert(
            NSPoint(x: toast.frame.midX, y: toast.frame.midY),
            to: host
        )
        let hit = try XCTUnwrap(lane.hitTest(onBand))
        XCTAssertTrue(
            hit === toast || hit.isDescendant(of: toast),
            "a click on the band went somewhere other than the band"
        )

        let clear = NSPoint(x: host.bounds.midX, y: host.bounds.maxY - Design.Spacing.medium)
        XCTAssertNil(
            lane.hitTest(clear),
            "the lane swallowed a click meant for the pane under it"
        )
        presenter.invalidate()
    }

    /// The lane crops only while a card is actually crossing the pane's edge. At rest it must
    /// not: a theme may hang up to the glow gutter of shadow off a card, and a lane cropping at
    /// rest would slice that shade off every receipt for the sake of a transition that is not
    /// running.
    func testTheLaneCropsDuringTheArrivalAndNotAtRest() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let lane = try XCTUnwrap(presenter.current?.superview)
        XCTAssertEqual(
            lane.layer?.masksToBounds,
            true,
            "a band still below the pane's edge is showing over whatever is down there"
        )

        waitForRunLoop(Design.Motion.travel + 0.2)
        XCTAssertEqual(
            lane.layer?.masksToBounds,
            false,
            "the lane kept cropping after the band settled"
        )
        presenter.invalidate()
    }

    // MARK: - The way out

    /// The ✕ is a real control, for the reason the way back is one: it is what gives the way out
    /// a keyboard route and an accessible name without this view stating either.
    ///
    /// It is also **not** hidden until the pointer arrives, which is a tab's grammar and the wrong
    /// one here — hovering this band stops its clock, so a ✕ that had to be discovered by hovering
    /// would answer "make this go away" by making it stay.
    func testTheBandCarriesAWayOutBesideTheWayBack() throws {
        let toast = ToastView(request: archiveRequest())
        let close = try XCTUnwrap(iconButtons(in: toast).first)

        XCTAssertFalse(close.isHidden, "the way out has to be found before it can be pressed")
        XCTAssertTrue(close.isAccessibilityElement())
        XCTAssertTrue(close.canBecomeKeyView || close.acceptsFirstResponder)
        XCTAssertEqual(close.accessibilityIdentifier(), "sidebar.toast.archive.dismiss")
        XCTAssertEqual(
            close.accessibilityTitle(),
            L10n.string("Dismiss"),
            "VoiceOver is told what the mark in the corner does"
        )
    }

    /// **Pressing the ✕ takes the band and nothing else.** The receipt's own action is the one
    /// thing on it that changes the world back, and a way out that ran it would archive-and-undo
    /// on a gesture that means neither.
    func testTheWayOutTakesTheBandWithoutRunningItsAction() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        var undone = 0
        presenter.present(archiveRequest(undo: { undone += 1 }))
        let toast = try XCTUnwrap(presenter.current)
        try XCTUnwrap(iconButtons(in: toast).first).onPress?()

        XCTAssertEqual(undone, 0, "the way out took the way back with it")
        XCTAssertNil(presenter.current)
        XCTAssertFalse(host.subviews.contains { $0 is ToastView })
        presenter.invalidate()
    }

    /// The message stops short of the ✕ and the fine print runs underneath it, rather than the
    /// whole text block being held to the narrower column: only the first line is beside the mark,
    /// and 26 points off every line of a 240-point receipt is a paragraph reflowed for a corner.
    func testTheWordsClearTheWayOutAndTheDetailRunsUnderIt() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)
        host.layoutSubtreeIfNeeded()

        let close = try XCTUnwrap(iconButtons(in: toast).first)
        let labels = descendants(of: toast).compactMap { $0 as? NSTextField }
        let message = try XCTUnwrap(labels.first { $0.stringValue.contains("Refactor") })
        let detail = try XCTUnwrap(labels.first { $0.stringValue.contains("Settings") })

        XCTAssertLessThanOrEqual(
            message.frame.maxX,
            close.frame.minX,
            "the message runs under the mark in the corner"
        )
        XCTAssertGreaterThan(
            detail.frame.maxX,
            message.frame.maxX,
            "the fine print was reflowed to clear a button it passes below"
        )
        // The band is not flipped, so "under the ✕" is a smaller y: the detail's top edge stands
        // at or below the button's bottom one.
        XCTAssertLessThanOrEqual(
            detail.frame.maxY,
            close.frame.minY,
            "the detail starts beside the ✕ instead of under it"
        )
        presenter.invalidate()
    }

    /// **Each line is wrapped against the width it actually has.** A receipt names a session, and
    /// a session's name is as long as the user made it — so the band wraps. One wrap width derived
    /// from the band's own bounds stopped being right the moment the ✕ took 26 points off the
    /// message and none off the detail: the message believed it had room it did not have, laid
    /// itself out as a single line, and the band clipped the rest. It read “Archived “Refactor”,
    /// with the session's name simply missing and nothing in any assertion to say so.
    func testEachLineIsWrappedAgainstTheWidthItActuallyHas() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest(message: "Archived “Refactor the parser front to back”"))
        let toast = try XCTUnwrap(presenter.current)
        host.layoutSubtreeIfNeeded()

        let labels = descendants(of: toast).compactMap { $0 as? NSTextField }
        let message = try XCTUnwrap(labels.first { $0.stringValue.contains("Refactor") })
        let detail = try XCTUnwrap(labels.first { $0.stringValue.contains("Settings") })

        for label in [message, detail] {
            XCTAssertEqual(
                label.preferredMaxLayoutWidth,
                label.frame.width,
                accuracy: 0.5,
                "measured against a width the band never gave it, so it clips instead of wrapping"
            )
        }

        let line = try XCTUnwrap(message.font).boundingRectForFont.height
        XCTAssertGreaterThan(
            message.frame.height,
            line * 1.5,
            "a message too long for the column was laid out on one line and cut off"
        )
        presenter.invalidate()
    }

    /// **The band is as tall as the text it draws, in every face a theme can put on it.** The bug
    /// this pins was a font rather than a layout: `intrinsicContentSize` and the cell that actually
    /// typesets a label can disagree about whether a string wraps, and at a width it very nearly
    /// fits they do. Under Claymorphism's rounded face the same receipt reported 175 points on one
    /// line — inside the 178 it had — while the cell broke it in two at exactly 178. The band was
    /// built one line tall and clipped the rest, and every assertion about widths and insets
    /// passed while the session's name was missing from the picture.
    func testTheBandIsAsTallAsTheTextItDrawsUnderEveryStockTheme() throws {
        let themes: [(name: String, theme: AppTheme)] = [
            ("system", .system),
            ("cyberpunk", AppThemeStyles.cyberpunk),
            ("swiss", AppThemeStyles.swissMinimalist),
            ("claymorphism", AppThemeStyles.claymorphism),
            ("win98", AppThemeStyles.win98)
        ]
        defer { AppThemePalette.set(.system) }

        for (name, theme) in themes {
            AppThemePalette.set(theme)
            let (host, bottom, _) = pane()
            let presenter = ToastPresenter(host: host, above: bottom)
            presenter.dwell = 30

            presenter.present(archiveRequest())
            let toast = try XCTUnwrap(presenter.current)
            host.layoutSubtreeIfNeeded()

            for label in descendants(of: toast).compactMap({ $0 as? NSTextField }) {
                let drawn = try XCTUnwrap(label.cell).cellSize(
                    forBounds: NSRect(
                        x: 0,
                        y: 0,
                        width: label.frame.width,
                        height: .greatestFiniteMagnitude
                    )
                ).height
                XCTAssertGreaterThanOrEqual(
                    label.frame.height,
                    drawn - 0.5,
                    "\(name) draws “\(label.stringValue)” taller than the room it was given"
                )
            }
            presenter.invalidate()
        }
    }

    // MARK: - The throw

    /// A push that stops short of the commit point is not a throw: the band goes back exactly
    /// where the presenter put it, because a receipt nudged by a hand on its way past must not be
    /// left sitting an inch out of the corner it belongs in.
    func testAShortPushSpringsTheBandBackWhereItWas() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)

        toast.carryBegan()
        toast.carryChanged(to: 20, at: 0)
        toast.carryChanged(to: 30, at: 1)
        toast.carryEnded()

        XCTAssertEqual(presenter.current, toast, "a nudge threw the band away")
        XCTAssertEqual(toast.carryOffset, 0, "the band was left standing where it was pushed to")
        presenter.invalidate()
    }

    /// Carried far enough, letting go throws it out — and it leaves the way it was going rather
    /// than dropping back down the way it arrived.
    func testCarryingTheBandPastItsCommitPointThrowsItOut() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)
        host.layoutSubtreeIfNeeded()

        var departure: ToastDeparture?
        let onDismiss = try XCTUnwrap(toast.onDismiss)
        toast.onDismiss = { sent in
            departure = sent
            onDismiss(sent)
        }

        toast.carryBegan()
        toast.carryChanged(to: toast.bounds.width, at: 0)
        toast.carryEnded()

        XCTAssertEqual(departure, .thrown(direction: 1))
        XCTAssertNil(presenter.current)
        XCTAssertFalse(host.subviews.contains { $0 is ToastView })
        presenter.invalidate()
    }

    /// **A flick throws it from wherever it got to.** The gesture somebody makes at a band they
    /// want gone is short and fast and lets go early, so distance alone would refuse exactly the
    /// throws that were meant — and accept only the slow deliberate shove nobody performs.
    func testAFlickThrowsTheBandWithoutCarryingItAllTheWay() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)
        host.layoutSubtreeIfNeeded()

        let short = -toast.bounds.width / 8
        toast.carryBegan()
        toast.carryChanged(to: short / 2, at: 0)
        toast.carryChanged(to: short, at: 0.02)
        XCTAssertLessThan(abs(short), toast.bounds.width * ToastDefaults.throwCommitFraction)

        toast.carryEnded()
        XCTAssertNil(presenter.current, "a flick left the band sitting there")
        presenter.invalidate()
    }

    /// Speed counts only in the direction the band is already going. A hand that pushes the band
    /// out and pulls it back has changed its mind, and throwing on that would send the receipt out
    /// of the side it was just rescued from.
    func testAFlickBackTowardsTheRestPositionIsNotAThrow() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)
        host.layoutSubtreeIfNeeded()

        let short = toast.bounds.width * ToastDefaults.throwCommitFraction - 1
        toast.carryBegan()
        toast.carryChanged(to: short, at: 0)
        toast.carryChanged(to: short / 4, at: 0.02)
        toast.carryEnded()

        XCTAssertEqual(presenter.current, toast, "pulling the band back threw it away")
        XCTAssertEqual(toast.carryOffset, 0)
        presenter.invalidate()
    }

    /// A carry holds the clock exactly as the pointer does, and for a stronger version of the same
    /// reason: a band that expired halfway through the gesture aimed at it would be dismissed by
    /// its own dwell while somebody was still deciding.
    func testCarryingTheBandStopsItsClockAndPuttingItBackStartsItAgain() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)
        XCTAssertFalse(presenter.isHeldOpen)

        toast.carryBegan()
        XCTAssertTrue(presenter.isHeldOpen, "the band kept counting down under the hand on it")
        XCTAssertTrue(toast.isCarried)

        toast.carryChanged(to: 10, at: 0)
        toast.carryEnded()
        XCTAssertFalse(presenter.isHeldOpen, "the clock never restarted, so the band is forever")
        presenter.invalidate()
    }

    /// A pointer resting on a band its own carry already holds is not a second hold. The presenter
    /// keeps what is *left* of a paused clock, and being handed the pause twice would spend the
    /// remainder against itself.
    func testAPointerOnACarriedBandDoesNotHoldItTwice() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest())
        let toast = try XCTUnwrap(presenter.current)

        toast.mouseEntered(with: NSEvent())
        toast.carryBegan()
        toast.carryChanged(to: 10, at: 0)
        toast.carryEnded()

        XCTAssertTrue(presenter.isHeldOpen, "the pointer is still on the band and lost its hold")
        toast.mouseExited(with: NSEvent())
        XCTAssertFalse(presenter.isHeldOpen)
        presenter.invalidate()
    }

    /// Throwing one hands the pane to whatever was waiting, exactly as running out of time does:
    /// the queue is about what is owed to the user, not about how the band in front of it went.
    func testThrowingABandHandsThePaneToWhateverWasWaiting() throws {
        let (host, bottom, _) = pane()
        let presenter = ToastPresenter(host: host, above: bottom)
        presenter.dwell = 30

        presenter.present(archiveRequest(message: "Archived “First”"))
        presenter.present(archiveRequest(message: "Archived “Second”"))
        let first = try XCTUnwrap(presenter.current)
        host.layoutSubtreeIfNeeded()

        first.carryBegan()
        first.carryChanged(to: first.bounds.width, at: 0)
        first.carryEnded()

        let second = try XCTUnwrap(presenter.current)
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(second.request.message.contains("Second"))
        XCTAssertTrue(presenter.queued.isEmpty)
        presenter.invalidate()
    }

    /// The band takes the press rather than passing it up. An unhandled `mouseDown` walks the
    /// responder chain, and the pane a receipt floats in is the list the receipt is *about* — a
    /// press falling through it would reach the sidebar that just lost the row being reported on.
    func testAPressOnTheBandDoesNotReachThePaneUnderneath() throws {
        let pane = PressCountingView()
        let toast = ToastView(request: archiveRequest())
        pane.addSubview(toast)

        toast.mouseDown(with: try XCTUnwrap(press(at: NSPoint(x: 20, y: 20), at: 0)))
        toast.mouseUp(with: try XCTUnwrap(press(at: NSPoint(x: 20, y: 20), at: 0.1)))

        XCTAssertEqual(pane.presses, 0)
    }

    /// And it takes the pointer the same way it takes the press.
    ///
    /// `NSTrackingArea` reports crossings of a *rectangle* and knows nothing about what is drawn
    /// over it, so the row under the band was sent `mouseEntered` as though the band were not
    /// there — and a hovered sidebar row draws a wash. Because the row's highlight and the band
    /// are both inset from the column by `Design.Spacing.medium`, that wash lined up exactly with
    /// the band's sides and stood 6 points proud of its top edge: it read as a backplate the band
    /// owned, rounded to a corner that was not the band's.
    func testAPointerOnTheBandDoesNotHoverTheRowUnderneath() throws {
        let list = try list()

        // The band's frame is stated in its lane's coordinates, so the lane is what converts it.
        let covered = try XCTUnwrap(list.toast.superview).convert(
            NSPoint(x: list.toast.frame.midX, y: list.toast.frame.midY),
            to: nil
        )
        list.row.mouseEntered(with: try XCTUnwrap(enterEvent(at: covered)))

        XCTAssertFalse(
            list.row.isMouseInside,
            "A row under the band is not the thing the pointer is on"
        )
        list.presenter.invalidate()
    }

    /// The other half, so the fix cannot be "the sidebar stopped hovering": the same row, the same
    /// band, a point the band does not reach.
    func testARowStillHoversWhereTheBandDoesNotCoverIt() throws {
        let list = try list()

        // The band's frame is stated in its lane's coordinates, so the lane is what converts it.
        let clear = try XCTUnwrap(list.toast.superview).convert(
            NSPoint(x: list.toast.frame.midX, y: list.toast.frame.maxY + Design.Spacing.large),
            to: nil
        )
        list.row.mouseEntered(with: try XCTUnwrap(enterEvent(at: clear)))

        XCTAssertTrue(list.row.isMouseInside, "The row is still hovered where nothing covers it")
        list.presenter.invalidate()
    }

    // MARK: - Helpers

    /// A pane with a sidebar row across it and a receipt floating over the row's lower half —
    /// the arrangement the band is actually used in, since the presenter is what places the band
    /// and the row's own highlight inset is what made the overlap visible.
    private func list() throws -> (
        row: SidebarHoverRowView,
        toast: ToastView,
        host: NSView,
        presenter: ToastPresenter
    ) {
        let pane = pane()
        let row = SidebarHoverRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        pane.host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: pane.host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: pane.host.trailingAnchor),
            row.topAnchor.constraint(equalTo: pane.host.topAnchor),
            row.bottomAnchor.constraint(equalTo: pane.bottom)
        ])

        let presenter = ToastPresenter(host: pane.host, above: pane.bottom)
        presenter.present(archiveRequest())
        pane.host.layoutSubtreeIfNeeded()

        return (row, try XCTUnwrap(presenter.current), pane.host, presenter)
    }

    /// A crossing with a stated location. The rows read the location off the event rather than off
    /// the window, so a fixture can put the pointer somewhere without owning the real one.
    private func enterEvent(at location: NSPoint) -> NSEvent? {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
    }

    /// Stands behind the band and counts anything the responder chain hands it.
    private final class PressCountingView: NSView {
        var presses = 0
        override func mouseDown(with event: NSEvent) { presses += 1 }
    }

    /// A press with its own stated modifiers and clock. `NSEvent()` carries neither a location nor
    /// a timestamp, and a `CGEvent` built here would read the keyboard the developer's hands are
    /// on — a held Shift is not something a test gets to be surprised by.
    private func press(at location: NSPoint, at timestamp: TimeInterval) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    private func iconButtons(in view: NSView) -> [ThemedIconButton] {
        descendants(of: view).compactMap { $0 as? ThemedIconButton }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func buttons(in view: NSView) -> [ThemedButton] {
        descendants(of: view).compactMap { $0 as? ThemedButton }
    }

    private func labelTexts(in view: NSView) -> [String] {
        descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func waitForRunLoop(_ interval: TimeInterval) {
        let settled = expectation(description: "the run loop advanced")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { settled.fulfill() }
        wait(for: [settled], timeout: interval + 5)
    }
}
