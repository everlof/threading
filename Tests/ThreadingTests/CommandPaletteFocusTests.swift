import AppKit
import XCTest
@testable import Threading

@MainActor
final class CommandPaletteFocusTests: XCTestCase {
    func testEscapeRestoresTheTerminalResponderAndDismissesOnce() throws {
        let (window, terminal) = fixture()
        let controller = palette()
        var dismissals = 0
        controller.onDismiss = { dismissals += 1 }
        XCTAssertTrue(window.makeFirstResponder(terminal))
        controller.present(in: window)
        XCTAssertFalse(window.firstResponder === terminal)
        XCTAssertTrue(controller.handleKeyForTesting(try escape(in: window)))
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertFalse(controller.isPresentedForTesting)
        controller.dismiss()
        XCTAssertEqual(dismissals, 1)
    }

    func testTextFieldRestorationUsesTheControlInsteadOfTheSharedFieldEditor() throws {
        let (window, _) = fixture()
        let field = ThemedTextField(string: "draft")
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let controller = palette()
        controller.present(in: window)
        controller.dismiss()
        XCTAssertNotNil(field.currentEditor())
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        XCTAssertEqual(field.stringValue, "draft")
    }

    func testRefusedCommandKeepsTheOriginalReturnTargetAndSuccessfulCommandOwnsNewFocus() throws {
        let (window, terminal) = fixture()
        let destination = ThemedTextField(string: "next surface")
        window.contentView?.addSubview(destination)
        var refuses = true
        let controller = palette { request in
            XCTAssertTrue(window.firstResponder === terminal, "restore before responder-chain invocation")
            if refuses { return .refused(commandID: request.commandID, reason: "Changed") }
            window.makeFirstResponder(destination)
            return .invoked(commandID: request.commandID)
        }
        XCTAssertTrue(window.makeFirstResponder(terminal))
        controller.present(in: window)
        drain { !controller.visibleCommandIDsForTesting.isEmpty }
        controller.confirmSelectionForTesting()
        XCTAssertTrue(controller.isPresentedForTesting)
        controller.dismiss()
        XCTAssertTrue(window.firstResponder === terminal)

        refuses = false
        controller.present(in: window)
        drain { !controller.visibleCommandIDsForTesting.isEmpty }
        controller.confirmSelectionForTesting()
        XCTAssertFalse(controller.isPresentedForTesting)
        XCTAssertTrue(window.firstResponder === destination.currentEditor())
    }

    func testEscapeReturnsKeyboardToTerminalInKeyWindow() throws {
        NSApp.activate(ignoringOtherApps: true)
        let activationDeadline = Date().addingTimeInterval(2)
        while !NSApp.isActive, Date() < activationDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try XCTSkipUnless(NSApp.isActive, "The hosted test cannot acquire key-window status.")
        let (window, terminal) = fixture()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === window)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        let controller = palette()
        controller.present(in: window)
        XCTAssertFalse(window.firstResponder === terminal)
        XCTAssertTrue(controller.handleKeyForTesting(try escape(in: window)))
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === window)
        XCTAssertTrue(window.firstResponder === terminal, "the real terminal owns the keyboard again")
    }

    private func fixture() -> (NSWindow, EmojiFixedTerminalView) {
        let window = TitlebarActionWindow(
            contentRect: NSRect(x: 120, y: 120, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        let terminal = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        window.contentView = terminal
        return (window, terminal)
    }

    private func palette(
        invoke: @escaping (HostCommandInvocationRequest) -> HostCommandInvocationOutcome = {
            .invoked(commandID: $0.commandID)
        }
    ) -> CommandPaletteViewController {
        CommandPaletteViewController(
            catalog: {
                [AppCommands.command(id: AppCommands.ID.refreshModels)!.hostDescriptor(
                    shortcut: nil, availability: .available
                )]
            },
            inputOptions: { _ in [] }, invokeRequest: invoke, shortcutEditing: nil
        )
    }

    private func escape(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        ))
    }

    private func drain(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }
}
