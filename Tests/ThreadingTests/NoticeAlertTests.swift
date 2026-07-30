import AppKit
import XCTest
@testable import Threading

/// The OK-only sibling of `ConfirmationAlertTests`: a statement the user may decline to see
/// again. Everything is built rather than run, so no modal is involved — the one behavioural
/// path that matters, the silent one, is a guard that runs before any alert exists.
@MainActor
final class NoticeAlertTests: XCTestCase {

    private let refreshKey = "extension.com.example.checks.refresh"

    private func scratchSettings() throws -> AppSettings {
        let suite = "NoticeAlert.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }

    private func receipt(notice: AppNotice?) -> NoticeRequest {
        NoticeRequest(
            notice: notice,
            title: "Refresh GitHub Checks",
            message: "Checks refreshed."
        )
    }

    // MARK: - Building

    /// A keyed notice offers the box; a keyless one — every error — cannot, because a box the
    /// alert would never honour is a promise the app cannot keep.
    func testOnlyAKeyedNoticeGetsTheBox() {
        let keyed = NoticeAlert.makeAlert(
            receipt(notice: .extensionCommandReceipt(commandID: refreshKey))
        )
        XCTAssertTrue(keyed.showsSuppressionButton)
        XCTAssertEqual(keyed.suppressionButton?.title, "Don't show this message again")

        let keyless = NoticeAlert.makeAlert(receipt(notice: nil))
        XCTAssertFalse(keyless.showsSuppressionButton)
    }

    /// The box is honoured only when OK dismissed the alert: an escaped or sheet-closed notice
    /// recorded no decision — the same rule the confirmation register states for an answer.
    func testTheBoxIsHonouredOnlyOnOK() {
        XCTAssertTrue(NoticeAlert.remembers(acknowledged: true, suppressionChecked: true))
        XCTAssertFalse(NoticeAlert.remembers(acknowledged: false, suppressionChecked: true))
        XCTAssertFalse(NoticeAlert.remembers(acknowledged: true, suppressionChecked: false))
        XCTAssertFalse(NoticeAlert.remembers(acknowledged: false, suppressionChecked: false))
    }

    // MARK: - Hiding

    /// A hidden notice is not put up at all, and the way back is all-at-once — dynamic keys
    /// mean there is no honest per-key list to offer once an extension is gone.
    func testAHiddenNoticeIsSilentAndComesBackAllAtOnce() throws {
        let settings = try scratchSettings()
        let notice = AppNotice.extensionCommandReceipt(commandID: refreshKey)
        let request = receipt(notice: notice)

        XCTAssertTrue(NoticeAlert.isShown(request, settings: settings))

        settings.setShows(false, for: notice)
        XCTAssertFalse(NoticeAlert.isShown(request, settings: settings))
        XCTAssertEqual(settings.hiddenNoticeCount, 1)

        settings.showAllNoticesAgain()
        XCTAssertTrue(NoticeAlert.isShown(request, settings: settings))
        XCTAssertEqual(settings.hiddenNoticeCount, 0)
    }

    /// Hiding one command's receipt says nothing about another command's — the key is the
    /// qualified command id, not the extension.
    func testHidingIsPerCommand() throws {
        let settings = try scratchSettings()
        settings.setShows(false, for: .extensionCommandReceipt(commandID: refreshKey))

        XCTAssertTrue(
            settings.shows(
                .extensionCommandReceipt(commandID: "extension.com.example.checks.open")
            )
        )
    }

    // MARK: - The invoker's receipts

    /// A success carries the command's own key, so its "done" message can be declined; a
    /// failure carries none, so it can never be hidden — a command whose failures stopped
    /// showing would read as working.
    func testOnlyASuccessReceiptCanBeDeclined() throws {
        let registry = CommandRegistry(builtInCommands: [])
        registry.replaceExtensionCommands(
            extensionIdentifier: "com.example.checks",
            extensionName: "GitHub Checks",
            commands: [.init(id: "refresh", title: "Refresh GitHub Checks")]
        )
        let command = try XCTUnwrap(registry.extensionCommands.first)

        let success = ExtensionCommandInvoker.resultNotice(
            for: command,
            message: "Checks refreshed.",
            isError: false
        )
        XCTAssertEqual(success.notice, .extensionCommandReceipt(commandID: refreshKey))
        XCTAssertEqual(success.style, .informational)

        let failure = ExtensionCommandInvoker.resultNotice(
            for: command,
            message: "Rate limited.",
            isError: true
        )
        XCTAssertNil(failure.notice, "a failure must never be hidable")
        XCTAssertEqual(failure.style, .warning)
    }
}
