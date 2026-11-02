import Foundation
import Testing
@testable import ThreadingController

struct MailPolicyTests {
    @Test func policyPersistsAndInvalidLimitsLeaveItUntouched() async throws {
        let (directory, store) = try ControllerStoreTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await store.mailPolicy().chainMessageLimit == 50)
        try await store.setMailPolicy(chainMessageLimit: 125)
        let reopened = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(try await reopened.mailPolicy().chainMessageLimit == 125)
        for invalid in [0, -1, Int.min] {
            await #expect(throws: ControllerError.invalidInput("chain_message_limit")) {
                try await reopened.setMailPolicy(chainMessageLimit: invalid)
            }
        }
        #expect(try await reopened.mailPolicy().chainMessageLimit == 125)
    }

    @Test func configuredFuseCountsTheWholeChainAndHumanResetOnlyClearsInheritance() async throws {
        let (directory, store) = try ControllerStoreTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try await store.host().id
        let a = MailAddress(host: host, kind: .session, id: UUID())
        let b = MailAddress(host: host, kind: .session, id: UUID())
        _ = try await store.registerMailbox(a, name: "A")
        _ = try await store.registerMailbox(b, name: "B")
        try await store.setMailPolicy(chainMessageLimit: 1)
        let firstID = UUID()
        let first = try await store.sendMail(from: a, to: b, id: firstID, text: "First", replyTo: nil, priority: .normal, ownerAdmitted: true)
        // Retrying the identical send does not spend another message.
        let retry = try await store.sendMail(from: a, to: b, id: firstID, text: "First", replyTo: nil, priority: .normal, ownerAdmitted: true)
        #expect(retry == first)
        _ = try await store.acknowledgeMail(mailbox: b, ids: [firstID])
        await #expect(throws: ControllerError.mailChainLimit(1)) {
            try await store.sendMail(from: b, to: a, id: UUID(), text: "Reply", replyTo: nil, priority: .normal, ownerAdmitted: true)
        }
        #expect(try await store.inbox(a).items.isEmpty)
        try await store.resetMailContext(b)
        // A prompt does not zero the old chain's count, even when explicitly replying to it.
        await #expect(throws: ControllerError.mailChainLimit(1)) {
            try await store.sendMail(from: b, to: a, id: UUID(), text: "Old reply", replyTo: firstID, priority: .normal, ownerAdmitted: true)
        }
        let fresh = try await store.sendMail(from: b, to: a, id: UUID(), text: "New task", replyTo: nil, priority: .normal, ownerAdmitted: true)
        #expect(fresh.envelope.chainID != first.envelope.chainID && fresh.envelope.depth == 0)

        // An owner change is seen by already-open stores and existing chains, without a restart.
        let owner = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        try await owner.setMailPolicy(chainMessageLimit: 2)
        let oldReply = try await store.sendMail(from: b, to: a, id: UUID(), text: "Old reply", replyTo: firstID, priority: .normal, ownerAdmitted: true)
        #expect(oldReply.envelope.chainID == first.envelope.chainID)
        await #expect(throws: ControllerError.mailChainLimit(2)) {
            try await store.sendMail(from: a, to: b, id: UUID(), text: "Third", replyTo: oldReply.envelope.id, priority: .normal, ownerAdmitted: true)
        }
    }

    @Test func authenticatedDirectoryReportsTheCurrentPolicy() async throws {
        let (directory, store) = try ControllerStoreTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = MailAddress(host: try await store.host().id, kind: .session, id: UUID())
        _ = try await store.registerMailbox(address, name: "A")
        let credential = try await store.mailboxCredential(address)
        try await store.setMailPolicy(chainMessageLimit: 75)
        let response = try await store.mailboxRequest(address: address, credential: credential, request: .mailDirectory)
        #expect(response.mailPolicy?.chainMessageLimit == 75)
        #expect(response.address == address)
    }
}
