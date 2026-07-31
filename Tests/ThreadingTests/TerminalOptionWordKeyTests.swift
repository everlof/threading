import XCTest
import AppKit
import SwiftTerm
@testable import Threading

/// The bytes the Option-word keys write to the PTY.
///
/// `TerminalSession` turns `optionAsMetaKey` off so Option still composes `~ | \ @` on non-US
/// layouts. That switch is all-or-nothing in SwiftTerm: its meta branch is also the only place
/// these keys became word editing, so keeping composition working silently dropped them
/// entirely — AppKit resolves them to `moveWordLeft:`, `moveWordRight:` and
/// `deleteWordBackward:`, which `doCommand(by:)` did not claim, so *nothing* reached the
/// process. Not a sequence the agent misread; no keypress at all.
///
/// Like the mouse reporting tests, these assert exact byte strings: the wire format is the whole
/// contract with whatever runs in the terminal.
@MainActor
final class TerminalOptionWordKeyTests: XCTestCase {

    // MARK: - Harness

    /// Captures what the view sends upstream, in place of a PTY.
    private final class Recorder: TerminalViewDelegate {
        var written: [UInt8] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            written.append(contentsOf: data)
        }

        var text: String { String(decoding: written, as: UTF8.self) }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// A terminal configured the way `TerminalSession` configures every terminal in the app.
    ///
    /// The window is built and never shown — `interpretKeyEvents` needs an input context, which
    /// wants a first responder in a window, and ordering one on screen is what leaves the test
    /// host queueing its own termination.
    private func makeView() -> (TerminalView, Recorder, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = TerminalView(frame: window.contentView!.bounds)
        view.optionAsMetaKey = false

        let recorder = Recorder()
        view.terminalDelegate = recorder

        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)

        return (view, recorder, window)
    }

    /// Arrow keys arrive with `.function` set, which is a branch of its own in `keyDown`.
    /// Delete does not, so the two reach `doCommand(by:)` by different routes.
    private func key(
        _ scalar: Int,
        _ flags: NSEvent.ModifierFlags,
        in window: NSWindow,
        keyCode: UInt16 = 0,
        characters: String? = nil
    ) -> NSEvent {
        let ignoring = String(UnicodeScalar(UInt32(scalar))!)
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters ?? ignoring,
            charactersIgnoringModifiers: ignoring,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// The Delete key: `0x7f`, keyCode 51 — not `NSDeleteFunctionKey`, which is forward delete.
    private enum Keys {
        static let backspaceScalar = 0x7f
        static let backspaceCode: UInt16 = 51
    }

    // MARK: - Word Motion

    func testOptionLeftSendsBackwardWord() {
        let (view, recorder, window) = makeView()

        view.keyDown(with: key(NSLeftArrowFunctionKey, [.option, .function], in: window))

        // ESC b: what readline binds to `backward-word`, what Terminal.app maps Option-left to
        // by default, and what Claude Code honours. The regression sent nothing at all.
        XCTAssertEqual(recorder.text, "\u{1b}b")
    }

    func testOptionRightSendsForwardWord() {
        let (view, recorder, window) = makeView()

        view.keyDown(with: key(NSRightArrowFunctionKey, [.option, .function], in: window))

        XCTAssertEqual(recorder.text, "\u{1b}f")
    }

    // MARK: - Word Deletion

    func testOptionBackspaceKillsTheWordBehindTheCaret() {
        let (view, recorder, window) = makeView()

        view.keyDown(with: key(
            Keys.backspaceScalar,
            [.option],
            in: window,
            keyCode: Keys.backspaceCode
        ))

        // ESC DEL — `\e\C-?`, which both zsh and bash bind to `backward-kill-word`, and which
        // Claude Code kills a word on. Like the arrows, this sent nothing at all before.
        XCTAssertEqual(recorder.text, "\u{1b}\u{7f}")
    }

    /// Delete on its own is a single character, and stays one: the word kill must not leak into
    /// the plain key that shares its scancode.
    func testPlainBackspaceStillDeletesOneCharacter() {
        let (view, recorder, window) = makeView()

        view.keyDown(with: key(
            Keys.backspaceScalar,
            [],
            in: window,
            keyCode: Keys.backspaceCode
        ))

        XCTAssertEqual(recorder.text, "\u{7f}")
    }

    // MARK: - What Must Not Change

    /// The guard on the other side: word motion must not be bought back by re-enabling meta,
    /// which is what makes Option a dead modifier for composing characters.
    func testTerminalSessionKeepsOptionAvailableForComposition() {
        let session = TerminalSession()

        XCTAssertFalse(
            session.terminalView.optionAsMetaKey,
            "Option must reach the OS so `~ | \\ @` stay typable on non-US layouts"
        )
    }

    /// With meta off, Option-plus-letter is a composed character, not `ESC` and the letter.
    /// A Swedish layout produces `~` from Option-N; meta would send `ESC n` instead.
    func testOptionLetterStillComposes() {
        let (view, recorder, window) = makeView()

        let composed = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "~",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        )!
        view.keyDown(with: composed)

        XCTAssertEqual(recorder.text, "~", "the composed character, not ESC n")
    }

    /// Unmodified arrows keep their cursor sequences — a fix that routed every left arrow
    /// through the word motion would be worse than the bug.
    func testPlainArrowsStillMoveOneCell() {
        let (view, recorder, window) = makeView()

        view.keyDown(with: key(NSLeftArrowFunctionKey, [.function], in: window))
        view.keyDown(with: key(NSRightArrowFunctionKey, [.function], in: window))

        XCTAssertEqual(recorder.text, "\u{1b}[D\u{1b}[C")
    }

    /// Control-arrow is handled by its own branch in `keyDown` and reports the xterm modifier
    /// form. It shares no code with the Option path, so it is here to catch a fix applied to
    /// the wrong branch.
    func testControlArrowsStillReportXtermModifiers() {
        let (view, recorder, window) = makeView()

        view.keyDown(with: key(NSLeftArrowFunctionKey, [.control, .function], in: window))
        view.keyDown(with: key(NSRightArrowFunctionKey, [.control, .function], in: window))

        XCTAssertEqual(recorder.text, "\u{1b}[1;5D\u{1b}[1;5C")
    }
}
