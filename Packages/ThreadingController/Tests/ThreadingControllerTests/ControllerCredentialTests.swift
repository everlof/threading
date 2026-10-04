import Foundation
import Testing
@testable import ThreadingController

extension ControllerStore {
    func rawPayload(_ kind: String, _ id: String) throws -> String? {
        try db.rows("SELECT payload FROM record WHERE kind=? AND id=?", [.text(kind), .text(id)]).first?.text(0)
    }
    func rawExecute(_ sql: String, _ values: [ControllerDatabase.Value]) throws { try db.run(sql, values) }
}

/// Bearer credentials are kept as digests: a copy of the store authenticates nothing.
struct ControllerCredentialTests {
    let helpers = ControllerStoreTests()
    let launches = ControllerLaunchTests()

    @Test func theStoredExecutionCredentialIsADigestNotThePlaintext() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: launches.spec()))
        #expect(try await store.rawPayload(ControllerCredential.executionKind, launch.executionID.description) == nil,
                "nothing is issued before the spawn right is consumed")
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        let stored = try #require(await store.rawPayload(ControllerCredential.executionKind, launch.executionID.description))
        #expect(!stored.contains(credential))
        #expect(stored == "\"\(ControllerCredential.digest(credential))\"")
        #expect(try await store.agentRequest(executionID: launch.executionID, credential: credential, request: .context).work?.id == work.id)
        await #expect(throws: ControllerError.forbidden) {
            try await store.agentRequest(executionID: launch.executionID,
                                         credential: String(stored.dropFirst().dropLast()), request: .context)
        }
    }

    @Test func theStoredMailboxCredentialIsADigestNotThePlaintext() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = MailAddress(host: try await store.host().id, kind: .session, id: UUID())
        _ = try await store.registerMailbox(session, name: "Console")
        let credential = try await store.mailboxCredential(session)
        let stored = try #require(await store.rawPayload(ControllerCredential.mailboxKind, session.description))
        #expect(!stored.contains(credential) && stored.contains(ControllerCredential.digestPrefix))
        #expect(try await store.mailboxRequest(address: session, credential: credential, request: .mailDirectory).address == session)
    }

    /// A store written by an older build holds plaintext; opening it digests every credential
    /// once, and the agent holding the plaintext keeps working.
    @Test func openingAnOlderStoreDigestsItsPlaintextCredentials() async throws {
        let (directory, store) = try helpers.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = try await helpers.seed(store)
        let launch = try #require(await store.prepareLaunch(workerID: work.workerID, spec: launches.spec()))
        _ = try await store.beginLaunch(launch.executionID)
        let legacy = ControllerCredential.mint()
        try await store.rawExecute("INSERT INTO record(kind,id,payload) VALUES(?,?,?)",
                                   [.text(ControllerCredential.executionKind), .text(launch.executionID.description), .text("\"\(legacy)\"")])
        try await store.rawExecute("DELETE FROM record WHERE kind=? AND id=?",
                                   [.text(ControllerCredential.migrationKind), .text(ControllerCredential.migrationID)])
        let reopened = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        let stored = try #require(await reopened.rawPayload(ControllerCredential.executionKind, launch.executionID.description))
        #expect(stored == "\"\(ControllerCredential.digest(legacy))\"")
        #expect(try await reopened.rawPayload(ControllerCredential.migrationKind, ControllerCredential.migrationID) != nil)
        #expect(try await reopened.agentRequest(executionID: launch.executionID, credential: legacy, request: .context).work?.id == work.id)
    }

    @Test func comparisonRefusesEverythingButTheIssuedCredential() {
        let credential = ControllerCredential.mint()
        let stored = ControllerCredential.digest(credential)
        #expect(ControllerCredential.matches(credential, stored: stored))
        #expect(!ControllerCredential.matches(credential + "x", stored: stored))
        #expect(!ControllerCredential.matches("", stored: stored))
        #expect(!ControllerCredential.matches(stored, stored: stored), "the digest is not itself a credential")
        #expect(!ControllerCredential.matches(credential, stored: nil))
    }

    @Test func aCredentialShapedTokenIsRedactedFromATailWithoutItsValue() {
        let credential = ControllerCredential.mint()
        let tail = ControllerOutputTail.redact(Data("token \(credential.lowercased()) end".utf8), secrets: [])
        #expect(tail == "token [redacted] end")
    }
}
