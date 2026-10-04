import Foundation
import Testing
import ThreadingController
@testable import ControllerRuntime

/// The broker in-process: what it serves, what it refuses, and that one silent client holds one
/// slot rather than the broker.
private struct BrokerFixture {
    let root: URL
    let store: ControllerStore
    let broker: ControllerAgentBroker
    let worker = WorkerID()

    init() async throws {
        // Short: a Unix socket path has a 104-byte limit on Darwin.
        root = URL(fileURLWithPath: "/tmp").appendingPathComponent("cab-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("controller.db").path
        store = try ControllerStore(path: database)
        broker = try ControllerAgentBroker(socketPath: ControllerAgentBroker.defaultSocketPath(database: database),
                                           store: try ControllerStore(path: database))
        broker.start()
        _ = try await store.addWorker(id: worker, name: "Fixture")
    }
    func remove() { broker.stop(); try? FileManager.default.removeItem(at: root) }

    func running(key: String) async throws -> (ExecutionID, String) {
        _ = try await store.enqueue(workerID: worker, key: key, instruction: "Synthetic")
        let spec = ControllerLaunchSpec(socketPath: "/tmp/unused.sock", executable: "/bin/true", arguments: [], environment: [:],
                                        directory: root.path, recipients: ["person:operator"], destination: "fixture")
        let launch = try #require(await store.prepareLaunch(workerID: worker, spec: spec))
        _ = try await store.beginLaunch(launch.executionID)
        let credential = try await store.launchCredential(launch.executionID)
        _ = try await store.recordSpawn(launch.executionID, pid: 42, seconds: 1, microseconds: 0)
        return (launch.executionID, credential)
    }
    func call(_ envelope: ControllerBrokerRequest) throws -> ControllerAgentResponse {
        try ControllerAgentBrokerClient.perform(socket: broker.socketPath, envelope)
    }
}

struct AgentBrokerTests {
    @Test func servesExactlyTheCallersOwnExecution() async throws {
        let fixture = try await BrokerFixture()
        defer { fixture.remove() }
        let (first, firstCredential) = try await fixture.running(key: "one")
        let (second, secondCredential) = try await fixture.running(key: "two")
        let context = try fixture.call(.init(execution: first.description, credential: firstCredential, request: .context))
        #expect(context.work?.key == "one")
        #expect(throws: ControllerBrokerFailure(description: "forbidden")) {
            try fixture.call(.init(execution: first.description, credential: secondCredential, request: .context))
        }
        #expect(throws: ControllerBrokerFailure(description: "forbidden")) {
            try fixture.call(.init(execution: second.description, credential: firstCredential,
                                   request: .finish(payload: "not mine")))
        }
        #expect(throws: ControllerBrokerFailure(description: "forbidden")) {
            try fixture.call(.init(execution: first.description, mailbox: "x", credential: firstCredential, request: .context))
        }
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.broker.socketPath)[.posixPermissions] as? NSNumber
        #expect(mode?.uint16Value == UInt16(ControllerAgentBroker.socketPermissions))
    }

    @Test func aSessionMailboxGetsOnlyItsMailTools() async throws {
        let fixture = try await BrokerFixture()
        defer { fixture.remove() }
        let session = MailAddress(host: try await fixture.store.host().id, kind: .session, id: UUID())
        _ = try await fixture.store.registerMailbox(session, name: "Console")
        let credential = try await fixture.store.mailboxCredential(session)
        #expect(try fixture.call(.init(mailbox: session.description, credential: credential, request: .mailDirectory)).address == session)
        #expect(throws: ControllerBrokerFailure(description: "forbidden")) {
            try fixture.call(.init(mailbox: session.description, credential: credential, request: .context))
        }
        #expect(throws: ControllerBrokerFailure(description: "invalid_input: broker_request")) {
            try fixture.call(.init(mailbox: session.description, credential: credential, request: .mailDirectory,
                                   transcript: ProviderTranscript(sessionID: "s", path: "/tmp/x")))
        }
    }

    @Test func aSilentClientHoldsOneSlotNotTheBroker() async throws {
        let fixture = try await BrokerFixture()
        defer { fixture.remove() }
        let (id, credential) = try await fixture.running(key: "one")
        let silent = try ControllerUnixSocket.connect(path: fixture.broker.socketPath, timeout: 1)
        defer { ControllerUnixSocket.close(silent) }
        let started = Date()
        #expect(try fixture.call(.init(execution: id.description, credential: credential, request: .context)).work?.key == "one")
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func aRegularFileAtTheSocketPathIsNeverReplaced() throws {
        let path = "/tmp/cab-file-" + UUID().uuidString.prefix(8)
        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("cab-s-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        #expect(throws: ControllerError.invalidInput("agent_socket_path_occupied")) {
            _ = try ControllerAgentBroker(socketPath: path, store: store)
        }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
    }
}

