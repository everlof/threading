import Combine
import SwiftTerm
import UIKit
import XCTest
@testable import ThreadingMobile

/// Claude Code draws things to click — "click to go to bottom" among them — and answers a left
/// button press at that cell. Tapping them from the phone did nothing, for two reasons that both
/// live in this gesture: the tap was reported as a *middle* click, which nothing listens for,
/// and the whole gesture was gated on the terminal holding the keyboard, so the first tap after
/// the keyboard was put away was spent taking it back.
@MainActor
final class RemoteTerminalTapTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let frame = CGRect(x: 0, y: 0, width: 420, height: 420)
        static let fontSize: CGFloat = 12
        /// Any-event tracking plus SGR encoding: the pair Claude Code turns on, and the same
        /// one `TerminalMouseReportingTests` pins on the Mac side.
        static let enableSGRMouseTracking = "\u{1b}[?1003h\u{1b}[?1006h"
        static let lines = 10
        static let tappedColumn = 6
        static let tappedRow = 3
    }

    // MARK: - Tests

    func testATapOverATrackingProgramIsReportedAsALeftClick() {
        let view = makeView()
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: Fixture.enableSGRMouseTracking)

        XCTAssertTrue(
            view.forwardTap(
                at: point(column: Fixture.tappedColumn, row: Fixture.tappedRow, in: view)
            )
        )

        // Cb 0 is the left button; 1 is the middle one, which is what this used to send.
        XCTAssertTrue(
            recorder.text.contains("<0;\(Fixture.tappedColumn + 1);\(Fixture.tappedRow + 1)M"),
            "expected a left press at the tapped cell, got \(recorder.text)"
        )
    }

    /// A finger has no dwell. A program told only that a button went down waits for a release
    /// that never comes, and leaves the row it was drawing under the pointer highlighted.
    func testTheReleaseTravelsWithThePress() {
        let view = makeView()
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: Fixture.enableSGRMouseTracking)

        view.forwardTap(at: point(column: Fixture.tappedColumn, row: Fixture.tappedRow, in: view))

        XCTAssertTrue(
            recorder.text.contains("<0;\(Fixture.tappedColumn + 1);\(Fixture.tappedRow + 1)m"),
            "expected the lowercase SGR release, got \(recorder.text)"
        )
    }

    func testATapIsClaimedByTheProgramEvenWithTheKeyboardPutAway() {
        let (window, view) = makeFocusedView()
        defer { window.isHidden = true }
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: Fixture.enableSGRMouseTracking)
        _ = view.resignFirstResponder()
        XCTAssertFalse(view.isFirstResponder)

        tap(view, at: point(column: Fixture.tappedColumn, row: Fixture.tappedRow, in: view))

        XCTAssertTrue(
            recorder.text.contains("<0;\(Fixture.tappedColumn + 1);\(Fixture.tappedRow + 1)M"),
            "a phone reading a TUI with the keyboard down still has to be able to click it"
        )
        XCTAssertFalse(
            view.isFirstResponder,
            "taking the keyboard on a click would cover the thing just clicked"
        )
    }

    /// Nothing is tracking the mouse: the tap belongs to the terminal again, and the way back
    /// to the keyboard is a tap on it.
    func testATapWithNoTrackingProgramTakesTheKeyboardBack() {
        let (window, view) = makeFocusedView()
        defer { window.isHidden = true }
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        _ = view.resignFirstResponder()

        tap(view, at: point(column: 0, row: 0, in: view))

        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(recorder.text.isEmpty, "a plain terminal has no click to report")
    }

    /// Over a tracking program single taps are the program's clicks, so a double tap is the
    /// finger's remaining way of asking for the keyboard on the terminal itself. The pair's
    /// first tap already reached the program through the single-tap recognizer; the double-tap
    /// handler must not send the same click again on its way to the keyboard.
    func testADoubleTapOverATrackingProgramTakesTheKeyboardBack() {
        let (window, view) = makeFocusedView()
        defer { window.isHidden = true }
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: Fixture.enableSGRMouseTracking)
        _ = view.resignFirstResponder()
        XCTAssertFalse(view.isFirstResponder)

        doubleTap(view, at: point(column: Fixture.tappedColumn, row: Fixture.tappedRow, in: view))

        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(
            recorder.text.isEmpty,
            "asking for the keyboard must not repeat the click, got \(recorder.text)"
        )
    }

    /// With the keyboard already up there is nothing left for a double tap to ask, so it stays
    /// what it always was over a tracking program: that program's click.
    func testADoubleTapWhileTypingIsStillTheProgramsClick() {
        let (window, view) = makeFocusedView()
        defer { window.isHidden = true }
        let recorder = RecordingTerminalDelegate()
        view.terminalDelegate = recorder
        view.feed(text: Fixture.enableSGRMouseTracking)

        doubleTap(view, at: point(column: Fixture.tappedColumn, row: Fixture.tappedRow, in: view))

        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(
            recorder.text.contains("<0;\(Fixture.tappedColumn + 1);\(Fixture.tappedRow + 1)M"),
            "expected the program's left click, got \(recorder.text)"
        )
    }

    /// A phone that will not forward reports — view-only, or typing into a draft — must not have
    /// the gesture claimed either. SwiftTerm hands a tracking program the one-finger pan and
    /// leaves two fingers for the scrollback, so a claimed gesture that is then dropped on the
    /// way out of the app scrolls nothing at all.
    func testAPhoneThatCannotSendKeepsItsOwnFingerOverATrackingProgram() {
        let view = makeView()
        view.allowMouseReporting = false

        view.feed(text: Fixture.enableSGRMouseTracking)

        XCTAssertNil(view.panMouseGesture, "the program must not be given this phone's finger")
        XCTAssertEqual(view.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertFalse(view.forwardTap(at: point(column: 0, row: 0, in: view)))
    }

    func testTakingTheMouseBackHandsTheProgramItsFingerAgain() {
        let view = makeView()
        view.allowMouseReporting = false
        view.feed(text: Fixture.enableSGRMouseTracking)

        view.allowMouseReporting = true

        XCTAssertNotNil(view.panMouseGesture)
        XCTAssertEqual(view.panGestureRecognizer.minimumNumberOfTouches, 2)
    }

    func testTheBarCanAskForTheKeyboardBack() {
        let (window, view) = makeFocusedView()
        defer { window.isHidden = true }
        let bridge = TerminalKeyBridge()
        bridge.terminalView = view
        bridge.dismissKeyboard()
        XCTAssertFalse(bridge.isKeyboardShowing)

        bridge.showKeyboard()

        XCTAssertTrue(bridge.isKeyboardShowing)
        XCTAssertTrue(view.isFirstResponder)
    }

    func testAskingForTheKeyboardWithNoTerminalIsHarmless() {
        TerminalKeyBridge().showKeyboard()
    }

    /// The bar decides whether to draw the show control during body evaluation, and the
    /// terminal attaches only after the bar's first render — so availability has to be a
    /// published change the bar is re-evaluated for, not a computed answer nothing announces.
    /// Computed, the show control never appeared: only the dismiss half ever did.
    func testAttachingATerminalPublishesTheShowControl() {
        let view = makeView()
        let bridge = TerminalKeyBridge()
        XCTAssertFalse(bridge.canShowKeyboard)
        var published = false
        let subscription = bridge.objectWillChange.sink { published = true }
        defer { subscription.cancel() }

        bridge.terminalView = view

        XCTAssertTrue(bridge.canShowKeyboard)
        XCTAssertTrue(published, "the bar cannot re-evaluate for a change nobody published")
    }

    /// Input mode can flip on a live view — a session dropping to view-only must take the show
    /// control with it, and coming back must return it.
    func testInputModeFlipsFollowTheShowControl() {
        let view = makeView()
        let bridge = TerminalKeyBridge()
        bridge.terminalView = view
        XCTAssertTrue(bridge.canShowKeyboard)

        view.setAllowsKeyboardInput(false)
        bridge.refreshKeyboardAvailability()
        XCTAssertFalse(bridge.canShowKeyboard)

        view.setAllowsKeyboardInput(true)
        bridge.refreshKeyboardAvailability()
        XCTAssertTrue(bridge.canShowKeyboard)
    }

    // MARK: - Private Methods

    private func makeView() -> RemoteTerminalView {
        let view = RemoteTerminalView(
            frame: Fixture.frame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        for line in 0..<Fixture.lines {
            view.feed(text: "line \(line)\r\n")
        }
        return view
    }

    private func makeFocusedView() -> (UIWindow, RemoteTerminalView) {
        let window = UIWindow(frame: Fixture.frame)
        let view = makeView()
        window.addSubview(view)
        window.makeKeyAndVisible()
        XCTAssertTrue(view.becomeFirstResponder())
        return (window, view)
    }

    /// The centre of a cell, which is where a finger lands.
    private func point(column: Int, row: Int, in view: RemoteTerminalView) -> CGPoint {
        let cell = view.cellSize
        XCTAssertGreaterThan(cell.width, 0)
        XCTAssertGreaterThan(cell.height, 0)
        return CGPoint(
            x: (CGFloat(column) + 0.5) * cell.width,
            y: (CGFloat(row) + 0.5) * cell.height
        )
    }

    /// Runs the real gesture handler. It is the view's own `@objc` gesture action rather than
    /// API, so the test reaches it the way the recognizer does — the point of these two cases
    /// is what the *gesture* decides, which a direct call to `forwardTap` would skip.
    private func tap(_ view: RemoteTerminalView, at point: CGPoint) {
        let recognizer = EndedTap(at: point, on: view)
        view.perform(Selector(("singleTap:")), with: recognizer)
    }

    private func doubleTap(_ view: RemoteTerminalView, at point: CGPoint) {
        let recognizer = EndedTap(at: point, on: view)
        view.perform(Selector(("doubleTap:")), with: recognizer)
    }
}

/// A tap that has already ended at a known point, so the gesture handler can be exercised
/// without a touch sequence the simulator would have to deliver.
private final class EndedTap: UITapGestureRecognizer {
    private let point: CGPoint

    init(at point: CGPoint, on view: UIView) {
        self.point = point
        super.init(target: nil, action: nil)
        view.addGestureRecognizer(self)
    }

    override var state: UIGestureRecognizer.State {
        get { .ended }
        set { super.state = newValue }
    }

    override func location(in view: UIView?) -> CGPoint { point }
}

/// Records what the emulator writes back to the process.
private final class RecordingTerminalDelegate: NSObject, TerminalViewDelegate {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        lock.lock()
        bytes.append(contentsOf: data)
        lock.unlock()
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
