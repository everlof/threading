import XCTest
import AppKit
import SwiftTerm
@testable import Threading

/// Terminal selection: what a pointer gesture puts on the clipboard, what it leaves alone, and
/// how long the selected buffer range survives while the process keeps repainting.
///
/// macOS has one pasteboard, so every one of these gestures is spending the user's clipboard.
/// The setting being off has to mean *nothing is written*, a selection covering no characters has
/// to mean nothing is written, and a drag still under way has to mean nothing is written yet: the
/// fork posts `selectionChanged` on every `dragExtend`, and copying there would hand back a
/// half-made selection dozens of times per gesture.
///
/// Every case drives real `NSEvent`s through the view's own handlers rather than reaching for the
/// selection directly, because the gesture wiring — which click count settles a selection, which
/// only clears one — is the part that can be wrong.
@MainActor
final class TerminalCopyOnSelectTests: XCTestCase {

    // MARK: - Harness

    private var pasteboard: NSPasteboard!
    private var view: EmojiFixedTerminalView!
    private var previousSetting = false

    /// What the user had copied before touching the terminal. Present in every test, because
    /// "the clipboard is unchanged" is only an assertion if there was something to lose.
    private static let priorClipboard = "https://example.com/what-the-user-copied-earlier"

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousSetting = AppSettings.shared.copiesTerminalSelection
        pasteboard = NSPasteboard(name: NSPasteboard.Name("threading-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(Self.priorClipboard, forType: .string)

        view = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.pasteboard = pasteboard
        view.feed(text: "hello world\r\n")
    }

    override func tearDownWithError() throws {
        AppSettings.shared.copiesTerminalSelection = previousSetting
        pasteboard.releaseGlobally()
        pasteboard = nil
        view = nil
        try super.tearDownWithError()
    }

    private var copied: String? { pasteboard.string(forType: .string) }

    /// The row the fed line landed on, and a row well below it that no output ever reached.
    private enum Row {
        static let text = 0
        static let blank = 2
    }

    /// A point inside the given grid row. `x` is a view coordinate, not a column: the tests that
    /// need a column ask for the first one (a couple of points in) or for the far edge, neither
    /// of which needs the cell width the fork keeps to itself.
    private func point(x: CGFloat, row: Int) -> NSPoint {
        let cellHeight = view.frame.height / CGFloat(view.getTerminal().getDims().rows)
        // Half a cell down into the row, measured from the top the way the fork's hit test is.
        return NSPoint(x: x, y: view.frame.height - (CGFloat(row) + 0.5) * cellHeight)
    }

    private func event(_ type: NSEvent.EventType, at location: NSPoint, clicks: Int = 1) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        ) else {
            XCTFail("AppKit refused to make a \(type) event")
            return NSEvent()
        }
        return event
    }

    /// A press, a drag to `toX`, and the release that settles the selection.
    ///
    /// Two dragged events, not one, and that is not padding: the fork anchors the selection at
    /// the **first** drag event rather than at the press, so a single event leaves start and end
    /// on the same cell and selects nothing. AppKit sends a stream during a real drag; a fixture
    /// that sends one is asserting against a gesture no user can make.
    private func drag(row: Int, fromX: CGFloat = 2, toX: CGFloat? = nil) {
        let from = point(x: fromX, row: row)
        let to = point(x: toX ?? (view.frame.width - 2), row: row)
        view.mouseDown(with: event(.leftMouseDown, at: from))
        view.mouseDragged(with: event(.leftMouseDragged, at: from))
        view.mouseDragged(with: event(.leftMouseDragged, at: to))
        view.mouseUp(with: event(.leftMouseUp, at: to))
    }

    /// A double-click, which is two presses — AppKit raises the click count rather than sending
    /// a different event, and the fork switches on exactly that.
    private func doubleClick(row: Int, x: CGFloat = 2) {
        let at = point(x: x, row: row)
        view.mouseDown(with: event(.leftMouseDown, at: at))
        view.mouseUp(with: event(.leftMouseUp, at: at))
        view.mouseDown(with: event(.leftMouseDown, at: at, clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, at: at, clicks: 2))
    }

    // MARK: - Copying

    func testDraggedSelectionLandsOnTheClipboard() {
        AppSettings.shared.copiesTerminalSelection = true

        drag(row: Row.text)

        XCTAssertEqual(
            copied?.contains("hello world"), true,
            "a drag across the fed line should have copied it, got \(String(describing: copied))"
        )
    }

    func testDoubleClickCopiesTheWordUnderThePointer() {
        AppSettings.shared.copiesTerminalSelection = true

        doubleClick(row: Row.text)

        XCTAssertEqual(copied?.contains("hello"), true, "the word under the pointer should copy")
        XCTAssertEqual(
            copied?.contains("world"), false,
            "a double-click selects the word, not the line: \(String(describing: copied))"
        )
    }

    // MARK: - Not Copying

    func testSelectionIsNotCopiedWhileTheSettingIsOff() {
        AppSettings.shared.copiesTerminalSelection = false

        drag(row: Row.text)

        XCTAssertEqual(copied, Self.priorClipboard, "the clipboard is the user's until they opt in")
        XCTAssertEqual(
            view.selectedText?.contains("hello world"), true,
            "the selection itself still has to happen — only the copying is opt-in"
        )
    }

    func testNothingIsCopiedUntilTheDragIsReleased() {
        AppSettings.shared.copiesTerminalSelection = true
        let from = point(x: 2, row: Row.text)

        view.mouseDown(with: event(.leftMouseDown, at: from))
        view.mouseDragged(with: event(.leftMouseDragged, at: from))
        view.mouseDragged(with: event(.leftMouseDragged, at: point(x: 60, row: Row.text)))

        XCTAssertNotNil(view.selectedText, "the drag should have selected something to not copy")
        XCTAssertEqual(
            copied, Self.priorClipboard,
            "a selection still being dragged is not yet what the user meant to take"
        )
    }

    func testDraggingAcrossBlankScreenKeepsTheClipboard() {
        AppSettings.shared.copiesTerminalSelection = true

        drag(row: Row.blank)

        XCTAssertEqual(
            copied, Self.priorClipboard,
            "a selection covering no characters must not clear what the user had copied"
        )
    }

    func testAClickThatOnlyClearsASelectionCopiesNothing() {
        AppSettings.shared.copiesTerminalSelection = true
        drag(row: Row.text)
        pasteboard.clearContents()
        pasteboard.setString(Self.priorClipboard, forType: .string)

        // The click that dismisses the selection made above.
        let at = point(x: 2, row: Row.text)
        view.mouseDown(with: event(.leftMouseDown, at: at))
        view.mouseUp(with: event(.leftMouseUp, at: at))

        XCTAssertNil(view.selectedText, "the click should have cleared the selection")
        XCTAssertEqual(copied, Self.priorClipboard, "clearing a selection is not a copy")
    }

    // MARK: - Selection Lifetime

    /// Codex repaints progress in small output chunks after a drag has settled. Output outside
    /// the selected range must not dismiss the range merely because another PTY read arrived.
    func testSelectionSurvivesUnrelatedProcessOutput() {
        AppSettings.shared.copiesTerminalSelection = false
        drag(row: Row.text)
        let selected = view.selectedText

        view.feed(text: "\u{1b}[3;1Hworking")

        XCTAssertEqual(view.selectedText, selected)
    }

    /// Codex's TUI also uses line feeds while repainting. A line feed away from the bottom does
    /// not move or replace existing buffer rows, so it must not cancel their selection.
    func testSelectionSurvivesALineFeedThatDoesNotScroll() {
        AppSettings.shared.copiesTerminalSelection = false
        drag(row: Row.text)
        let selected = view.selectedText

        view.feed(text: "\u{1b}[3;1Hprogress\r\n")

        XCTAssertEqual(view.selectedText, selected)
    }

    /// Normal and alternate buffers reuse coordinates for unrelated content. Keeping the range
    /// across a switch would highlight text the user never selected.
    func testSwitchingBuffersClearsTheSelection() {
        drag(row: Row.text)
        XCTAssertNotNil(view.selectedText)

        view.feed(text: "\u{1b}[?1049h")

        XCTAssertNil(view.selectedText)
    }

    /// An alternate buffer has no scrollback: scrolling replaces every row in place rather than
    /// appending stable history. That operation still invalidates a local selection.
    func testScrollingTheAlternateBufferClearsTheSelection() {
        // 1049 restores whichever cursor position the alternate buffer last held. Home it so
        // the pointer fixture selects the row we just wrote rather than assuming that position.
        view.feed(text: "\u{1b}[?1049h\u{1b}[Hstable row")
        drag(row: Row.text)
        XCTAssertNotNil(view.selectedText)

        let bottomRow = view.getTerminal().getDims().rows
        view.feed(text: "\u{1b}[\(bottomRow);1H\r\n")

        XCTAssertNil(view.selectedText)
    }

    // MARK: - Copy With Nothing Selected

    /// The bug underneath copy-on-select, and older than it: `copy` clears the pasteboard before
    /// it writes, so a Copy with nothing selected threw the user's clipboard away. ⌘C was safe —
    /// menu validation gates it on an active selection — but the app's own terminal context menu
    /// calls this directly, and so does copy-on-select.
    func testCopyingWithNoSelectionKeepsTheClipboard() {
        view.copy(view)

        XCTAssertEqual(copied, Self.priorClipboard, "there was nothing to copy, so nothing changes")
    }
}
