import XCTest
import ThreadingController

@testable import Threading

// MARK: - Host-local mailboxes for remote-host sessions

@MainActor
final class RemoteSessionMailboxTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteSessionMailboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("host"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
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
            // The Mac's own answering entry is absent; the host's entry only *reports* to the
            // Mac (`observed=`), which the Mac answers with silence.
            XCTAssertFalse(commands.contains { $0.contains(MCPDefaults.mailNoticePathPrefix) && !$0.contains(MCPDefaults.mailNoticeObservedParameter) },
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

        // Reprovisioning must preserve an owner's explicit revocation.
        _ = try await remote.setMailGrant(recipient: binding.address, sender: "\(macHost.id)/*",
            expectedRevision: 1, mode: nil, allowsInterrupt: false)
        mailboxes.reset()
        _ = await mailboxes.provision(session, name: "Deploy", endpoint: endpoint())
        let revoked = try await remote.mailGrants(recipient: binding.address).items
        XCTAssertNil(revoked.first?.mode)
        XCTAssertEqual(revoked.first?.revision, 2)
        _ = try await remote.setMailGrant(recipient: binding.address, sender: "\(macHost.id)/*",
            expectedRevision: 2, mode: .notify, allowsInterrupt: false)

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
/// Routes owner RPCs to one fake host per SSH alias.
final class RoutingOwnerRPCFake: RemoteHostCommandRunning, @unchecked Sendable {
    let hosts: [String: OwnerRPCFake]
    init(_ hosts: [String: OwnerRPCFake]) { self.hosts = hosts }
    func run(on destination: RemoteHostDestination, command: String, input: RemoteHostCommandInput,
             extraOptions: [String], timeout: TimeInterval) throws -> RemoteHostCommandResult {
        guard let host = hosts[destination.alias] else { return .init(output: "unknown host", termination: .exited(255)) }
        return try host.run(on: destination, command: command, input: input, extraOptions: extraOptions, timeout: timeout)
    }
}

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
                mode: args[3] == "none" ? nil : MailMode(rawValue: args[3]), allowsInterrupt: args[4] == "interrupt",
                chainTokenBudget: args.count > 5 ? Int64(args[5]) : nil))
        case "mail-send":
            return try encode(try await store.sendMail(
                from: MailAddress(args[0]), to: MailAddress(args[1]), id: UUID(uuidString: args[2])!, text: args[3],
                replyTo: nil, priority: MailPriority(rawValue: args[4]) ?? .normal, ownerAdmitted: args.count > 5))
        case "mailbox": return try encode(try await store.inbox(MailAddress(args[0])))
        case "mail-sent": return try encode(try await store.recentSentMail(MailAddress(args[0])))
        case "mail-contact-set": return try encode(try await store.setMailContact(MailAddress(args[0]), name: args[1]))
        case "mail-forward": return try encode(try await store.mailForward(MailAddress(args[0])))
        case "mail-forward-revision": return try encode(try await store.mailForwardRevision(MailAddress(args[0])))
        case "mail-forward-set":
            return try encode(try await store.setMailForward(from: MailAddress(args[0]), to: MailAddress(args[1]), expectedRevision: Int(args[2])!))
        case "mail-forward-clear":
            try await store.clearMailForward(MailAddress(args[0]), expectedRevision: Int(args[1])!)
            return try encode(try await store.mailForwardRevision(MailAddress(args[0])))
        case "mail-move": return try encode(try await store.moveMail(from: MailAddress(args[0]), to: MailAddress(args[1])))
        default: throw ControllerError.forbidden
        }
    }

    private final class Box: @unchecked Sendable { var value: String? }
}

// MARK: - Grants and contacts

@MainActor
final class MailAccessTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailAccessTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
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

// MARK: - Moving a session's mailbox

@MainActor
final class MailboxHandoverTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailboxHandoverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("host"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMovingToAHostAndBackCarriesUnreadMailAndGrants() async throws {
        let remote = try ControllerStore(path: directory.appendingPathComponent("host/controller.db").path)
        let remoteHost = try await remote.host()
        let mac = MacMailbox(databaseURL: directory.appendingPathComponent("mac/mailbox.db"))
        let macHost = try await mac.host()
        let macStore = try await mac.controllerStore()
        _ = try await remote.setMailPeer(host: macHost.id, expectedRevision: 0, name: "mac", transport: nil, push: false, pull: false)
        _ = try await macStore.setMailPeer(host: remoteHost.id, expectedRevision: 0, name: "vps-1", transport: nil, push: false, pull: false)

        let fake = OwnerRPCFake(store: remote)
        let mailboxes = RemoteSessionMailboxes()
        mailboxes.runner = fake
        mailboxes.mailbox = mac
        mailboxes.ensurePeered = { _ in remoteHost.id }
        let handover = MailboxHandover()
        handover.mailbox = mac
        handover.mailboxes = mailboxes
        handover.ensurePeered = { _ in remoteHost.id }
        handover.kick = { _ in }
        let endpoint = RemoteControllerEndpoint(
            hostID: RemoteHostID(), name: "vps-1", destination: RemoteHostDestination(alias: "vps-1", configFile: nil),
            executable: "/opt/threading/threading-controller", database: "/var/lib/threading/controller.db"
        )

        let session = SessionID()
        let onMac = try await mac.register(session, name: "Deploy")
        let worker = MailAddress(host: remoteHost.id, kind: .worker, id: UUID())
        try await mac.ensureGrant(recipient: onMac, sender: worker.description, mode: .wake)
        let unread = UUID()
        _ = try await mac.send(from: SessionID(), senderName: "Review", to: onMac, id: unread, text: "unread",
                               replyTo: nil, priority: .normal, ownerAdmitted: true)

        // This Mac -> the host.
        let there = await handover.move(session, title: "Deploy", from: .thisMac, to: .host(endpoint))
        XCTAssertEqual(there.issues, [])
        XCTAssertEqual(there.moved, 1)
        XCTAssertEqual(there.grantsCopied, 1)
        let onHost = MailAddress(host: remoteHost.id, kind: .session, id: session.rawValue)
        XCTAssertEqual(mailboxes.binding(for: session)?.address, onHost)
        let pushed = try await macStore.outboundBatch(for: remoteHost.id).envelopes
        _ = try await remote.handleMailRPC(MailRPCRequest(push: MailPush(from: macHost.id, messages: pushed)), peer: macHost.id)
        let hostInbox = try await remote.inbox(onHost).items.map(\.message.envelope.id)
        XCTAssertEqual(hostInbox, [unread], "same id, now on the host")
        let hostGrants = try await remote.mailGrants(recipient: onHost).items.map(\.sender)
        XCTAssertTrue(hostGrants.contains(worker.description), "the grant followed the session")

        // The host -> this Mac: forwarded back, accepted because the Mac wrote the forward.
        let back = await handover.move(session, title: "Deploy", from: .host(endpoint), to: .thisMac)
        XCTAssertEqual(back.issues, [])
        XCTAssertEqual(back.moved, 1)
        XCTAssertNil(mailboxes.binding(for: session))
        let held = try await remote.outboundBatch(for: macHost.id)
        try await macStore.acceptPulled(held.envelopes, from: remoteHost.id, next: held.next)
        let macInbox = try await mac.inbox(for: session, name: "Deploy", after: 0, limit: 5).items.map(\.message.envelope.id)
        XCTAssertEqual(macInbox, [unread])
    }

    func testAnUnreachableNewHostMovesNothing() async {
        let handover = MailboxHandover()
        let mailboxes = RemoteSessionMailboxes()
        let fake = OwnerRPCFake(store: nil)
        fake.offline = true
        mailboxes.runner = fake
        mailboxes.ensurePeered = { _ in throw RemoteControllerRPC.Failure.transport("down") }
        mailboxes.mailbox = MacMailbox(databaseURL: directory.appendingPathComponent("mac/mailbox.db"))
        handover.mailbox = mailboxes.mailbox
        handover.mailboxes = mailboxes
        handover.kick = { _ in }
        let endpoint = RemoteControllerEndpoint(
            hostID: RemoteHostID(), name: "vps-1", destination: RemoteHostDestination(alias: "vps-1", configFile: nil),
            executable: "/opt/threading/threading-controller", database: "/var/lib/threading/controller.db"
        )
        let outcome = await handover.move(SessionID(), title: "Deploy", from: .thisMac, to: .host(endpoint))
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertFalse(outcome.issues.isEmpty)
    }

    // MARK: Review fixes

    private func hostEndpoint(_ name: String = "vps-1") -> RemoteControllerEndpoint {
        RemoteControllerEndpoint(
            hostID: RemoteHostID(), name: name, destination: RemoteHostDestination(alias: name, configFile: nil),
            executable: "/opt/threading/threading-controller", database: "/var/lib/threading/controller.db"
        )
    }

    /// A Mac, one reachable host, and a handover wired to them.
    private func world() async throws -> (mac: MacMailbox, macStore: ControllerStore, remote: ControllerStore, remoteHost: HostID,
                                          mailboxes: RemoteSessionMailboxes, handover: MailboxHandover, endpoint: RemoteControllerEndpoint) {
        let remote = try ControllerStore(path: directory.appendingPathComponent("host/controller.db").path)
        let remoteHost = try await remote.host().id
        let mac = MacMailbox(databaseURL: directory.appendingPathComponent("mac/mailbox.db"))
        let macHost = try await mac.host().id
        let macStore = try await mac.controllerStore()
        _ = try await remote.setMailPeer(host: macHost, expectedRevision: 0, name: "mac", transport: nil, push: false, pull: false)
        _ = try await macStore.setMailPeer(host: remoteHost, expectedRevision: 0, name: "vps-1", transport: nil, push: false, pull: false)
        let mailboxes = RemoteSessionMailboxes()
        mailboxes.runner = OwnerRPCFake(store: remote)
        mailboxes.mailbox = mac
        mailboxes.ensurePeered = { _ in remoteHost }
        let handover = MailboxHandover()
        handover.mailbox = mac
        handover.mailboxes = mailboxes
        handover.ensurePeered = { _ in remoteHost }
        handover.kick = { _ in }
        return (mac, macStore, remote, remoteHost, mailboxes, handover, hostEndpoint())
    }

    func testReapplyingAModeKeepsAGrantsBudget() async throws {
        let w = try await world()
        let session = SessionID()
        let address = try await w.mac.register(session, name: "Deploy")
        let worker = MailAddress(host: w.remoteHost, kind: .worker, id: UUID())
        try await w.mac.ensureGrant(recipient: address, sender: worker.description, mode: .wake, chainTokenBudget: .set(50_000))
        let again = try await w.mac.ensureGrant(recipient: address, sender: worker.description, mode: .wake)
        XCTAssertEqual(again.chainTokenBudget, 50_000, "a caller that does not deal in budgets never removes the fuse")
    }

    /// The session lived on h1, which was down when its project moved to this Mac and then on to
    /// h2. When h1 answers again, its unread mail goes to h2 — where the session lives now — and
    /// the retry is cleared; it is neither dropped by the later move nor sent to this Mac.
    func testAnOldHostsMailFollowsTheSessionToWhereItLivesNowWhenTheHostReturns() async throws {
        let w = try await world()
        let h1 = try ControllerStore(path: directory.appendingPathComponent("h1.db").path)
        let h1Host = try await h1.host().id
        let macHost = try await w.mac.host().id
        _ = try await h1.setMailPeer(host: macHost, expectedRevision: 0, name: "mac", transport: nil, push: false, pull: false)
        _ = try await h1.setMailPeer(host: w.remoteHost, expectedRevision: 0, name: "h2", transport: ["/usr/bin/ssh", "h2"], push: true, pull: false)
        _ = try await w.remote.setMailPeer(host: h1Host, expectedRevision: 0, name: "h1", transport: nil, push: false, pull: false)
        let session = SessionID()
        let onH1 = MailAddress(host: h1Host, kind: .session, id: session.rawValue)
        _ = try await h1.registerMailbox(onH1, name: "Deploy")
        _ = try await h1.setMailGrant(recipient: onH1, sender: "*", expectedRevision: 0, mode: .notify, allowsInterrupt: false)
        let sibling = MailAddress(host: h1Host, kind: .session, id: UUID())
        _ = try await h1.registerMailbox(sibling, name: "Sibling")
        let unread = try await h1.sendMail(from: sibling, to: onH1, id: UUID(), text: "unread on h1", replyTo: nil, priority: .normal)

        let h1Endpoint = hostEndpoint("h1")
        @MainActor final class Reachability {
            var isUp = false
        }
        let reachability = Reachability()
        let routing = RoutingOwnerRPCFake(["vps-1": OwnerRPCFake(store: w.remote), "h1": OwnerRPCFake(store: h1)])
        w.mailboxes.runner = routing
        w.handover.runner = routing
        w.handover.ensurePeered = { endpoint in
            if endpoint.name == "h1" { guard reachability.isUp else { throw RemoteControllerRPC.Failure.transport("down") }; return h1Host }
            return w.remoteHost
        }
        _ = await w.handover.move(session, title: "Deploy", from: .host(h1Endpoint), to: .thisMac)
        _ = await w.handover.move(session, title: "Deploy", from: .thisMac, to: .host(w.endpoint))
        XCTAssertNotNil(w.handover.pending[session]?[h1Endpoint.hostID], "a later move does not drop the old host's mail")

        reachability.isUp = true
        w.handover.currentSide = { _ in .host(w.endpoint) }
        for task in w.handover.retryPending(reachable: h1Endpoint) { _ = await task.value }
        XCTAssertNil(w.handover.pending[session], "moved, so no longer pending")
        let held = try await h1.outboundBatch(for: w.remoteHost).envelopes.map(\.id)
        XCTAssertEqual(held, [unread.envelope.id], "queued for h2, where the session lives now")
    }

    func testAnOldPartThatKeepsFailingIsGivenUpAfterItsRetries() async throws {
        let w = try await world()
        let session = SessionID()
        let down = hostEndpoint("down")
        w.handover.ensurePeered = { endpoint in
            if endpoint.name == "down" { throw RemoteControllerRPC.Failure.transport("down") }
            return w.remoteHost
        }
        w.handover.currentSide = { _ in .thisMac }
        _ = await w.handover.move(session, title: "Deploy", from: .host(down), to: .thisMac)
        for _ in 0..<MailboxHandoverDefaults.retryAttempts {
            XCTAssertNotNil(w.handover.pending[session]?[down.hostID])
            for task in w.handover.retryPending(reachable: down) { _ = await task.value }
        }
        XCTAssertNil(w.handover.pending[session], "bounded: given up rather than retried on every sync")
    }

    func testTheFallbackNeverOverridesAGrantTheOwnerSet() async throws {
        let w = try await world()
        let caller = SessionID(), target = SessionID()
        let provisioned = await w.mailboxes.provision(caller, name: "Caller", endpoint: w.endpoint)
        let binding = try XCTUnwrap(provisioned)
        let targetAddress = try await w.mac.register(target, name: "Target")
        // The owner revoked this caller on the target.
        try await w.mac.ensureGrant(recipient: targetAddress, sender: binding.address.description, mode: .wake)
        try await w.mac.ensureGrant(recipient: targetAddress, sender: binding.address.description, mode: nil)
        let delivery = MacMailDelivery(mailbox: w.mac)
        delivery.mailboxes = w.mailboxes
        let answered = expectation(description: "answered")
        delivery.storeUndeliverable("hello", to: target, from: caller) { ok in
            XCTAssertFalse(ok, "a revoked sender is refused, not silently re-granted"); answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        let grant = try await w.macStore.mailGrants(recipient: targetAddress).items.first { $0.sender == binding.address.description }
        XCTAssertNil(grant?.mode, "the revocation stands")
    }

    func testAMovedGrantKeepsItsChainBudget() async throws {
        let w = try await world()
        let session = SessionID()
        let onMac = try await w.mac.register(session, name: "Deploy")
        let worker = MailAddress(host: w.remoteHost, kind: .worker, id: UUID())
        try await w.mac.ensureGrant(recipient: onMac, sender: worker.description, mode: .wake, chainTokenBudget: .set(200_000))
        let outcome = await w.handover.move(session, title: "Deploy", from: .thisMac, to: .host(w.endpoint))
        XCTAssertEqual(outcome.issues, [])
        let onHost = MailAddress(host: w.remoteHost, kind: .session, id: session.rawValue)
        let copied = try await w.remote.mailGrants(recipient: onHost).items.first { $0.sender == worker.description }
        XCTAssertEqual(copied?.chainTokenBudget, 200_000, "the spend fuse moves with the grant")
    }

    func testAnUnreachableOldHostDoesNotHoldBackThisMacsMailAndIsRetried() async throws {
        let w = try await world()
        let session = SessionID()
        // Mail waiting on this Mac (left here when the old host could not be reached at launch).
        let onMac = try await w.mac.register(session, name: "Deploy")
        _ = try await w.mac.send(from: SessionID(), senderName: "Review", to: onMac, id: UUID(), text: "unread",
                                 replyTo: nil, priority: .normal, ownerAdmitted: true)
        let down = hostEndpoint("down")
        w.handover.ensurePeered = { endpoint in
            if endpoint.name == "down" { throw RemoteControllerRPC.Failure.transport("down") }
            return w.remoteHost
        }
        let outcome = await w.handover.move(session, title: "Deploy", from: .host(down), to: .host(w.endpoint))
        XCTAssertEqual(outcome.moved, 1, "this Mac's mail moved although the old host was down")
        XCTAssertFalse(outcome.issues.isEmpty)
        XCTAssertNotNil(w.handover.pending[session], "the old host's part is retried when it answers")
    }

    func testAMacAddressThatNeverHeldAMailboxGetsNoForward() async throws {
        let w = try await world()
        let session = SessionID()
        let macHost = try await w.mac.host().id
        let macAddress = MailAddress(host: macHost, kind: .session, id: session.rawValue)
        let outcome = await w.handover.move(session, title: "Deploy", from: .thisMac, to: .host(w.endpoint))
        XCTAssertEqual(outcome.issues, [])
        let forward = try await w.macStore.mailForward(macAddress)
        XCTAssertNil(forward, "nothing to forward from an address that never existed here")
    }

    func testAMoveAskedForDuringAnotherRunsAfterIt() async throws {
        let w = try await world()
        let session = SessionID()
        _ = try await w.mac.register(session, name: "Deploy")
        let entered = expectation(description: "first move reached provisioning")
        let gate = ProvisionGate(entered: entered)
        defer { gate.release() }
        w.mailboxes.ensurePeered = { _ in
            await gate.wait()
            return w.remoteHost
        }
        let first = Task {
            await w.handover.move(session, title: "Deploy", from: .thisMac, to: .host(w.endpoint))
        }
        // Sibling async-let tasks have no admission order. Hold the first move in provisioning
        // before asking for the return move, so this exercises the queue rather than scheduling.
        await fulfillment(of: [entered], timeout: 5)
        _ = await w.handover.move(session, title: "Deploy", from: .host(w.endpoint), to: .thisMac)
        gate.release()
        _ = await first.value
        XCTAssertNil(w.mailboxes.binding(for: session), "the later move ran: the mailbox is back on this Mac")
    }

    @MainActor
    private final class ProvisionGate {
        private let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false

        init(entered: XCTestExpectation) { self.entered = entered }

        func wait() async {
            entered.fulfill()
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testConcurrentProvisioningBothGetTheHostMailbox() async throws {
        let w = try await world()
        let session = SessionID()
        async let a = w.mailboxes.provision(session, name: "Deploy", endpoint: w.endpoint)
        async let b = w.mailboxes.provision(session, name: "Deploy", endpoint: w.endpoint)
        let (first, second) = await (a, b)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "the second caller waits for the first instead of falling back to this Mac")
    }

    func testFallbackMailFromAHostMailboxIsSentFromTheHost() async throws {
        let w = try await world()
        let caller = SessionID(), target = SessionID()
        let provisioned = await w.mailboxes.provision(caller, name: "Caller", endpoint: w.endpoint)
        let binding = try XCTUnwrap(provisioned)
        let delivery = MacMailDelivery(mailbox: w.mac)
        delivery.mailboxes = w.mailboxes
        let stored = expectation(description: "stored")
        delivery.storeUndeliverable("busy? read this", to: target, from: caller) { ok in
            XCTAssertTrue(ok); stored.fulfill()
        }
        await fulfillment(of: [stored], timeout: 10)
        let sent = try await w.remote.recentSentMail(binding.address)
        XCTAssertEqual(sent.map(\.envelope.text), ["busy? read this"], "sent as the mailbox the caller reads")
        let macHost = try await w.mac.host().id
        XCTAssertEqual(sent.first?.envelope.recipient.host, macHost)
        // A target created after the caller launched has no sibling grant yet; the fallback wrote
        // one, so this Mac accepts the mail when it pulls it.
        let page = try await w.remote.handleMailRPC(MailRPCRequest(pull: MailPull(after: 0, refused: nil)), peer: macHost)
        try await w.macStore.acceptPulled(page.messages ?? [], from: w.remoteHost, next: page.next ?? 0)
        let peer = try await w.macStore.mailPeer(w.remoteHost)
        XCTAssertNil(peer?.pendingRefusals, "not refused on this Mac")
    }

}
