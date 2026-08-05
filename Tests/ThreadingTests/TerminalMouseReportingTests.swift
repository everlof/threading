import AppKit
import XCTest
import SwiftTerm

/// The bytes the terminal writes back for a mouse event, in SGR mode.
///
/// A hover reported as a button *release* is indistinguishable, to the program on the other end
/// of the PTY, from the user clicking: Claude Code toggles a collapsed tool row on mouse-up, so
/// moving the pointer across its transcript opened and closed rows under the cursor. The format
/// is the whole contract here, which is why these assert on exact byte strings.
final class TerminalMouseReportingTests: XCTestCase {

    // MARK: - Harness

    /// Captures what the terminal sends upstream.
    private final class Recorder: TerminalDelegate {
        var written: [UInt8] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            written.append(contentsOf: data)
        }

        var text: String { String(decoding: written, as: UTF8.self) }
    }

    /// A terminal in "any-event tracking" (1003) reporting in SGR (1006) — the pair Claude Code
    /// turns on, and the only combination under which hover reaches the program at all.
    private func makeTerminal() -> (Terminal, Recorder) {
        let recorder = Recorder()
        let terminal = Terminal(delegate: recorder)
        terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
        XCTAssertEqual(terminal.mouseMode, .anyEvent, "1003 should select any-event tracking")
        recorder.written.removeAll()
        return (terminal, recorder)
    }

    /// What `MacTerminalView.mouseMoved` encodes for a pointer with no button held.
    private func hoverFlags(_ terminal: Terminal) -> Int {
        terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false)
    }

    // MARK: - Motion

    func testHoverReportsMotionNotRelease() {
        let (terminal, recorder) = makeTerminal()

        terminal.sendMotion(buttonFlags: hoverFlags(terminal), x: 12, y: 7, pixelX: 0, pixelY: 0)

        // Cb 35 = motion (32) + no button (3), and an uppercase final byte. The regression wrote
        // `<32;13;8m`: button 0, lowercase — a left-button release.
        XCTAssertEqual(recorder.text, "\u{1b}[<35;13;8M")
    }

    func testDragReportsMotionWithButton() {
        let (terminal, recorder) = makeTerminal()
        let held = terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false)

        terminal.sendMotion(buttonFlags: held, x: 3, y: 4, pixelX: 0, pixelY: 0)

        XCTAssertEqual(recorder.text, "\u{1b}[<32;4;5M", "motion with button 0 held")
    }

    // MARK: - Buttons

    func testButtonPressStillReportsPress() {
        let (terminal, recorder) = makeTerminal()
        let press = terminal.encodeButton(button: 0, release: false, shift: false, meta: false, control: false)

        terminal.sendEvent(buttonFlags: press, x: 2, y: 5)

        XCTAssertEqual(recorder.text, "\u{1b}[<0;3;6M")
    }

    /// The case the old test would have passed: a real release must keep its lowercase final
    /// byte and its flattened button bits, or clicking stops working entirely.
    func testButtonReleaseStillReportsRelease() {
        let (terminal, recorder) = makeTerminal()
        let release = terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false)

        terminal.sendEvent(buttonFlags: release, x: 2, y: 5)

        XCTAssertEqual(recorder.text, "\u{1b}[<0;3;6m")
    }

    // MARK: - Wheel

    /// Captures what a whole `TerminalView` sends upstream, which is where the wheel path ends.
    private final class ViewRecorder: TerminalViewDelegate {
        var written: [UInt8] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) { written.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        /// Wheel presses only — buttons 64 (up) and 65 (down).
        var wheelReports: Int {
            let text = String(decoding: written, as: UTF8.self)
            return text.components(separatedBy: "\u{1b}[<64;").count - 1
                + text.components(separatedBy: "\u{1b}[<65;").count - 1
        }
    }

    /// A view tracking the mouse the way Claude Code asks it to: `?1000h` with SGR reporting.
    @MainActor
    private func makeWheelView(tracking: Bool = true) -> (TerminalView, ViewRecorder) {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        let recorder = ViewRecorder()
        view.terminalDelegate = recorder
        if tracking {
            view.getTerminal().feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
            XCTAssertEqual(view.getTerminal().mouseMode, .vt200)
        }
        recorder.written.removeAll()
        return (view, recorder)
    }

    /// A wheel event as AppKit delivers one: classic notches, or a trackpad's precise points.
    ///
    /// The flags are always stated, never merely left alone. A `CGEvent` built from a nil source
    /// takes its modifiers from the *combined session state* — the keys physically down on the
    /// developer's keyboard at that instant — and a modifier rides straight into the report:
    /// shift turns wheel-up from button 64 into 68, so the assertions below stop matching. It
    /// fails as "the wheel reports nothing", in whichever tests happen to run while someone is
    /// typing, which is as intermittent as it sounds.
    private func scroll(notches: Int32 = 0, points: Int32 = 0, option: Bool = false) throws -> NSEvent {
        let precise = points != 0
        let cg = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 1,
            wheel1: precise ? points : notches,
            wheel2: 0,
            wheel3: 0
        ))
        cg.flags = option ? [.maskAlternate] : []
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// One notch is one wheel event to the program. The scrollback path multiplies a fast notch
    /// by a velocity curve — up to a screenful — and reporting that count sent a program dozens
    /// of presses for a gesture the user made once.
    @MainActor
    func testOneNotchIsOneReportHoweverFastItTurns() throws {
        let (view, recorder) = makeWheelView()

        view.scrollWheel(with: try scroll(notches: 10))

        XCTAssertEqual(recorder.wheelReports, 1)
        XCTAssertTrue(String(decoding: recorder.written, as: UTF8.self).hasPrefix("\u{1b}[<64;"),
                      "a positive delta is wheel-up, button 64")
    }

    /// The bug this budget exists for: a momentum flick used to put over a thousand reports a
    /// second into the pty. A program that was mid-render resumed reading inside one of them,
    /// dropped the orphaned `ESC [ <`, and typed the rest — `65;104;33M` — into its composer.
    @MainActor
    func testAFlickCannotOutrunTheProgramReadingIt() throws {
        let (view, recorder) = makeWheelView()

        // Momentum: a long run of large precise deltas with no time passing between them.
        for _ in 0..<40 {
            view.scrollWheel(with: try scroll(points: -180))
        }

        // Six is the burst; the refill over a loop this short is a fraction of one report.
        XCTAssertLessThanOrEqual(recorder.wheelReports, 8,
                                 "a flick may spend the burst and no more")
        XCTAssertGreaterThan(recorder.wheelReports, 0, "the flick still scrolls")
    }

    /// A rate, not a one-shot: the budget refills, so scrolling keeps working after a flick.
    @MainActor
    func testTheBudgetRefillsSoTheNextGestureStillScrolls() throws {
        let (view, recorder) = makeWheelView()
        for _ in 0..<40 { view.scrollWheel(with: try scroll(points: -180)) }
        let spent = recorder.wheelReports

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        view.scrollWheel(with: try scroll(points: -180))

        XCTAssertGreaterThan(recorder.wheelReports, spent, "200ms buys reports back")
    }

    /// Holding option is the escape hatch back to the local scrollback, and must stay silent —
    /// a report sent there scrolls the program instead of the terminal.
    @MainActor
    func testOptionScrollsTheScrollbackAndReportsNothing() throws {
        let (view, recorder) = makeWheelView()

        view.scrollWheel(with: try scroll(notches: 3, option: true))

        XCTAssertEqual(recorder.written.count, 0)
    }

    /// Nothing goes upstream at all until the program asks to track the mouse.
    @MainActor
    func testWheelIsSilentWhenTheProgramIsNotTrackingTheMouse() throws {
        let (view, recorder) = makeWheelView(tracking: false)

        view.scrollWheel(with: try scroll(notches: 3))
        view.scrollWheel(with: try scroll(points: -180))

        XCTAssertEqual(recorder.written.count, 0)
    }

    // MARK: - Modifiers

    /// Modifier bits share the low byte with the button number, so the release/motion test has
    /// to survive them.
    func testHoverWithModifiersStaysMotion() {
        let (terminal, recorder) = makeTerminal()
        let flags = terminal.encodeButton(button: 0, release: true, shift: true, meta: false, control: true)

        terminal.sendMotion(buttonFlags: flags, x: 0, y: 0, pixelX: 0, pixelY: 0)

        // 32 motion + 3 no-button + 4 shift + 16 control.
        XCTAssertEqual(recorder.text, "\u{1b}[<55;1;1M")
    }
}
