import SwiftTerm
import UIKit
import XCTest
@testable import ThreadingMobile

/// The key bar carries the way back from the keyboard, because it replaces SwiftTerm's own
/// accessory row which used to carry it. The control was there and did nothing at all.
@MainActor
final class TerminalKeyboardDismissalTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let windowFrame = CGRect(x: 0, y: 0, width: 390, height: 844)
        static let fontSize: CGFloat = 12
    }

    // MARK: - Tests

    func testDismissingPutsTheTerminalsKeyboardAway() {
        let (window, view, bridge) = makeFocusedTerminal()
        defer { window.isHidden = true }
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(bridge.isKeyboardShowing)

        bridge.dismissKeyboard()

        XCTAssertFalse(view.isFirstResponder)
        XCTAssertFalse(bridge.isKeyboardShowing)
    }

    /// Nothing is holding the keyboard and nothing crashes; the bar may be tapped either way.
    func testDismissingIsHarmlessWithNothingFocused() {
        let (window, view, bridge) = makeFocusedTerminal()
        defer { window.isHidden = true }
        bridge.dismissKeyboard()

        bridge.dismissKeyboard()

        XCTAssertFalse(view.isFirstResponder)
    }

    func testABridgeWithNoTerminalReportsNoKeyboard() {
        XCTAssertFalse(TerminalKeyBridge().isKeyboardShowing)
    }

    /// A platform tripwire, not a behaviour of ours. `UIApplication.sendAction` broadcasting
    /// `resignFirstResponder` is the idiom that dismisses a `UITextField`, and the bar shipped
    /// with it — but it leaves this terminal first responder, which is why the button did
    /// nothing. If a future iOS makes this pass, the direct call is still correct and this test
    /// is what says the constraint has gone away.
    func testTheApplicationBroadcastStillDoesNotReachTheTerminal() {
        let (window, view, _) = makeFocusedTerminal()
        defer { window.isHidden = true }

        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )

        XCTAssertTrue(view.isFirstResponder)
    }

    // MARK: - Private Methods

    private func makeFocusedTerminal() -> (UIWindow, RemoteTerminalView, TerminalKeyBridge) {
        let window = UIWindow(frame: Fixture.windowFrame)
        let view = RemoteTerminalView(
            frame: Fixture.windowFrame,
            font: UIFont.monospacedSystemFont(ofSize: Fixture.fontSize, weight: .regular)
        )
        window.addSubview(view)
        window.makeKeyAndVisible()
        let bridge = TerminalKeyBridge()
        bridge.terminalView = view
        XCTAssertTrue(view.becomeFirstResponder())
        return (window, view, bridge)
    }
}
