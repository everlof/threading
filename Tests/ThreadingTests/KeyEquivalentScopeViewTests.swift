import AppKit
import XCTest
@testable import Threading

@MainActor
final class KeyEquivalentScopeViewTests: XCTestCase {
    func testAnswersChordsOnlyWhileFocusIsInside() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content

        let scope = KeyEquivalentScopeView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let inside = KeyEquivalentFocusProbe(frame: NSRect(x: 10, y: 10, width: 40, height: 40))
        scope.addSubview(inside)
        let outside = KeyEquivalentFocusProbe(frame: NSRect(x: 250, y: 10, width: 40, height: 40))
        content.addSubview(scope)
        content.addSubview(outside)

        var received = 0
        scope.onKeyEquivalent = { event in
            received += 1
            return event.charactersIgnoringModifiers == "r"
        }
        let commandR = try keyEvent("r", window: window)

        XCTAssertTrue(window.makeFirstResponder(outside))
        XCTAssertFalse(window.performKeyEquivalent(with: commandR))
        XCTAssertEqual(received, 0, "a scope without focus must not see the chord at all")

        XCTAssertTrue(window.makeFirstResponder(inside))
        XCTAssertTrue(scope.containsKeyboardFocus)
        XCTAssertTrue(window.performKeyEquivalent(with: commandR))
        XCTAssertEqual(received, 1)

        XCTAssertFalse(
            window.performKeyEquivalent(with: try keyEvent("x", window: window)),
            "a chord the handler declines continues to the rest of the window and the menu"
        )
    }

    func testFieldEditorInsideTheScopeCountsAsFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let scope = KeyEquivalentScopeView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView = scope
        let field = ThemedTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        scope.addSubview(field)

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(window.firstResponder is NSText, "editing moves focus to the field editor")
        XCTAssertTrue(scope.containsKeyboardFocus)
    }

    private func keyEvent(_ key: String, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 15
        ))
    }
}

private final class KeyEquivalentFocusProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
}
