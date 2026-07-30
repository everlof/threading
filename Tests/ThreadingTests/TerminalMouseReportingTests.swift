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
