import AppKit
import ThreadingController
import XCTest
@testable import Threading

final class MailPolicySettingsTests: XCTestCase {
    @MainActor
    func testOwnerEditsPersistAndInvalidInputCannotBeSaved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mailbox.db")
        let mailbox = MacMailbox(databaseURL: url)
        let controller = MailPolicySettingsController(mailbox: mailbox)
        let row = controller.makeRow()
        await controller.load()
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
        }
        let field = try XCTUnwrap(descendants(row, ThemedTextField.self).first)
        let save = try XCTUnwrap(descendants(row, ThemedButton.self).first {
            $0.accessibilityIdentifier() == "settings.tools.mail.save"
        })
        XCTAssertEqual(field.stringValue, "50")
        XCTAssertFalse(save.isEnabled)
        for invalid in ["", "0", "-2", "2.5", "abc", String(repeating: "9", count: 30)] {
            field.stringValue = invalid
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertFalse(save.isEnabled, invalid)
            await controller.save()
            let policy = try await mailbox.policy()
            XCTAssertEqual(policy.chainMessageLimit, 50)
        }
        field.stringValue = "125"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(save.performPrimaryAction())
        let deadline = Date().addingTimeInterval(5)
        while try await mailbox.policy().chainMessageLimit != 125, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reopened = MacMailbox(databaseURL: url)
        let policy = try await reopened.policy()
        XCTAssertEqual(policy.chainMessageLimit, 125)
        let nextController = MailPolicySettingsController(mailbox: reopened)
        let nextRow = nextController.makeRow()
        await nextController.load()
        XCTAssertEqual(descendants(nextRow, ThemedTextField.self).first?.stringValue, "125")
    }

    func testRefusalTellsTheAgentWhatToSayAndUsesTheActualLimit() {
        let words = MailAgentCommandService.mailWords(for: .refused(.mailChainLimit(125)))
        XCTAssertTrue(words.contains("125 messages"))
        XCTAssertFalse(words.contains("50"))
        XCTAssertTrue(words.contains("Message not sent"))
        XCTAssertTrue(words.contains("Tell the user in the chat"))
        XCTAssertTrue(words.contains("new human prompt"))
        XCTAssertTrue(words.contains("without reply_to"))
        XCTAssertTrue(words.contains("old chain stays capped"))
    }
}
