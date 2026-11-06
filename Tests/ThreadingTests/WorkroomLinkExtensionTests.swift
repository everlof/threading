import AppKit
import ThreadingController
import XCTest
@testable import Threading

@MainActor
final class WorkroomLinkExtensionTests: XCTestCase {
    func testConfirmExtendsTheSelectedExistingLinkAndCancelLeavesItAlone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ControllerStore(path: directory.appendingPathComponent("mail.db").path)
        let person = try await store.addWorkroomPerson(id: WorkroomPersonID(), handle: "expert", name: "Expert", language: "sv")
        let (invitation, token) = try await store.issueWorkroomInvitation(person: person.id)
        let target = WorkroomLinkExtension.Target(person: person, invitation: invitation)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 720, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        let cancelled = expectation(description: "cancelled")
        WorkroomLinkExtension.present(targets: [target], store: store, in: window) { success in
            XCTAssertFalse(success)
            cancelled.fulfill()
        }
        let cancelPanel = try XCTUnwrap(window.childWindows?.first)
        cancelPanel.cancelOperation(nil)
        await fulfillment(of: [cancelled], timeout: 5)
        let unchanged = try await store.latestWorkroomInvitation(person: person.id)
        XCTAssertEqual(unchanged, invitation)

        let confirmed = expectation(description: "extended")
        WorkroomLinkExtension.present(targets: [target], store: store, in: window) { success in
            XCTAssertTrue(success)
            confirmed.fulfill()
        }
        let content = try XCTUnwrap(window.childWindows?.first?.contentView)
        let confirm = try XCTUnwrap(descendants(content).compactMap { $0 as? ThemedButton }
            .first { $0.title == L10n.string("Extend Link") })
        XCTAssertTrue(confirm.performPrimaryAction())
        await fulfillment(of: [confirmed], timeout: 5)
        let changed = try await store.latestWorkroomInvitation(person: person.id)
        XCTAssertEqual(changed?.id, invitation.id)
        XCTAssertNotEqual(changed?.expiresAt, invitation.expiresAt)
        let oldExpiry = try XCTUnwrap(ISO8601DateFormatter().date(from: invitation.expiresAt))
        let participant = try await store.redeemWorkroomInvitation(token, deviceLabel: "Safari",
                                                                  now: oldExpiry.addingTimeInterval(1))
        XCTAssertEqual(participant.0.person.id, person.id)
    }

    func testCommandAndSheetNameTheLifetimeAndKeepSecurityConfirmation() throws {
        XCTAssertTrue(AppCommands.editable.contains { $0.id == "workroom.extendLink" && $0.isEditable })
        guard case .alwaysAsks(.securityGrant) = ConfirmationPrompt.extendWorkroomInvitation.policy else {
            return XCTFail("extending an invitation requires the owner's confirmation")
        }
        let (request, _) = WorkroomLinkExtension.request(targets: [])
        XCTAssertTrue(request.message.contains("seven days"))
        XCTAssertTrue(request.message.contains("Room closing dates"))
        XCTAssertEqual(request.confirmTitle, L10n.string("Extend Link"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
