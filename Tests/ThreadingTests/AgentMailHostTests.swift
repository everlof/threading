import XCTest
import ThreadingController

@testable import Threading

// MARK: - Host-local mailboxes for remote-host sessions

@MainActor
final class RemoteSessionMailboxTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteSessionMailboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("host"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func endpoint() -> RemoteControllerEndpoint {
        RemoteControllerEndpoint(
            hostID: RemoteHostID(), name: "vps-1",
            destination: RemoteHostDestination(alias: "vps-1", configFile: nil),
            executable: "/opt/threading/threading-controller", database: "/var/lib/threading/controller.db"
        )
    }

    private func binding(_ endpoint: RemoteControllerEndpoint, session: SessionID) -> RemoteSessionMailboxes.Binding {
        .init(endpoint: endpoint, address: MailAddress(host: HostID(), kind: .session, id: session.rawValue), credential: "secret")
    }

    private func context(home: String) -> RemoteHostLaunchContext {
        RemoteHostLaunchContext(
            destination: RemoteHostDestination(alias: "pi", configFile: nil),
            facts: RemoteHostFacts(
                machine: "aarch64", home: home, user: "me", loginShell: "/bin/sh", hasSystemd: true,
                lingerEnabled: true, installedBinaries: [], activeInstances: [], claudePath: "/usr/bin/claude",
                curlPath: "/usr/bin/curl"
            ),
            localSocketPath: "/tmp/x.sock",
            toolRoute: RemoteHostToolRoute(
                socketPath: "\(home)/.local/state/threading/bridge/mcp.sock",
                bridgePath: "\(home)/.local/lib/threading/bridge/00/threading-mcp-bridge",
                cacheDirectory: "\(home)/.local/state/threading/bridge/catalogues"
            )
        )
    }

    func testAHostMailboxLaunchCarriesTheControllersToolsAndHooksAndNotTheMacs() throws {
        let session = AgentSession(kind: .claude, title: "Deploy")
        let binding = binding(endpoint(), session: session.id)
        let integration = RemoteAgentLaunch.Integration.make(
            for: session, context: context(home: "/home/me"), reportsLifecycle: true,
            allowedTools: ["list_sessions"], mailbox: binding
        )
        XCTAssertTrue(integration.environment.contains("THREADING_MAILBOX_ADDRESS=\(binding.address)"))
        XCTAssertTrue(integration.environment.contains("THREADING_MAILBOX_CREDENTIAL=secret"))
        XCTAssertTrue(integration.environment.contains("THREADING_CONTROLLER_DATABASE=/var/lib/threading/controller.db"))
        XCTAssertEqual(integration.flags.extraAllowedToolNames, MailboxEnvironment.allowedToolNames)

        let config = try XCTUnwrap(integration.payloads.first { $0.variable == RemoteAgentLaunchDefaults.mcpConfigVariable })
        let servers = try XCTUnwrap(config.object.value["mcpServers"] as? [String: Any])
        let mail = try XCTUnwrap(servers[MailboxEnvironment.serverName] as? [String: Any])
        XCTAssertEqual(mail["command"] as? String, "/opt/threading/threading-controller")
        XCTAssertEqual(mail["args"] as? [String], ["agent-mcp"])
        XCTAssertEqual((mail["env"] as? [String: String])?[MailboxEnvironment.credentialKey], "secret")
        XCTAssertNotNil(servers[MCPDefaults.serverName], "Threading's own bridge stays beside it")

        let settings = try XCTUnwrap(integration.payloads.first { $0.variable == RemoteAgentLaunchDefaults.settingsVariable })
        let hooks = try XCTUnwrap(settings.object.value["hooks"] as? [String: [[String: Any]]])
        for event in MailNoticeHook.events {
            let commands = (hooks[MailNoticeHook.hookName(for: event)] ?? [])
                .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
            XCTAssertTrue(commands.contains(MailNoticeHook.hostCommand(executable: "/opt/threading/threading-controller", event: event)))
            XCTAssertFalse(commands.contains { $0.contains(MCPDefaults.mailNoticePathPrefix) },
                           "the Mac must not also answer notices for a host mailbox")
        }
        // Owner-only files, never argv.
        XCTAssertTrue(integration.scriptLines.first?.contains("umask 077") == true)
        let commands = AgentLauncher.remoteClaudeCommands(for: session, prompt: nil, integration: integration.flags)
        XCTAssertTrue(commands.fresh.source.contains("mcp__threading-mail__mail_send"))
        XCTAssertFalse(commands.fresh.source.contains("secret"))
    }

    func testWithoutAHostMailboxTheLaunchIsUnchanged() {
        let session = AgentSession(kind: .claude, title: "Deploy")
        let integration = RemoteAgentLaunch.Integration.make(
            for: session, context: context(home: "/home/me"), reportsLifecycle: true, allowedTools: ["list_sessions"]
        )
        XCTAssertFalse(integration.environment.contains { $0.hasPrefix(MailboxEnvironment.addressKey) })
        XCTAssertTrue(integration.flags.extraAllowedToolNames.isEmpty)
    }

    func testAHostMailboxHidesTheMacsMailToolsForThatSessionOnly() {
        XCTAssertTrue(MCPRemoteSessionToolScope.isMailTool(named: "mail_send"))
        XCTAssertFalse(MCPRemoteSessionToolScope.isMailTool(named: "send_to_session"))
        let mailboxes = RemoteSessionMailboxes.shared
        let session = SessionID()
        defer { mailboxes.reset() }
        XCTAssertFalse(mailboxes.keepsMailOnHost(session))
        let binding = binding(endpoint(), session: session)
        mailboxes.install(binding, for: session)
        XCTAssertTrue(mailboxes.keepsMailOnHost(session))
        XCTAssertEqual(mailboxes.session(forAddress: binding.address), session)
    }

    func testProvisioningRegistersTheMailboxOnTheHostAndGrantsThisMac() async throws {
        let remote = try ControllerStore(path: directory.appendingPathComponent("host/controller.db").path)
        let remoteHost = try await remote.host()
        let mac = MacMailbox(databaseURL: directory.appendingPathComponent("mac/mailbox.db"))
        let macHost = try await mac.host()
        _ = try await remote.setMailPeer(host: macHost.id, expectedRevision: 0, name: "mac", transport: nil, push: false, pull: false)
        _ = try await mac.controllerStore().setMailPeer(host: remoteHost.id, expectedRevision: 0, name: "vps-1",
                                                       transport: nil, push: false, pull: false)

        let mailboxes = RemoteSessionMailboxes()
        mailboxes.runner = OwnerRPCFake(store: remote)
        mailboxes.mailbox = mac
        mailboxes.ensurePeered = { _ in remoteHost.id }
        let session = SessionID()
        let provisioned = await mailboxes.provision(session, name: "Deploy", endpoint: endpoint())
        let binding = try XCTUnwrap(provisioned)
        XCTAssertEqual(binding.address, MailAddress(host: remoteHost.id, kind: .session, id: session.rawValue))
        let credential = try await remote.mailboxCredential(binding.address)
        XCTAssertEqual(binding.credential, credential)
        let grants = try await remote.mailGrants(recipient: binding.address).items
        XCTAssertEqual(grants.map(\.sender), ["\(macHost.id)/*"])
        XCTAssertEqual(grants.first?.mode, .notify)

        // The Info panel reads it over owner-rpc; an unreachable host shows the last read, stale.
        _ = try await mac.send(from: SessionID(), senderName: "Fix the importer", to: binding.address, id: UUID(),
                               text: "hi", replyTo: nil, priority: .normal, ownerAdmitted: false)
        _ = try await remote.handleMailRPC(MailRPCRequest(push: MailPush(from: macHost.id,
            messages: try await mac.controllerStore().outboundBatch(for: remoteHost.id).envelopes)), peer: macHost.id)
        let freshRead = await mailboxes.read(session) { _ in nil }
        let fresh = try XCTUnwrap(freshRead)
        XCTAssertEqual(fresh.received.map(\.party), ["Fix the importer"])
        XCTAssertEqual(fresh.note, "Kept on vps-1.")
        (mailboxes.runner as! OwnerRPCFake).offline = true
        let staleRead = await mailboxes.read(session) { _ in nil }
        let stale = try XCTUnwrap(staleRead)
        XCTAssertEqual(stale.received.map(\.party), ["Fix the importer"])
        XCTAssertTrue(stale.note?.contains("can’t be reached") == true)
    }

    func testAnUnreachableHostKeepsTheMailboxOnThisMac() async {
        let mailboxes = RemoteSessionMailboxes()
        let fake = OwnerRPCFake(store: nil)
        fake.offline = true
        mailboxes.runner = fake
        mailboxes.mailbox = MacMailbox(databaseURL: directory.appendingPathComponent("mac/mailbox.db"))
        mailboxes.ensurePeered = { _ in throw RemoteControllerRPC.Failure.transport("down") }
        let binding = await mailboxes.provision(SessionID(), name: "Deploy", endpoint: endpoint())
        XCTAssertNil(binding)
    }
}

/// Runs `owner-rpc` against a store in-process, or fails like an unreachable host.
final class OwnerRPCFake: RemoteHostCommandRunning, @unchecked Sendable {
    let store: ControllerStore?
    var offline = false

    init(store: ControllerStore?) { self.store = store }

    func run(on destination: RemoteHostDestination, command: String, input: RemoteHostCommandInput,
             extraOptions: [String], timeout: TimeInterval) throws -> RemoteHostCommandResult {
        guard !offline, let store, command.hasSuffix(" owner-rpc"), case .data(let bytes) = input else {
            return .init(output: "ssh: connect to host vps-1: Connection refused", termination: .exited(255))
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        Task.detached {
            box.value = try? await Self.answer(store, bytes)
            semaphore.signal()
        }
        semaphore.wait()
        guard let output = box.value else { return .init(output: "refused", termination: .exited(1)) }
        return .init(output: output, termination: .exited(0))
    }

    private static func answer(_ store: ControllerStore, _ bytes: Data) async throws -> String {
        let request = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let args = (request["arguments"] as! [[String: Any]]).map { ($0["value"] as? String) ?? ($0["text"] as? String) ?? "" }
        func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) + "\n" }
        switch request["command"] as! String {
        case "host": return try encode(try await store.host())
        case "mail-register": return try encode(try await store.registerMailbox(MailAddress(args[0]), name: args[1]))
        case "mail-credential": return try encode(try await store.mailboxCredential(MailAddress(args[0])))
        case "mail-grants": return try encode(try await store.mailGrants(recipient: MailAddress(args[0])))
        case "mail-grant-set":
            return try encode(try await store.setMailGrant(
                recipient: MailAddress(args[0]), sender: args[1], expectedRevision: Int(args[2])!,
                mode: args[3] == "none" ? nil : MailMode(rawValue: args[3]), allowsInterrupt: args[4] == "interrupt"))
        case "mailbox": return try encode(try await store.inbox(MailAddress(args[0])))
        case "mail-sent": return try encode(try await store.recentSentMail(MailAddress(args[0])))
        case "mail-contact-set": return try encode(try await store.setMailContact(MailAddress(args[0]), name: args[1]))
        default: throw ControllerError.forbidden
        }
    }

    private final class Box: @unchecked Sendable { var value: String? }
}

// MARK: - Grants and contacts

@MainActor
final class MailAccessTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailAccessTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSenderPatternsAreValidatedLikeTheController() {
        let host = HostID()
        XCTAssertEqual(MailAccessService.validSender("*"), "*")
        XCTAssertEqual(MailAccessService.validSender(" \(host)/* "), "\(host)/*")
        let address = MailAddress(host: host, kind: .worker, id: UUID())
        XCTAssertEqual(MailAccessService.validSender(address.description), address.description)
        XCTAssertNil(MailAccessService.validSender("deploy-bot"))
        XCTAssertNil(MailAccessService.validSender("nothost/*"))
        XCTAssertEqual(MailAccessService.offeredModes, [.notify, .wake])
    }

    func testAGrantAdmitsARemoteSenderAndARevocationRefusesTheNextOne() async throws {
        let service = MailAccessService()
        let mac = MacMailbox(databaseURL: directory.appendingPathComponent("mailbox.db"))
        service.mailbox = mac
        service.mailboxes = RemoteSessionMailboxes()
        let session = SessionID()
        let remote = HostID()
        let store = try await mac.controllerStore()
        _ = try await store.setMailPeer(host: remote, expectedRevision: 0, name: "vps-1", transport: nil, push: false, pull: false)
        let sender = MailAddress(host: remote, kind: .worker, id: UUID())
        let recipient = try await mac.register(session, name: "Deploy")
        func envelope() -> MailEnvelope {
            try! JSONDecoder().decode(MailEnvelope.self, from: JSONSerialization.data(withJSONObject: [
                "id": UUID().uuidString, "sender": sender.description, "senderName": "bot",
                "recipient": recipient.description, "text": "hi", "priority": "normal",
                "chainID": UUID().uuidString, "depth": 0, "sentAt": "2026-10-03T10:00:00Z"
            ]))
        }

        do {
            try await service.setGrant(sessionID: session, name: "Deploy", sender: "bogus", mode: .notify)
            XCTFail("an invalid sender was granted")
        } catch let failure as MailAccessService.Failure { XCTAssertEqual(failure, .invalidSender) }

        try await service.setGrant(sessionID: session, name: "Deploy", sender: "\(remote)/*", mode: .wake)
        let grants = try await service.grants(for: session, name: "Deploy")
        XCTAssertEqual(grants.map(\.mode), [.wake])
        try await store.acceptPulled([envelope()], from: remote, next: 1)
        let open = try await mac.inbox(for: session, name: "Deploy", after: 0, limit: 5)
        XCTAssertEqual(open.items.count, 1)
        let candidate = await mac.wakeCandidate(for: session)
        XCTAssertNotNil(candidate, "mail admitted under a wake grant may start the session")

        try await service.setGrant(sessionID: session, name: "Deploy", sender: "\(remote)/*", mode: nil)
        try await store.acceptPulled([envelope()], from: remote, next: 2)
        let after = try await mac.inbox(for: session, name: "Deploy", after: 0, limit: 5)
        XCTAssertEqual(after.items.count, 1, "the revoked grant refuses the next message")

        try await service.addContact(for: session, address: sender.description, name: "Deploy bot")
        let contacts = try await mac.contacts()
        XCTAssertEqual(contacts.map(\.name), ["Deploy bot"])
    }

    func testNotifyAloneNeverWakes() async throws {
        let mac = MacMailbox(databaseURL: directory.appendingPathComponent("mailbox.db"))
        let session = SessionID()
        let to = try await mac.register(session, name: "Deploy")
        _ = try await mac.send(from: SessionID(), senderName: "sibling", to: to, id: UUID(), text: "hi",
                               replyTo: nil, priority: .normal, ownerAdmitted: true)
        let candidate = await mac.wakeCandidate(for: session)
        XCTAssertNil(candidate, "same-project mail is notify: it never starts a session")
        XCTAssertTrue(MacMailDelivery.canWake(usesNativeUI: true, kind: .claude))
        XCTAssertFalse(MacMailDelivery.canWake(usesNativeUI: false, kind: .claude), "a terminal is never typed into")
    }

    func testTheGrantFormOffersNotifyAndWake() {
        let fields = SessionMailAccessForm.grantFields()
        XCTAssertEqual(fields.mode.item(at: 0)?.title, SessionMailPresentation.words(for: .notify))
        XCTAssertEqual(fields.mode.item(at: 1)?.title, SessionMailPresentation.words(for: .wake))
        XCTAssertNil(fields.mode.item(at: 2))
    }
}
