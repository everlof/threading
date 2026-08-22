import SwiftTerm
import UIKit
import XCTest
@testable import ThreadingMobile

/// A mirrored agent TUI writes constantly, and SwiftTerm's iOS view pinned the viewport to the
/// bottom of the buffer on every one of those writes. Scrolling back through a working session
/// from the phone was therefore impossible: each line of output undid the drag before a finger
/// could finish it. The emulator has always had the seam for this — `Terminal.userScrolling`
/// holds `yDisp` above the live tail, and the Mac view has used it all along — so these cover
/// the iOS half now driving it.
@MainActor
final class RemoteTerminalScrollTests: XCTestCase {
    private var hostWindows: [UIWindow] = []

    // MARK: - Constants

    private enum Fixture {
        static let frame = CGRect(x: 0, y: 0, width: 420, height: 420)
        static let fontSize: CGFloat = 12
        /// Comfortably more rows than the view shows, and short of SwiftTerm's 500-line
        /// scrollback, so nothing is trimmed while the viewport is being held.
        static let lines = 300
        /// Past the scrollback cap, so every further line drops one off the top.
        static let overflowingLines = 900
        static let offsetTolerance: CGFloat = 0.5
        static let followUpLines = 20
        /// Enough output to have a screen, without the cost of building scrollback.
        static let shortRun = 10
        /// Button tracking plus SGR encoding, which is what an agent TUI turns on.
        static let enableSGRMouseTracking = "\u{1b}[?1000h\u{1b}[?1006h"
        static let disableMouseTracking = "\u{1b}[?1000l"
        /// Comfortably more than one line's worth of finger travel.
        static let dragDistance: CGFloat = 400
    }

    // MARK: - Tests

    /// A terminal push crosses two grid authorities: the Mac's current PTY grid arrives in
    /// `hello`, then an interactive phone takes ownership with the grid its final frame can
    /// display. Both travel through SwiftTerm's size delegate, but only the latter is a viewport
    /// lease. Reporting the authoritative resize echoed the Mac grid back between two identical
    /// phone requests and made Codex repaint three times on every push.
    @MainActor
    func testOnlyTheLocallyOwnedGridIsReportedAsAViewportLease() {
        let view = RemoteTerminalView(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let coordinator = TerminalViewRepresentable.Coordinator(
            connection: .demoTerminal(),
            allowsInput: true,
            keyBridge: TerminalKeyBridge(),
            initialScrollProgress: nil,
            onScrollProgress: { _ in }
        )
        coordinator.attach(to: view)
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder

        XCTAssertFalse(
            coordinator.reportsTerminalViewportChanges,
            "A pre-authentication layout is not a lease yet."
        )
        XCTAssertFalse(view.shouldReportSizeChange(newCols: 48, newRows: 41))

        // A desktop terminal can be wider than the phone viewport protocol accepts. Rendering
        // that host-owned grid is valid; echoing it as the phone's lease is not.
        view.setAuthoritativeGrid(cols: 268, rows: 83)

        XCTAssertFalse(
            coordinator.reportsTerminalViewportChanges,
            "Installing the Mac grid must never echo it back as the phone's request."
        )
        XCTAssertFalse(view.shouldReportSizeChange(newCols: 268, newRows: 83))
        XCTAssertTrue(
            recorder.sizeReports.isEmpty,
            "The suppression hook must reach SwiftTerm's delegate boundary, not merely answer false."
        )

        view.setUsesLocalViewport(true)
        let localGrid = view.terminalDimensions

        XCTAssertTrue(
            coordinator.reportsTerminalViewportChanges,
            "The final interactive phone grid owns the remote viewport."
        )
        XCTAssertTrue(view.shouldReportSizeChange(newCols: 48, newRows: 41))
        XCTAssertEqual(recorder.sizeReports, ["\(localGrid.cols)x\(localGrid.rows)"])
    }

    func testAFreshViewSitsAtTheLiveTail() {
        let view = makeView(feeding: Fixture.lines)

        XCTAssertTrue(view.canScroll, "300 lines into a 420pt view has to leave something above")
        XCTAssertGreaterThan(view.contentOffset.y, 0)
        XCTAssertEqual(view.scrollPosition, 1, accuracy: 0.001)
    }

    func testAViewportHeldAboveTheTailIsNotPulledBackByOutput() {
        let view = makeView(feeding: Fixture.lines)
        view.scroll(toPosition: 0)
        let topLine = visibleTopLine(of: view)
        XCTAssertEqual(view.contentOffset.y, 0, accuracy: Fixture.offsetTolerance)
        XCTAssertNotNil(topLine)

        for line in 0..<Fixture.followUpLines {
            view.feed(text: "later \(line)\r\n")
        }
        settleTerminalCallbacks(for: view)

        XCTAssertEqual(view.contentOffset.y, 0, accuracy: Fixture.offsetTolerance)
        XCTAssertEqual(view.terminalStateSnapshot().viewportRow, 0)
        XCTAssertEqual(visibleTopLine(of: view), topLine)
    }

    func testAViewportAtTheTailKeepsFollowingOutput() {
        let view = makeView(feeding: Fixture.lines)
        let before = view.contentOffset.y
        // The second visible row becomes the first one when the buffer scrolls by a line.
        let secondLine = view.terminalStateSnapshot().visibleRows
            .first(where: { $0.row == 1 })?.text
            .trimmingCharacters(in: .whitespaces)
        XCTAssertNotNil(secondLine)

        view.feed(text: "one more\r\n")
        settleTerminalCallbacks(for: view)

        XCTAssertGreaterThan(view.contentOffset.y, before)
        XCTAssertEqual(view.scrollPosition, 1, accuracy: 0.001)
        XCTAssertEqual(visibleTopLine(of: view), secondLine)
    }

    /// A drag reaches the emulator through `layoutSubviews`, which UIScrollView runs on every
    /// offset change. Without it the emulator still believes it is at the tail and resets the
    /// viewport on the next write, so the finger and the output fight each other.
    func testAnOffsetThisViewDidNotSetIsMirroredIntoTheEmulator() {
        let view = makeView(feeding: Fixture.lines)

        view.contentOffset = .zero
        view.setNeedsLayout()
        view.layoutIfNeeded()

        XCTAssertEqual(view.terminalStateSnapshot().viewportRow, 0)

        view.feed(text: "later\r\n")
        settleTerminalCallbacks(for: view)

        XCTAssertEqual(view.contentOffset.y, 0, accuracy: Fixture.offsetTolerance)
    }

    func testTypingRejoinsTheLiveTail() {
        let view = makeView(feeding: Fixture.lines)
        let tail = view.contentOffset.y
        view.scroll(toPosition: 0)

        view.send(txt: "hello")
        settleTerminalCallbacks(for: view)

        XCTAssertEqual(view.contentOffset.y, tail, accuracy: Fixture.offsetTolerance)

        view.feed(text: "later\r\n")
        settleTerminalCallbacks(for: view)

        XCTAssertGreaterThan(view.contentOffset.y, tail)
    }

    /// Once the scrollback is full the buffer no longer grows: every new line drops one off the
    /// top, and a held viewport has to move down with the text or the line being read slides
    /// away under it.
    func testHeldTextStaysPutWhileTheScrollbackTrims() {
        let view = makeView(feeding: Fixture.overflowingLines)
        view.scroll(toPosition: 0.5)
        let held = visibleTopLine(of: view)
        let offset = view.contentOffset.y
        XCTAssertNotNil(held)

        for line in 0..<Fixture.followUpLines {
            view.feed(text: "trimming \(line)\r\n")
        }
        settleTerminalCallbacks(for: view)

        XCTAssertEqual(visibleTopLine(of: view), held)
        XCTAssertLessThan(view.contentOffset.y, offset)
    }

    /// Claude's TUI tracks the mouse, and a program that tracks the mouse scrolls *its own*
    /// content when it is told the wheel turned. Reporting a finger as a press-and-drag instead
    /// moved nothing at all, which is what "I cannot scroll the TUI from my phone" looked like.
    func testAFingerDragIsReportedAsAWheelToAMouseTrackingProgram() {
        let view = makeView(feeding: Fixture.shortRun)
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: Fixture.enableSGRMouseTracking)
        settleTerminalCallbacks(for: view)
        XCTAssertNotEqual(view.terminalStateSnapshot().mouseMode, .off)

        view.forwardWheelDrag(distance: Fixture.dragDistance, gestureRecognizer: UIPanGestureRecognizer())
        settleTerminalCallbacks(for: view)

        XCTAssertTrue(recorder.text.contains("<64;"), "expected wheel-up reports, got \(recorder.text)")
        XCTAssertFalse(recorder.text.contains("<0;"), "a drag is not a button press: \(recorder.text)")
    }

    func testDraggingTheOtherWayReportsTheWheelTheOtherWay() {
        let view = makeView(feeding: Fixture.shortRun)
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: Fixture.enableSGRMouseTracking)
        settleTerminalCallbacks(for: view)

        view.forwardWheelDrag(distance: -Fixture.dragDistance, gestureRecognizer: UIPanGestureRecognizer())
        settleTerminalCallbacks(for: view)

        XCTAssertTrue(recorder.text.contains("<65;"), "expected wheel-down reports, got \(recorder.text)")
    }

    /// An alternate buffer deliberately has no local scrollback, so letting UIScrollView own the
    /// finger only drags its current screen into blank space. xterm Alternate Scroll Mode defines
    /// the wheel as cursor keys; whether an application assigns those keys to content is its own
    /// contract. Threading launches Codex inline because Codex assigns them to composer history.
    func testXtermAlternateScrollModeTurnsAFingerDragIntoCursorKeys() {
        let view = makeView(feeding: Fixture.shortRun)
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: "\u{1b}[?1049h")
        settleTerminalCallbacks(for: view)

        XCTAssertTrue(view.terminalStateSnapshot().isAlternateBuffer)
        XCTAssertEqual(view.terminalStateSnapshot().mouseMode, .off)
        XCTAssertNotNil(view.panMouseGesture)
        XCTAssertEqual(view.panGestureRecognizer.minimumNumberOfTouches, 2)

        view.forwardWheelDrag(
            distance: Fixture.dragDistance,
            gestureRecognizer: UIPanGestureRecognizer()
        )
        settleTerminalCallbacks(for: view)

        XCTAssertTrue(
            recorder.text.contains("\u{1b}[A"),
            "expected cursor-up input for alternate scroll, got \(recorder.text.debugDescription)"
        )
        XCTAssertFalse(recorder.text.contains("<64;"), "cursor scrolling is not a mouse report")
    }

    func testLeavingTheAlternateScreenReturnsOneFingerToLocalScrollback() {
        let view = makeView(feeding: Fixture.shortRun)
        view.feed(text: "\u{1b}[?1049h")
        settleTerminalCallbacks(for: view)
        XCTAssertNotNil(view.panMouseGesture)

        view.feed(text: "\u{1b}[?1049l")
        settleTerminalCallbacks(for: view)

        XCTAssertNil(view.panMouseGesture)
        XCTAssertEqual(view.panGestureRecognizer.minimumNumberOfTouches, 1)
    }

    func testResetAlternateScrollModeSuppressesCursorKeyTranslation() {
        let view = makeView(feeding: Fixture.shortRun)
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1007l")
        settleTerminalCallbacks(for: view)

        view.forwardWheelDrag(
            distance: Fixture.dragDistance,
            gestureRecognizer: UIPanGestureRecognizer()
        )
        settleTerminalCallbacks(for: view)

        XCTAssertTrue(recorder.text.isEmpty)
    }

    /// The application's gesture and the scroll view's own both live on this view, and two pan
    /// recognizers on one view do not both get to recognise. The touch count is what tells them
    /// apart, so the local scrollback stays reachable with two fingers.
    func testMouseTrackingHandsOneFingerToTheProgramAndKeepsTwoForTheScrollback() {
        let view = makeView(feeding: Fixture.shortRun)
        XCTAssertNil(view.panMouseGesture)
        XCTAssertEqual(view.panGestureRecognizer.minimumNumberOfTouches, 1)

        view.feed(text: Fixture.enableSGRMouseTracking)
        settleTerminalCallbacks(for: view)

        XCTAssertNotNil(view.panMouseGesture)
        XCTAssertEqual(view.panGestureRecognizer.minimumNumberOfTouches, 2)

        view.feed(text: Fixture.disableMouseTracking)
        settleTerminalCallbacks(for: view)

        XCTAssertNil(view.panMouseGesture)
        XCTAssertEqual(view.panGestureRecognizer.minimumNumberOfTouches, 1)
    }

    /// A flick is worth far more lines than the program can read reports for, and a split report
    /// is what puts `65;104;33M` in a composer. See `WheelReportBudget`.
    func testAFlickCannotOutrunTheProgramReadingIt() {
        let view = makeView(feeding: Fixture.shortRun)
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: Fixture.enableSGRMouseTracking)
        settleTerminalCallbacks(for: view)

        for _ in 0..<10 {
            view.forwardWheelDrag(distance: Fixture.dragDistance, gestureRecognizer: UIPanGestureRecognizer())
        }
        settleTerminalCallbacks(for: view)

        let reports = recorder.text.components(separatedBy: "<64;").count - 1
        XCTAssertGreaterThan(reports, 0)
        XCTAssertLessThanOrEqual(reports, Int(WheelReportBudget.burst) + 1)
    }

    func testFontSizeIsRoundedAndBounded() {
        XCTAssertEqual(MobileTerminalFontSize.normalized(8.4), 9)
        XCTAssertEqual(MobileTerminalFontSize.normalized(13.49), 13)
        XCTAssertEqual(MobileTerminalFontSize.normalized(13.5), 14)
        XCTAssertEqual(MobileTerminalFontSize.normalized(99), 24)
        XCTAssertEqual(MobileTerminalFontSize.normalized(.infinity), 13)
    }

    func testPinchScaleMapsFromTheGestureStartingSize() {
        XCTAssertEqual(MobileTerminalFontSize.scaled(from: 13, by: 1.01), 13)
        XCTAssertEqual(MobileTerminalFontSize.scaled(from: 13, by: 1.2), 16)
        XCTAssertEqual(MobileTerminalFontSize.scaled(from: 20, by: 0.5), 10)
        XCTAssertEqual(MobileTerminalFontSize.scaled(from: 13, by: 0), 13)
    }

    @MainActor
    func testPinchPersistsOnlyItsFinalWholePointSize() {
        let view = makeFontView(fontSize: 13)
        var persisted: [Double] = []
        view.configureFontSizing { persisted.append($0) }

        view.beginFontPinch()
        view.updateFontPinch(scale: 1.01)
        view.updateFontPinch(scale: 1.2)

        XCTAssertEqual(view.font.pointSize, 16)
        XCTAssertTrue(persisted.isEmpty)

        view.endFontPinch()

        XCTAssertEqual(persisted, [16])
    }

    @MainActor
    func testFontSizingInstallsOnePinchRecognizer() {
        let view = makeFontView(fontSize: 13)

        view.configureFontSizing { _ in }
        view.configureFontSizing { _ in }

        XCTAssertEqual(view.gestureRecognizers?.filter { $0 is UIPinchGestureRecognizer }.count, 1)
    }

    /// A viewer renders the Mac's grid rather than owning its PTY. Changing glyph dimensions
    /// must therefore zoom that renderer without reflowing or soft-resetting the emulator.
    @MainActor
    func testFontChangePreservesAnAuthoritativeGrid() {
        let view = makeFontView(fontSize: 13)
        view.setAuthoritativeGrid(cols: 109, rows: 84)

        view.applyPreferredFontSize(20)

        let dimensions = view.terminalDimensions
        XCTAssertEqual(dimensions.cols, 109)
        XCTAssertEqual(dimensions.rows, 84)
        XCTAssertEqual(view.font.pointSize, 20)
    }

    /// An interactive phone owns the viewport, so a larger font intentionally advertises the
    /// smaller grid that now fits the same pixels.
    @MainActor
    func testFontChangeRecomputesALocallyOwnedGrid() {
        let view = makeFontView(fontSize: 13)
        view.setAuthoritativeGrid(cols: 109, rows: 84)
        view.setUsesLocalViewport(true)
        let before = view.terminalDimensions

        view.applyPreferredFontSize(20)

        let after = view.terminalDimensions
        XCTAssertLessThan(after.cols, before.cols)
        XCTAssertLessThan(after.rows, before.rows)
    }

    @MainActor
    func testFontSizeAccessibilityActionsDescribeBothDirections() {
        let view = makeFontView(fontSize: 13)
        view.configureFontSizing { _ in }

        XCTAssertEqual(
            Set(view.accessibilityCustomActions?.map(\.name) ?? []),
            Set([
                MobileL10n.string("Increase terminal font size"),
                MobileL10n.string("Decrease terminal font size"),
            ])
        )
    }

    // MARK: - Private Methods

    @MainActor
    private func makeFontView(fontSize: CGFloat) -> RemoteTerminalView {
        RemoteTerminalView(
            frame: CGRect(x: 0, y: 0, width: 402, height: 700),
            font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        )
    }

    private func makeView(feeding lines: Int) -> RemoteTerminalView {
        let view = RemoteTerminalView(
            frame: Fixture.frame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        let window = UIWindow(frame: Fixture.frame)
        window.addSubview(view)
        hostWindows.append(window)
        for line in 0..<lines {
            view.feed(text: "line \(line)\r\n")
        }
        settleTerminalCallbacks(for: view)
        return view
    }

    private func settleTerminalCallbacks(for view: RemoteTerminalView) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    /// `Terminal.getLine` is viewport-relative, so row 0 is whatever the person is looking at.
    private func visibleTopLine(of view: RemoteTerminalView) -> String? {
        view.terminalStateSnapshot().visibleRows
            .first(where: { $0.row == 0 })?.text
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Records what the emulator writes back to the process.
private final class RecordingTerminalDelegate: NSObject, TerminalViewDelegate {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var sizes: [String] = []

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    var sizeReports: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sizes
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        lock.lock()
        bytes.append(contentsOf: data)
        lock.unlock()
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        lock.lock()
        sizes.append("\(newCols)x\(newRows)")
        lock.unlock()
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
