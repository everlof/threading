import XCTest
import ThreadingController

@testable import Threading

@MainActor
final class MailIdleWakeTests: XCTestCase {
    private final class Connection {}

    func testInstalledHookCommandReceivesMailOverTheActualListenerAndExitsTwo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mw-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = MacMailbox(databaseURL: directory.appendingPathComponent("mail.db"))
        let recipient = SessionID()
        let address = try await mailbox.register(recipient, name: "BETA")
        let connected = expectation(description: "background hook connected")
        connected.assertForOverFulfill = false
        let wake = MailIdleWake(mailbox: mailbox, eligible: { _ in connected.fulfill(); return true })
        let server = MCPServer(socketPath: directory.appendingPathComponent("mcp.sock").path)
        server.mailIdleWakeProvider = { wake }
        let ready = expectation(description: "listener ready")
        server.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        defer { server.stop(); MCPSessionRegistry.remove(sessionID: recipient) }
        let token = MCPSessionRegistry.token(for: recipient)
        let socket = try XCTUnwrap(server.socketPath)
        let command = MailIdleWakeHook.command()
        XCTAssertFalse(command.contains(token))
        let exited = expectation(description: "hook wakes Claude with exit 2")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin", "THREADING_MCP_SOCKET": socket,
                               "THREADING_SESSION_TOKEN": token]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        await fulfillment(of: [connected], timeout: 5)
        _ = try await mailbox.send(from: SessionID(), senderName: "VERIFICATION", to: address, id: UUID(),
                                   text: "PRIVATE_BODY", replyTo: nil, priority: .normal, ownerAdmitted: true)
        wake.arrived(for: recipient)
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(process.terminationStatus, 2)
        let notice = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(notice.contains("VERIFICATION"))
        XCTAssertFalse(notice.contains("PRIVATE_BODY"))
    }

    func testArrivalWakesOnceWithoutUserActivityAndNeverCarriesPeerText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("idle-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = MacMailbox(databaseURL: directory.appendingPathComponent("mail.db"))
        let wake = MailIdleWake(mailbox: mailbox, eligible: { _ in true })
        let recipient = SessionID(), connection = Connection()
        let address = try await mailbox.register(recipient, name: "BETA")
        let received = expectation(description: "idle background hook receives notice")
        received.assertForOverFulfill = true
        wake.watch(recipient, connection: ObjectIdentifier(connection)) { response in
            XCTAssertEqual(response.status, 200)
            let notice = String(decoding: response.body, as: UTF8.self)
            XCTAssertTrue(notice.contains("VERIFICATION"))
            XCTAssertFalse(notice.contains("UNTRUSTED_PEER_BODY"))
            received.fulfill()
        }
        let id = UUID()
        _ = try await mailbox.send(from: SessionID(), senderName: "VERIFICATION", to: address,
                                   id: id, text: "UNTRUSTED_PEER_BODY", replyTo: nil,
                                   priority: .normal, ownerAdmitted: true)
        for _ in 0..<10_000 { wake.arrived(for: recipient) }
        await fulfillment(of: [received], timeout: 3)
        let inbox = try await mailbox.inbox(for: recipient, name: "BETA", after: 0, limit: 10)
        XCTAssertEqual(inbox.items.map(\.message.envelope.id), [id], "wake is not acknowledgment")
        let anotherNotice = await mailbox.notice(for: recipient, event: .postToolUse)
        XCTAssertNil(anotherNotice)
    }

    func testRenewalRetiresTheOldHookAndItsDisconnectDoesNotRemoveTheNewOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("idle-renew-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = MacMailbox(databaseURL: directory.appendingPathComponent("mail.db"))
        let wake = MailIdleWake(mailbox: mailbox, eligible: { _ in true })
        let recipient = SessionID(), old = Connection(), new = Connection()
        let retired = expectation(description: "old hook exits silently")
        let received = expectation(description: "new hook receives mail")
        wake.watch(recipient, connection: ObjectIdentifier(old)) { response in
            XCTAssertEqual(response.status, 204)
            XCTAssertTrue(response.body.isEmpty)
            retired.fulfill()
        }
        wake.watch(recipient, connection: ObjectIdentifier(new)) { response in
            XCTAssertEqual(response.status, 200)
            received.fulfill()
        }
        wake.disconnected(ObjectIdentifier(old))
        let address = try await mailbox.register(recipient, name: "BETA")
        _ = try await mailbox.send(from: SessionID(), senderName: "Peer", to: address, id: UUID(),
                                   text: "Waiting", replyTo: nil, priority: .normal, ownerAdmitted: true)
        wake.arrived(for: recipient)
        await fulfillment(of: [retired, received], timeout: 3)
    }

    func testSessionStartAnnouncementDoesNotSpendIdleWakeAndRearmingDoesNotLoop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("idle-start-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = MacMailbox(databaseURL: directory.appendingPathComponent("mail.db"))
        let recipient = SessionID(), first = Connection(), second = Connection()
        let address = try await mailbox.register(recipient, name: "BETA")
        _ = try await mailbox.send(from: SessionID(), senderName: "Peer", to: address, id: UUID(),
                                   text: "Already announced", replyTo: nil, priority: .normal, ownerAdmitted: true)
        let startNotice = await mailbox.notice(for: recipient, event: .sessionStart)
        XCTAssertNotNil(startNotice)
        let wake = MailIdleWake(mailbox: mailbox, eligible: { _ in true })
        let received = expectation(description: "already announced mail wakes the idle agent")
        wake.watch(recipient, connection: ObjectIdentifier(first)) { response in
            XCTAssertEqual(response.status, 200)
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 3)
        let looped = expectation(description: "unacked mail must not trigger another wake")
        looped.isInverted = true
        wake.watch(recipient, connection: ObjectIdentifier(second)) { _ in looped.fulfill() }
        for _ in 0..<100 { wake.arrived(for: recipient) }
        await fulfillment(of: [looped], timeout: 0.1)
        wake.disconnected(ObjectIdentifier(second))
    }

    func testDisconnectedOrIneligibleSessionsDoNotConsumeMail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("idle-gone-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = MacMailbox(databaseURL: directory.appendingPathComponent("mail.db"))
        let wake = MailIdleWake(mailbox: mailbox, eligible: { _ in true })
        let recipient = SessionID(), connection = Connection()
        wake.watch(recipient, connection: ObjectIdentifier(connection)) { _ in XCTFail("disconnected") }
        wake.disconnected(ObjectIdentifier(connection))
        // Allow the initial empty query to finish before storing the mail.
        for _ in 0..<20 { await Task.yield() }
        let address = try await mailbox.register(recipient, name: "BETA")
        _ = try await mailbox.send(from: SessionID(), senderName: "Peer", to: address, id: UUID(),
                                   text: "Waiting", replyTo: nil, priority: .normal, ownerAdmitted: true)
        wake.arrived(for: recipient)
        let refused = MailIdleWake(mailbox: mailbox, eligible: { _ in false })
        refused.watch(recipient, connection: ObjectIdentifier(connection)) { response in
            XCTAssertEqual(response.status, 204)
        }
        let unannounced = await mailbox.hasUnannouncedMail(for: recipient)
        XCTAssertTrue(unannounced)
    }

    func testOnlyLocalClaudeLaunchesOptIntoBackgroundWakeHooks() throws {
        XCTAssertTrue(AgentKind.claude.supports(.rewakingMailHooks))
        for kind in [AgentKind.codex, .grok, .openCode, .cursor] {
            XCTAssertFalse(kind.supports(.rewakingMailHooks))
        }
        let session = SessionID()
        defer { MCPSessionRegistry.remove(sessionID: session) }
        let settings = try XCTUnwrap(MCPSessionRegistry.hookSettings(
            for: session, brokersPermissions: false, reportsLifecycle: true,
            mailNotices: true, idleMailWake: true))
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: [[String: Any]]])
        for event in MailIdleWakeHook.events {
            let entries = (hooks[event] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            XCTAssertEqual(entries.filter { $0["asyncRewake"] as? Bool == true }.count, 1)
        }
        let ordinary = try XCTUnwrap(MCPSessionRegistry.hookSettings(
            for: session, brokersPermissions: false, reportsLifecycle: true, mailNotices: true))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ordinary), as: UTF8.self)
        XCTAssertFalse(text.contains("asyncRewake"), "native and remote launches retain their own delivery")
    }

    func testWatcherCapacityIsBoundedAndDisconnectReleasesIt() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("idle-cap-\(UUID())")
        let mailbox = MacMailbox(databaseURL: directory.appendingPathComponent("mail.db"))
        let wake = MailIdleWake(mailbox: mailbox, eligible: { _ in true })
        let connections = (0..<MailIdleWake.maximumWatchers).map { _ in Connection() }
        for connection in connections {
            wake.watch(SessionID(), connection: ObjectIdentifier(connection)) { _ in XCTFail("no mail") }
        }
        let overflow = Connection()
        wake.watch(SessionID(), connection: ObjectIdentifier(overflow)) { response in
            XCTAssertEqual(response.status, 204)
        }
        wake.disconnected(ObjectIdentifier(connections[0]))
        wake.watch(SessionID(), connection: ObjectIdentifier(overflow)) { _ in XCTFail("capacity was released") }
        for connection in connections + [overflow] { wake.disconnected(ObjectIdentifier(connection)) }
    }
}
