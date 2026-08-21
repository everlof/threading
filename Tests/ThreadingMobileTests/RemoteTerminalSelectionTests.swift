import SwiftTerm
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// Selecting text in the phone's terminal had two ways of feeling broken. Every line feed
/// dropped the selection while the program tracked the mouse, which is exactly while an agent
/// is printing the thing someone is trying to select; and a long press put a "Select" menu
/// between the finger and the word, taking the keyboard on the way. These pin the selection
/// surviving output the way the Mac's does, the press selecting directly, and the edit menu
/// carrying the app's own action beside Copy.
@MainActor
final class RemoteTerminalSelectionTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let frame = CGRect(x: 0, y: 0, width: 420, height: 420)
        static let fontSize: CGFloat = 12
        static let enableSGRMouseTracking = "\u{1b}[?1003h\u{1b}[?1006h"
        static let initialLines = 60
        static let moreLines = 12
        static let smallScrollback = 20
        static let selectedRow = 10
        static let selectedWord = "line"
        static let blankColumn = 30
        static let quoteTitle = "Add to message"
    }

    // MARK: - Tests

    func testASelectionSurvivesOutputWhileTheProgramTracksTheMouse() {
        let view = makeView()
        view.allowMouseReporting = true
        view.feed(text: Fixture.enableSGRMouseTracking)
        settleTerminalCallbacks(for: view)
        select(row: Fixture.selectedRow, in: view)
        let selected = view.selectedText
        XCTAssertEqual(selected, "\(Fixture.selectedWord) \(Fixture.selectedRow)")

        feedLines(Fixture.moreLines, into: view)

        XCTAssertTrue(view.hasActiveSelection, "output that only appends must not drop a selection")
        XCTAssertEqual(view.selectedText, selected)
    }

    func testASelectionIsDroppedOnceScrollbackRecyclesItsLines() {
        let view = makeView(scrollback: Fixture.smallScrollback)
        view.allowMouseReporting = true
        select(row: Fixture.selectedRow, in: view)
        XCTAssertTrue(view.hasActiveSelection)

        feedLines(Fixture.initialLines, into: view)

        XCTAssertFalse(
            view.hasActiveSelection,
            "the rows the selection named hold other text now; keeping it would highlight the wrong lines"
        )
    }

    func testALongPressSelectsTheWordUnderTheFingerWithoutTakingTheKeyboard() {
        let (window, view) = makeWindowedView()
        defer { window.isHidden = true }
        XCTAssertFalse(view.isFirstResponder)

        longPress(view, .began, at: point(column: 1, row: 3, in: view))

        XCTAssertTrue(view.hasActiveSelection)
        XCTAssertEqual(view.selectedText, Fixture.selectedWord)
        XCTAssertFalse(view.isFirstResponder, "a gesture about text is not a request for the keyboard")
    }

    func testALongPressOverBlankCellsSelectsNothing() {
        let view = makeView()

        longPress(view, .began, at: point(column: Fixture.blankColumn, row: 3, in: view))

        XCTAssertFalse(view.hasActiveSelection)
    }

    func testMovingTheFingerExtendsTheSelectionFromTheWord() {
        let view = makeView()

        longPress(view, .began, at: point(column: 1, row: 3, in: view))
        longPress(view, .changed, at: point(column: 6, row: 4, in: view))

        XCTAssertEqual(view.selectedText, "line 3\nline 4")
    }

    func testALongPressInsideTheSelectionKeepsIt() {
        let view = makeView()
        longPress(view, .began, at: point(column: 1, row: 3, in: view))
        longPress(view, .changed, at: point(column: 6, row: 4, in: view))
        longPress(view, .ended, at: point(column: 6, row: 4, in: view))
        let selected = view.selectedText

        longPress(view, .began, at: point(column: 2, row: 4, in: view))

        XCTAssertEqual(view.selectedText, selected)
    }

    func testTheEditMenuOffersTheQuoteBesideCopyOnlyWhileTextIsSelected() {
        let view = makeView()
        view.configureSelectionMenu(quoteSelection: { _ in }, canPaste: true)
        UIPasteboard.general.string = "pasted"

        XCTAssertEqual(
            titles(of: view.editMenuElements(suggested: [])),
            ["Select All", "Paste"]
        )

        select(row: Fixture.selectedRow, in: view)

        XCTAssertEqual(
            titles(of: view.editMenuElements(suggested: [])),
            ["Copy", Fixture.quoteTitle, "Select All", "Paste"]
        )
    }

    func testTheSystemsOwnEditCommandsAreUsedWhenItOffersThem() {
        let view = makeView()
        view.configureSelectionMenu(quoteSelection: { _ in }, canPaste: true)
        select(row: Fixture.selectedRow, in: view)
        let suggested = UIMenu(identifier: .standardEdit, children: [
            UICommand(title: "Kopiera", action: #selector(UIResponderStandardEditActions.copy(_:))),
            UICommand(title: "Markera allt", action: #selector(UIResponderStandardEditActions.selectAll(_:))),
        ])

        XCTAssertEqual(
            titles(of: view.editMenuElements(suggested: [suggested])).prefix(3),
            ["Kopiera", Fixture.quoteTitle, "Markera allt"]
        )
    }

    func testAViewOnlyPhoneIsOfferedNoPaste() {
        let view = makeView()
        view.configureSelectionMenu(quoteSelection: nil, canPaste: false)
        UIPasteboard.general.string = "pasted"
        select(row: Fixture.selectedRow, in: view)

        XCTAssertEqual(titles(of: view.editMenuElements(suggested: [])), ["Copy", "Select All"])
    }

    func testTheHandlesFollowTheThemesCursorColour() throws {
        let view = makeView()
        let theme = RemoteTerminalThemeDTO(
            id: "ember",
            name: "Ember",
            foreground: "#FFFFFF",
            background: "#000000",
            cursor: "#FF8800",
            selection: "#FFFFFF32",
            ansi: []
        )

        TerminalViewRepresentable.apply(theme, to: view)

        XCTAssertEqual(view.selectionHandleColor, try XCTUnwrap(UIColor(remoteHex: "#FF8800")))
    }

    // MARK: - Private Methods

    private func makeView(scrollback: Int? = nil) -> RemoteTerminalView {
        let font = UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        let view: RemoteTerminalView
        if let scrollback {
            view = RemoteTerminalView(
                frame: Fixture.frame,
                font: font,
                options: TerminalOptions(scrollback: scrollback)
            )
        } else {
            view = RemoteTerminalView(frame: Fixture.frame, font: font)
        }
        feedLines(Fixture.initialLines, into: view)
        return view
    }

    private func makeWindowedView() -> (UIWindow, RemoteTerminalView) {
        let window = UIWindow(frame: Fixture.frame)
        let view = makeView()
        window.addSubview(view)
        window.makeKeyAndVisible()
        return (window, view)
    }

    private var fedLines = 0

    private func feedLines(_ count: Int, into view: RemoteTerminalView) {
        for _ in 0..<count {
            view.feed(text: "line \(fedLines)\r\n")
            fedLines += 1
        }
        settleTerminalCallbacks(for: view)
    }

    private func settleTerminalCallbacks(for view: RemoteTerminalView) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private func select(row: Int, in view: RemoteTerminalView) {
        view.setSelectionRange(
            start: Position(col: 0, row: row),
            end: Position(col: "line \(row)".count, row: row)
        )
    }

    /// The centre of a cell in the scroll view's content, which is where a finger lands.
    private func point(column: Int, row: Int, in view: RemoteTerminalView) -> CGPoint {
        let cell = view.cellSize
        return CGPoint(
            x: (CGFloat(column) + 0.5) * cell.width,
            y: (CGFloat(row) + 0.5) * cell.height
        )
    }

    private func longPress(
        _ view: RemoteTerminalView,
        _ state: UIGestureRecognizer.State,
        at point: CGPoint
    ) {
        let recognizer = ScriptedLongPress(state: state, at: point, on: view)
        view.perform(Selector(("longPress:")), with: recognizer)
    }

    private func titles(of elements: [UIMenuElement]) -> [String] {
        elements.map(\.title)
    }
}

/// A long press frozen in one state at one point, so the gesture handler can be exercised
/// without a touch sequence the simulator would have to deliver.
private final class ScriptedLongPress: UILongPressGestureRecognizer {
    private let scriptedState: UIGestureRecognizer.State
    private let point: CGPoint

    init(state: UIGestureRecognizer.State, at point: CGPoint, on view: UIView) {
        scriptedState = state
        self.point = point
        super.init(target: nil, action: nil)
        view.addGestureRecognizer(self)
    }

    override var state: UIGestureRecognizer.State {
        get { scriptedState }
        set { super.state = newValue }
    }

    override func location(in view: UIView?) -> CGPoint { point }
}
