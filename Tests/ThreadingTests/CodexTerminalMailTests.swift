import XCTest
import ThreadingController
@testable import Threading

@MainActor
final class CodexTerminalMailTests: XCTestCase {
    private let destination = CodexTerminalMail.Target(
        executable: "/fixture/codex", socketPath: "/fixture/sock",
        threadID: UUID().uuidString, accountHome: "/fixture/account"
    )

    private actor Queue {
        var notices: [String] = []
        var accept = true
        var hold: CheckedContinuation<Void, Never>?
        var suspended = false
        func enqueue(_ target: CodexTerminalMail.Target, _ text: String) async -> Bool {
            notices.append(text)
            if suspended { await withCheckedContinuation { hold = $0 } }
            return accept
        }
        func configure(accept: Bool = true, suspended: Bool = false) { self.accept = accept; self.suspended = suspended }
        func release() { suspended = false; hold?.resume(); hold = nil }
    }

    func testIdleArrivalCoalescesBurstAndConsumesOnlyTheReceiptedNotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let mailbox = MacMailbox(databaseURL: root.appendingPathComponent("mail.db"))
        let recipient = SessionID(), queue = Queue()
        let address = try await mailbox.register(recipient, name: "ALPHA")
        let destination = destination
        let delivery = CodexTerminalMail(mailbox: mailbox, target: { _ in destination },
                                        enqueue: { await queue.enqueue($0, $1) })
        await queue.configure(suspended: true)
        let first = UUID()
        _ = try await mailbox.send(from: SessionID(), senderName: "VERIFICATION", to: address, id: first,
                                   text: "PRIVATE_PEER_BODY", replyTo: nil, priority: .normal, ownerAdmitted: true)
        delivery.arrived(for: recipient)
        for _ in 0..<1000 {
            if await queue.hold != nil { break }
            await Task.yield()
        }
        let beforeReceipt = await mailbox.pendingWake(for: recipient)
        XCTAssertNotNil(beforeReceipt, "No receipt yet")
        for _ in 0..<10_000 { delivery.arrived(for: recipient) }
        let second = UUID()
        _ = try await mailbox.send(from: SessionID(), senderName: "BETA", to: address, id: second,
                                   text: "SECOND_PRIVATE_BODY", replyTo: nil, priority: .normal, ownerAdmitted: true)
        delivery.arrived(for: recipient)
        await queue.release()
        await waitUntil {
            let count = await queue.notices.count
            let pending = await mailbox.pendingWake(for: recipient)
            return count == 2 && pending == nil
        }
        let notices = await queue.notices
        XCTAssertEqual(notices.count, 2)
        XCTAssertTrue(notices[0].contains("VERIFICATION"))
        XCTAssertFalse(notices.joined().contains("PRIVATE"))
        let inbox = try await mailbox.inbox(for: recipient, name: "ALPHA", after: 0, limit: 10)
        XCTAssertEqual(inbox.items.count, 2, "Queue receipts are not mail acknowledgments")
        XCTAssertTrue(inbox.items.allSatisfy { $0.message.stopBlocked == true })
        for _ in 0..<100 { delivery.activityChanged(recipient) }
        for _ in 0..<50 { await Task.yield() }
        let afterEdges = await queue.notices.count
        XCTAssertEqual(afterEdges, 2, "Unacknowledged mail must not loop")
    }

    func testFailedQueueAndIneligibleRecipientLeaveMailForRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-mail-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let mailbox = MacMailbox(databaseURL: root.appendingPathComponent("mail.db"))
        let recipient = SessionID(), queue = Queue()
        let address = try await mailbox.register(recipient, name: "ALPHA")
        _ = try await mailbox.send(from: SessionID(), senderName: "Peer", to: address, id: UUID(),
                                   text: "PRIVATE", replyTo: nil, priority: .normal, ownerAdmitted: true)
        var current: CodexTerminalMail.Target?
        let delivery = CodexTerminalMail(mailbox: mailbox, target: { _ in current },
                                        enqueue: { await queue.enqueue($0, $1) })
        delivery.arrived(for: recipient)
        await queue.configure(accept: false)
        current = destination
        delivery.activityChanged(recipient)
        await waitUntil { await queue.notices.count == 1 }
        for _ in 0..<100 { await Task.yield() }
        let afterFailure = await mailbox.pendingWake(for: recipient)
        XCTAssertNotNil(afterFailure)
        await queue.configure()
        current = nil
        delivery.activityChanged(recipient)
        current = destination
        delivery.activityChanged(recipient)
        await waitUntil { await mailbox.pendingWake(for: recipient) == nil }
        let delivered = await queue.notices.count
        XCTAssertEqual(delivered, 2)
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Delivery did not settle")
    }
}
