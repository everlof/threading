import AppKit
import XCTest
@testable import Threading

/// Typing the opening message does not broadcast a settings change per character.
///
/// Every `AppSettingsDidChange` makes its observers re-read each project's git control files,
/// re-scan the three sound directories twice over, and diff a snapshot of every session — several
/// milliseconds of filesystem work, which is why this field was reported as unusably slow to type
/// in. A settled value still has to reach the store, so what is asserted is both halves: silence
/// while typing, and one write when the field is left.
@MainActor
final class OpeningMessageCoalescingTests: XCTestCase {

    private var original = ""

    override func setUp() {
        super.setUp()
        original = AppSettings.shared.newChatOpeningMessage
    }

    override func tearDown() {
        AppSettings.shared.newChatOpeningMessage = original
        super.tearDown()
    }

    func testTypingDoesNotWriteOrBroadcastPerCharacter() throws {
        let controller = GeneralPreferencesViewController()
        _ = controller.view
        let field = try openingMessageField(in: controller)

        AppSettings.shared.newChatOpeningMessage = "before"
        // The page opens showing whatever is stored, so start from an empty field.
        field.stringValue = ""

        var broadcasts = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppSettingsDidChange.name,
            object: nil,
            queue: .main
        ) { _ in broadcasts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        for character in "a settled sentence" {
            field.stringValue += String(character)
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field)
            )
        }

        XCTAssertEqual(broadcasts, 0, "typing broadcast a settings change per character")
        XCTAssertEqual(
            AppSettings.shared.newChatOpeningMessage,
            "before",
            "the value should not be committed while it is still being typed"
        )

        controller.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )

        XCTAssertEqual(
            AppSettings.shared.newChatOpeningMessage,
            "a settled sentence",
            "leaving the field should settle what was typed into it"
        )
        XCTAssertEqual(broadcasts, 1, "a settled value is one change, not eighteen")
    }

    /// Closing Settings without leaving the field first is the other way out of this row.
    func testLeavingThePageSettlesWhatWasTyped() throws {
        let controller = GeneralPreferencesViewController()
        _ = controller.view
        let field = try openingMessageField(in: controller)

        AppSettings.shared.newChatOpeningMessage = ""
        field.stringValue = "typed, then the window closed"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
        controller.viewWillDisappear()

        XCTAssertEqual(
            AppSettings.shared.newChatOpeningMessage,
            "typed, then the window closed",
            "a page closed mid-sentence must not drop the sentence"
        )
    }

    private func openingMessageField(
        in controller: GeneralPreferencesViewController
    ) throws -> ThemedTextField {
        let field = descendants(of: controller.view)
            .compactMap { $0 as? ThemedTextField }
            .first { $0.accessibilityIdentifier() == "settings.general.new-chat-opening-message" }
        return try XCTUnwrap(field, "the opening-message field should be on the page")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
