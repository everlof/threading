import AppKit
import XCTest
@testable import Threading

/// The pointer over a search field's trailing controls.
///
/// `NSTextField` registers one I-beam rectangle over its **whole** bounds, so the buttons riding
/// inside the field's trailing edge — Settings' Ask AI, and the ✕ every search field carries —
/// were answered with "type here" rather than with the arrow every other button shows. The field
/// now declares the caret's room instead (`PointerClaiming`), which the first test states as the
/// platform fact that behaviour replaces and the rest as what the declaration buys.
@MainActor
final class SearchFieldPointerTests: XCTestCase {

    /// A stand-in for the themed field — same shape of cell, inset on both sides — recording
    /// what `NSTextField` itself asks for. `ThemedSearchField` is `final`, and the fact under
    /// test belongs to AppKit rather than to us.
    private final class InsetFieldSpy: NSTextField {
        static let leadingInset: CGFloat = 28
        static let trailingInset: CGFloat = 90

        final class Cell: NSTextFieldCell {
            override func drawingRect(forBounds rect: NSRect) -> NSRect {
                var inset = rect
                inset.origin.x += InsetFieldSpy.leadingInset
                inset.size.width -= InsetFieldSpy.leadingInset + InsetFieldSpy.trailingInset
                return super.drawingRect(forBounds: inset)
            }
        }

        override class var cellClass: AnyClass? {
            get { Cell.self }
            set { super.cellClass = newValue }
        }

        var received: [(rect: NSRect, cursor: NSCursor)] = []

        override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
            received.append((rect, cursor))
            super.addCursorRect(rect, cursor: cursor)
        }
    }

    private enum Fixture {
        static let width: CGFloat = 320
        static let query = "notifications"
    }

    @objc private func askAI() {}

    func testAnEditableFieldClaimsItsWholeBoundsForTheCaretsCursor() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Fixture.width + 20, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let field = InsetFieldSpy(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: 26))
        field.isBezeled = false
        window.contentView?.addSubview(field)

        field.resetCursorRects()

        let claim = try XCTUnwrap(
            field.received.first,
            "An editable field registers a cursor rectangle; the clip has nothing to do otherwise."
        )
        XCTAssertEqual(
            claim.rect, field.bounds,
            "AppKit claims the whole control, not the cell's drawing rect — so the trailing inset "
                + "that keeps the text clear of the controls does not keep the pointer clear of them."
        )
        XCTAssertTrue(claim.cursor === NSCursor.iBeam, "The claim is the caret's cursor.")
        XCTAssertLessThan(
            field.cell!.drawingRect(forBounds: field.bounds).maxX, claim.rect.maxX,
            "The inset the fixture states is real; the claim reaches past it anyway."
        )
    }

    func testTheIBeamStopsWhereTheTrailingControlsBeginAndLeavesTheQueryAlone() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Fixture.width + 20, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let field = ThemedSearchField(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: 0))
        field.frame.size.height = field.intrinsicContentSize.height
        window.contentView?.addSubview(field)

        field.installTrailingAction(
            title: "Ask AI",
            accessibilityLabel: "Ask AI about settings",
            accessibilityIdentifier: "settings.search.askAI",
            target: self,
            action: #selector(askAI)
        )
        field.isTrailingActionVisible = true
        field.stringValue = Fixture.query
        field.layoutSubtreeIfNeeded()

        let action = try XCTUnwrap(field.trailingActionButton)
        XCTAssertFalse(action.isHidden)
        XCTAssertFalse(field.clearButton.isHidden)

        let query = try XCTUnwrap(
            field.resolvedPointerClaims().first { $0.cursor === NSCursor.iBeam }?.rect,
            "an editable field claims the caret's room"
        )
        for button in [action, field.clearButton] as [NSView] {
            let frame = button.convert(button.bounds, to: field)
            XCTAssertFalse(
                query.intersects(frame),
                "\(button) is a button: the pointer over it keeps the arrow, so the caret's "
                    + "rectangle may not reach it."
            )
        }
        XCTAssertEqual(query.minX, field.bounds.minX)
        XCTAssertTrue(
            query.contains(NSPoint(x: field.bounds.midX / 2, y: field.bounds.midY)),
            "The query itself is still text to point at."
        )
    }

    func testAFieldWithNothingInItsTrailingRunKeepsTheWholeIBeam() {
        let field = ThemedSearchField(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: 0))
        field.frame.size.height = field.intrinsicContentSize.height
        field.layoutSubtreeIfNeeded()

        XCTAssertTrue(field.clearButton.isHidden, "Nothing typed, so nothing to clear.")
        XCTAssertEqual(
            field.caretRect, field.bounds,
            "With no control on offer the field is the field it always was."
        )
        XCTAssertEqual(field.resolvedPointerClaims(), [PointerClaim(field.bounds, .iBeam)])
    }

    func testClearingTheQueryGivesTheRoomBackToTheCaret() {
        let field = ThemedSearchField(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: 0))
        field.frame.size.height = field.intrinsicContentSize.height
        field.stringValue = Fixture.query
        field.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            field.caretRect.maxX, field.bounds.maxX,
            "The ✕ is standing in the trailing edge."
        )

        field.clear()
        field.layoutSubtreeIfNeeded()

        XCTAssertEqual(field.caretRect, field.bounds)
    }

    func testAFieldThatCannotBeTypedIntoClaimsNoCaretAtAll() {
        let field = ThemedTextField(string: "read only")
        field.frame = NSRect(x: 0, y: 0, width: Fixture.width, height: 26)
        field.isEditable = false
        field.isSelectable = false

        XCTAssertNil(
            field.resolvedPointerClaims().first { $0.cursor === NSCursor.iBeam },
            "AppKit claims no I-beam for one of these, and neither do we — see the first test."
        )
        XCTAssertEqual(
            field.resolvedPointerClaims(), [PointerClaim(field.bounds, .arrow)],
            "It is still an opaque plate, so it still answers for what it covers."
        )
    }
}
