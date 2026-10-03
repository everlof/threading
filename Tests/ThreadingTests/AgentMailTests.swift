import XCTest
import ThreadingController

@testable import Threading

// MARK: - Mailbox

/// The Mac's mailbox file: a controller store in a scratch directory, never the user's.
final class MacMailboxTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMailboxTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mailbox() -> MacMailbox {
        MacMailbox(databaseURL: directory.appendingPathComponent("Mail/mailbox.db"))
    }

    func testHostedTestsResolveTheMailboxIntoTheScratchDirectory() {
        let url = MacMailbox.liveDatabaseURL()
        XCTAssertTrue(
            url.path.hasPrefix(StateManager.hostedTestDirectory().path),
            "a hosted test must never open the developer's mailbox: \(url.path)"
        )
        XCTAssertEqual(url.lastPathComponent, MacMailDefaults.databaseFileName)
    }

    func testSessionsAreRegisteredLazilyUnderThisMacsHost() async throws {
        let mailbox = mailbox()
        let session = SessionID()
        let host = try await mailbox.host()
        let address = try await mailbox.register(session, name: "Fix the importer")
        XCTAssertEqual(address, MailAddress(host: host.id, kind: .session, id: session.rawValue))
        XCTAssertEqual(address.description, "\(host.id)/session/\(session.uuidString.lowercased())")
        let again = try await mailbox.host()
        XCTAssertEqual(again.id, host.id, "the host id is minted once")
    }

    func testOwnerAdmittedLocalMailIsReadNoticedAndAcknowledged() async throws {
        let mailbox = mailbox()
        let sender = SessionID()
        let recipient = SessionID()
        let to = try await mailbox.register(recipient, name: "Review pass")
        let id = UUID()
        _ = try await mailbox.send(
            from: sender, senderName: "Fix the importer", to: to, id: id,
            text: "The byte cap is the bug.", replyTo: nil, priority: .normal, ownerAdmitted: true
        )
        let probe = await mailbox.hasUnannouncedMail(for: recipient)
        XCTAssertTrue(probe)

        let maybeNotice = await mailbox.notice(for: recipient, event: .postToolUse)
        let notice = try XCTUnwrap(maybeNotice)
        XCTAssertTrue(notice.contains("Fix the importer"))
        XCTAssertFalse(notice.contains("byte cap"), "a notice never carries the body")
        let second = await mailbox.notice(for: recipient, event: .postToolUse)
        XCTAssertNil(second, "a message is announced once per event kind")
        let afterNotice = await mailbox.hasUnannouncedMail(for: recipient)
        XCTAssertFalse(afterNotice)

        let page = try await mailbox.inbox(for: recipient, name: "Review pass", after: 0, limit: 20)
        XCTAssertEqual(page.items.map(\.message.envelope.text), ["The byte cap is the bug."])
        XCTAssertTrue(page.items[0].header.contains(id.uuidString.lowercased()))

        _ = try await mailbox.acknowledge(for: recipient, name: "Review pass", ids: [id])
        let empty = try await mailbox.inbox(for: recipient, name: "Review pass", after: 0, limit: 20)
        XCTAssertTrue(empty.items.isEmpty)

        let snapshot = try await mailbox.snapshot(for: sender, limit: 5)
        XCTAssertEqual(snapshot.sent.map(\.envelope.id), [id])
    }

    func testWithoutOwnerAdmissionALocalSendNeedsAGrant() async throws {
        let mailbox = mailbox()
        let to = try await mailbox.register(SessionID(), name: "Target")
        do {
            _ = try await mailbox.send(
                from: SessionID(), senderName: "Sender", to: to, id: UUID(), text: "hi",
                replyTo: nil, priority: .normal, ownerAdmitted: false
            )
            XCTFail("an unadmitted send was accepted")
        } catch let failure as MacMailbox.Failure {
            XCTAssertEqual(failure, .refused(.forbidden))
        }
    }

    func testARemoteRecipientWithoutAPeerIsAnUnknownHost() async throws {
        let mailbox = mailbox()
        let remote = MailAddress(host: HostID(), kind: .worker, id: UUID())
        do {
            _ = try await mailbox.send(
                from: SessionID(), senderName: "Sender", to: remote, id: UUID(), text: "hi",
                replyTo: nil, priority: .normal, ownerAdmitted: false
            )
            XCTFail("mail to an unknown host was queued")
        } catch let failure as MacMailbox.Failure {
            XCTAssertEqual(failure, .refused(.invalidInput("unknown_host")))
            XCTAssertEqual(MailAgentCommandService.mailWords(for: failure), MailAgentCommandService.unknownRecipientWords)
        }
    }

    func testAnUnreadableFileIsReportedAndNeverRecreated() async throws {
        let url = directory.appendingPathComponent("Mail/mailbox.db")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data(repeating: 0x5A, count: 8_192)
        try garbage.write(to: url)
        let mailbox = MacMailbox(databaseURL: url)
        do {
            _ = try await mailbox.host()
            XCTFail("an unreadable mailbox opened")
        } catch let failure as MacMailbox.Failure {
            guard case .unavailable = failure else { return XCTFail("\(failure)") }
        }
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, garbage, "the bytes stay for a build that can read them")
        let notice = await mailbox.notice(for: SessionID(), event: .stop)
        XCTAssertNil(notice, "an unavailable mailbox answers a hook with silence")
    }

    func testAddressResolutionAcceptsIdsAndAddressesOnly() {
        let local = HostID()
        let session = SessionID()
        XCTAssertEqual(MailAgentCommandService.mailTarget(session.uuidString, localHost: local), .session(session))
        let own = MailAddress(host: local, kind: .session, id: session.rawValue)
        XCTAssertEqual(MailAgentCommandService.mailTarget(own.description, localHost: local), .session(session))
        let worker = MailAddress(host: local, kind: .worker, id: UUID())
        XCTAssertNil(MailAgentCommandService.mailTarget(worker.description, localHost: local),
                     "this Mac runs no workers")
        let remote = MailAddress(host: HostID(), kind: .worker, id: UUID())
        XCTAssertEqual(MailAgentCommandService.mailTarget(remote.description, localHost: local), .remote(remote))
        XCTAssertNil(MailAgentCommandService.mailTarget("Review pass", localHost: local))
    }
}

// MARK: - Scope and the send_to_session fallback

@MainActor
final class AgentMailControlTests: XCTestCase {

    private struct Fixture {
        let caller = AgentSession(kind: .claude, title: "Fix the importer")
        let peer = AgentSession(kind: .codex, title: "Review pass")
        let stranger = AgentSession(kind: .claude, title: "Another project's session")
        var project: Project
        var other: Project

        init() {
            project = Project(name: "Alpha", folderURL: URL(fileURLWithPath: "/tmp/alpha"))
            other = Project(name: "Beta", folderURL: URL(fileURLWithPath: "/tmp/beta"))
            project.sessions = [caller, peer]
            other.sessions = [stranger]
        }

        var sessions: [AgentSession] { project.sessions + other.sessions }
    }

    private final class Stored {
        var messages: [(text: String, target: SessionID, caller: SessionID)] = []
    }

    private func plane(
        _ fixture: Fixture,
        outcome: SessionMessageDelivery.Outcome,
        stored: Stored,
        stores: Bool = true
    ) -> WorkspaceControlPlane {
        var dependencies = WorkspaceControlPlane.Dependencies(
            session: { id in fixture.sessions.first { $0.id == id } },
            projectForSession: { id in
                fixture.project.sessions.contains { $0.id == id } ? fixture.project
                    : fixture.other.sessions.contains { $0.id == id } ? fixture.other : nil
            },
            activity: { _ in .working },
            surface: { _ in .terminal },
            deliver: { _, _, done in done(outcome) },
            steer: { _, _ in .targetNotLiveChat },
            armWatch: { _, _, _ in .watcherAtCapacity(limit: 0) }
        )
        dependencies.storeAsMail = { text, target, caller, done in
            if stores { stored.messages.append((text, target, caller)) }
            done(stores)
        }
        return WorkspaceControlPlane(dependencies: dependencies)
    }

    private func send(_ plane: WorkspaceControlPlane, _ text: String, to target: SessionID, from caller: SessionID)
        -> ControlSendOutcome {
        var result: ControlSendOutcome = .refused(.deliveryFailed)
        plane.send(text, to: target, from: .agentSession(caller)) { result = $0 }
        return result
    }

    func testMailIsAdmittedWithinTheProjectAndOutOfScopeAnswersAsUnknown() {
        let fixture = Fixture()
        let plane = plane(fixture, outcome: .sentNow, stored: Stored())
        guard case .success(let row) = plane.admitMail(to: fixture.peer.id, from: .agentSession(fixture.caller.id)) else {
            return XCTFail("a same-project sibling must be admitted")
        }
        XCTAssertEqual(row.id, fixture.peer.id)

        let outside = plane.admitMail(to: fixture.stranger.id, from: .agentSession(fixture.caller.id))
        let missing = plane.admitMail(to: SessionID(), from: .agentSession(fixture.caller.id))
        XCTAssertEqual(outside, .failure(.targetUnknown))
        XCTAssertEqual(outside, missing, "out of scope must be indistinguishable from nonexistent")
        XCTAssertEqual(
            plane.admitMail(to: fixture.caller.id, from: .agentSession(fixture.caller.id)),
            .failure(.targetIsCaller)
        )
    }

    func testABusyTerminalOrDormantTargetGetsTheMessageAsMail() {
        let fixture = Fixture()
        for outcome in [SessionMessageDelivery.Outcome.busyTerminal, .noLiveSurface] {
            let stored = Stored()
            let result = send(plane(fixture, outcome: outcome, stored: stored), "  The cap is the bug.  ",
                              to: fixture.peer.id, from: fixture.caller.id)
            guard case .storedInMailbox(let row) = result else { return XCTFail("\(outcome): \(result)") }
            XCTAssertEqual(row.id, fixture.peer.id)
            XCTAssertEqual(stored.messages.map(\.text), ["The cap is the bug."],
                           "the body is stored without the delivery header; the inbox vouches for the sender")
            XCTAssertEqual(stored.messages.first?.caller, fixture.caller.id)
        }
    }

    func testAMailboxThatCannotStoreKeepsTheOldRefusals() {
        let fixture = Fixture()
        XCTAssertEqual(
            send(plane(fixture, outcome: .busyTerminal, stored: Stored(), stores: false), "hi",
                 to: fixture.peer.id, from: fixture.caller.id),
            .refused(.targetBusy)
        )
        XCTAssertEqual(
            send(plane(fixture, outcome: .noLiveSurface, stored: Stored(), stores: false), "hi",
                 to: fixture.peer.id, from: fixture.caller.id),
            .refused(.targetNotRunning)
        )
    }

    func testImmediateDeliveryIsUnchangedAndNeverStoresMail() {
        let fixture = Fixture()
        let stored = Stored()
        guard case .sent = send(plane(fixture, outcome: .sentNow, stored: stored), "hi",
                                to: fixture.peer.id, from: fixture.caller.id) else { return XCTFail() }
        XCTAssertTrue(stored.messages.isEmpty)
    }
}

// MARK: - Delivery rules

@MainActor
final class MacMailDeliveryTests: XCTestCase {

    private final class FakeChat: AppMessageReceiving {
        var isRunning = true
        var steers: AppMessageSteerResult = .steered
        var accepted: [String] = []
        var steered: [String] = []

        func acceptAppMessage(
            _ prompt: ConversationPrompt, origin: ConversationOutbox.Item.Origin, attachmentIDs: [String]
        ) -> AppMessageAcceptance {
            accepted.append(prompt.text)
            return .queuedBehindTurn
        }

        func steerAppMessage(_ prompt: ConversationPrompt) -> AppMessageSteerResult {
            if steers == .steered { steered.append(prompt.text) }
            return steers
        }
    }

    func testThePlanFollowsTheSurfaceAndNeverTheRuntimeName() {
        typealias Facts = MacMailDelivery.Facts
        XCTAssertEqual(MacMailDelivery.plan(for: Facts(surface: .chat, terminalReady: false, answersHooks: true), priority: .interrupt), .steerNotice)
        XCTAssertEqual(MacMailDelivery.plan(for: Facts(surface: .chat, terminalReady: false, answersHooks: true), priority: .normal), .queueNotice)
        XCTAssertEqual(MacMailDelivery.plan(for: Facts(surface: .terminal, terminalReady: true, answersHooks: false), priority: .normal), .typeNotice)
        XCTAssertEqual(MacMailDelivery.plan(for: Facts(surface: .terminal, terminalReady: false, answersHooks: true), priority: .interrupt), .awaitHooks)
        XCTAssertEqual(MacMailDelivery.plan(for: Facts(surface: .terminal, terminalReady: false, answersHooks: false), priority: .normal), .awaitBoundary)
        XCTAssertEqual(MacMailDelivery.plan(for: Facts(surface: .dormant, terminalReady: false, answersHooks: true), priority: .interrupt), .awaitLaunch)
    }

    func testOnlyRuntimesWhoseHooksAnswerClaimTheCapability() {
        XCTAssertTrue(AgentKind.claude.supports(.answeringMailHooks))
        XCTAssertTrue(AgentKind.codex.supports(.answeringMailHooks))
        XCTAssertFalse(AgentKind.grok.supports(.answeringMailHooks))
        XCTAssertFalse(AgentKind.openCode.supports(.answeringMailHooks))
    }

    func testAnInterruptSteersTheNoticeAndFallsBackToTheQueue() {
        let chat = FakeChat()
        XCTAssertEqual(MacMailDelivery.offer("Threading: 1 unread mail message.", to: chat, steering: true), .steered)
        XCTAssertEqual(chat.steered, ["Threading: 1 unread mail message."])
        XCTAssertTrue(chat.accepted.isEmpty)

        chat.steers = .refused(.noActiveTurn)
        XCTAssertEqual(MacMailDelivery.offer("Threading: 2 unread mail messages.", to: chat, steering: true), .queued)
        XCTAssertEqual(chat.accepted, ["Threading: 2 unread mail messages."])

        XCTAssertEqual(MacMailDelivery.offer("Threading: notice", to: chat, steering: false), .queued)
        chat.isRunning = false
        XCTAssertEqual(MacMailDelivery.offer("Threading: notice", to: chat, steering: false), .notTaken)
    }
}

// MARK: - Hooks

@MainActor
final class MailNoticeHookTests: XCTestCase {

    override func tearDown() {
        MailStopContinuationLedger.reset()
        super.tearDown()
    }

    func testHookOutputMatchesTheControllersShape() throws {
        let stop = MacMailHookOutput.object(event: .stop, notice: "Threading: 1 unread")
        XCTAssertEqual(stop["decision"] as? String, "block")
        XCTAssertEqual(stop["reason"] as? String, "Threading: 1 unread")

        for (event, name) in [(MailNoticeEvent.postToolUse, "PostToolUse"), (.sessionStart, "SessionStart")] {
            let object = MacMailHookOutput.object(event: event, notice: "n")
            let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: String])
            XCTAssertEqual(specific, ["hookEventName": name, "additionalContext": "n"])
        }
        XCTAssertTrue(MacMailHookOutput.silence.body.isEmpty)
        XCTAssertEqual(MacMailHookOutput.silence.status, 200)
        XCTAssertEqual(MCPServer.mailNoticeEvent(inQuery: "event=stop"), .stop)
        XCTAssertNil(MCPServer.mailNoticeEvent(inQuery: "event=bogus"))
    }

    func testClaudeSettingsCarryTheMailHooksAsSeparateEntries() throws {
        let sessionID = SessionID()
        defer { MCPSessionRegistry.remove(sessionID: sessionID) }
        let token = MCPSessionRegistry.token(for: sessionID)
        let with = try XCTUnwrap(MCPSessionRegistry.hookSettings(
            for: sessionID, brokersPermissions: false, reportsLifecycle: true, mailNotices: true
        ))
        let without = try XCTUnwrap(MCPSessionRegistry.hookSettings(
            for: sessionID, brokersPermissions: false, reportsLifecycle: true
        ))
        let withHooks = try XCTUnwrap(with["hooks"] as? [String: [[String: Any]]])
        let withoutHooks = try XCTUnwrap(without["hooks"] as? [String: [[String: Any]]])
        for event in MailNoticeHook.events {
            let name = MailNoticeHook.hookName(for: event)
            let expected = MailNoticeHook.claudeCommand(token: token, event: event)
            let commands = (withHooks[name] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
            XCTAssertTrue(commands.contains(expected), "\(name) has no mail entry")
            XCTAssertEqual((withHooks[name]?.count ?? 0) - (withoutHooks[name]?.count ?? 0), 1,
                           "the mail entry is added beside the lifecycle entries, never in place of one")
            XCTAssertFalse(expected.contains(">/dev/null 2>&1"), "the mail hook's stdout is its answer")
            XCTAssertTrue(expected.hasSuffix("2>/dev/null || true"))
        }
        let off = try XCTUnwrap(MCPSessionRegistry.hookSettings(
            for: sessionID, brokersPermissions: false, reportsLifecycle: false, theme: "dark-ansi", mailNotices: true
        ))
        XCTAssertNil((off["hooks"] as? [String: Any])?["PostToolUse"], "no lifecycle reporting, no mail hooks")
    }

    func testAnUnreachableAppMakesTheMailHookSilentAndSuccessful() throws {
        let command = MailNoticeHook.claudeCommand(token: "nobody", event: .stop)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin", "THREADING_MCP_SOCKET": "/nonexistent/socket", "THREADING_MCP_PORT": "1"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"stop_hook_active":false}"#.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(data.isEmpty, "an absent app must print nothing: \(String(decoding: data, as: UTF8.self))")
    }

    func testCodexInstallsTheMailEntriesBesideItsOwnAndKeepsForeignOnes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-mail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let foreign: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo other-tool"]]]]]]
        try JSONSerialization.data(withJSONObject: foreign).write(to: CodexHookInstaller.hooksFile(inCodexHome: home.path))

        XCTAssertTrue(CodexHookInstaller.install(inCodexHome: home.path))
        XCTAssertFalse(CodexHookInstaller.install(inCodexHome: home.path), "an unchanged file is never rewritten")
        let data = try Data(contentsOf: CodexHookInstaller.hooksFile(inCodexHome: home.path))
        let hooks = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
        for event in MailNoticeHook.events {
            let commands = (hooks[MailNoticeHook.hookName(for: event)] ?? [])
                .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
            let mail = CodexHookInstaller.command(for: event)
            XCTAssertTrue(commands.contains(mail))
            XCTAssertTrue(mail.contains(MCPDefaults.hookMarker))
            XCTAssertTrue(mail.contains("[ -n \"$THREADING_SESSION_TOKEN\" ]"), "inert for runs that are not Threading's")
        }
        let stops = (hooks["Stop"] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertTrue(stops.contains("echo other-tool"))
    }

    // MARK: Stop continuation

    func testABlockedStopHoldsTheFinishUntilTheAgentProvesItWentOn() throws {
        let session = SessionID()
        var relayed: [HookLifecycleReport] = []
        var scheduled: [@MainActor () -> Void] = []
        MailStopContinuationLedger.schedule = { _, work in scheduled.append(work) }
        defer { MailStopContinuationLedger.schedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        } }
        let finish = try XCTUnwrap(HookLifecycleReport(sessionID: session, event: .turnFinished, payload: [:]))

        XCTAssertEqual(MailStopContinuationLedger.recordBlock(session), .holdNextFinish)
        XCTAssertTrue(MailStopContinuationLedger.absorbsFinish(finish) { relayed.append($0) })
        MailStopContinuationLedger.recordEvidence(session)
        scheduled.forEach { $0() }
        XCTAssertTrue(relayed.isEmpty, "the turn went on; its first finish is void")
        XCTAssertFalse(MailStopContinuationLedger.absorbsFinish(finish) { relayed.append($0) },
                       "the real end is relayed")

        // A block the agent never saw: no evidence, so the held finish is relayed after all.
        scheduled.removeAll()
        let other = SessionID()
        let otherFinish = try XCTUnwrap(HookLifecycleReport(sessionID: other, event: .turnFinished, payload: [:]))
        XCTAssertEqual(MailStopContinuationLedger.recordBlock(other), .holdNextFinish)
        XCTAssertTrue(MailStopContinuationLedger.absorbsFinish(otherFinish) { relayed.append($0) })
        scheduled.forEach { $0() }
        XCTAssertEqual(relayed.map(\.sessionID), [other])
    }

    func testAStaleBlockHoldsNothing() throws {
        let session = SessionID()
        let finish = try XCTUnwrap(HookLifecycleReport(sessionID: session, event: .turnFinished, payload: [:]))
        _ = MailStopContinuationLedger.recordBlock(session, now: Date().addingTimeInterval(-60))
        XCTAssertFalse(MailStopContinuationLedger.absorbsFinish(finish) { _ in })
    }

    /// A host-local notice hook answers on the host and also tells this Mac whether it blocked a
    /// Stop, so the Mac's continuation ledger sees a block it would otherwise never hear about.
    func testTheHostNoticeHookReportsItsAnswerBackToTheMac() throws {
        let command = MailNoticeHook.hostCommand(executable: "/opt/threading/threading-controller", event: .stop)
        XCTAssertTrue(command.contains("agent-notice stop"))
        XCTAssertTrue(command.contains("\(MCPDefaults.mailNoticeObservedParameter)=$threading_mail_observed"))
        XCTAssertTrue(command.contains("threading_mail_observed=\(MCPDefaults.mailNoticeObservedBlock)"))
        XCTAssertTrue(command.hasSuffix("printf '%s' \"$threading_mail_answer\"; true"), "the agent still gets the host's answer")
        XCTAssertEqual(MCPServer.mailNoticeObserved(inQuery: "event=stop&observed=block"), MCPDefaults.mailNoticeObservedBlock)
        XCTAssertNil(MCPServer.mailNoticeObserved(inQuery: "event=stop&observed=anything-else"))

        // Reported over the tunnel, the block holds the finish like a block answered here.
        let session = SessionID()
        let finish = try XCTUnwrap(HookLifecycleReport(sessionID: session, event: .turnFinished, payload: [:]))
        MCPServer.recordMailHookCall(session, event: .stop, blocked: true)
        XCTAssertTrue(MailStopContinuationLedger.absorbsFinish(finish) { _ in })
        MailStopContinuationLedger.reset()
    }

    /// The notice typed at the idle edge starts a short new turn, and its Stop is blocked a few
    /// seconds after the previous turn's relayed finish. That block belongs to the new turn: its
    /// finish must be held, not treated as already relayed.
    func testABlockInAFreshTurnSoonAfterTheLastFinishHoldsThatTurnsFinish() throws {
        let session = SessionID()
        let previous = HookLifecycleRelay.observe
        var relayed: [HookLifecycleReport] = []
        HookLifecycleRelay.observe = { relayed.append($0) }
        defer { HookLifecycleRelay.observe = previous }
        let finish = try XCTUnwrap(HookLifecycleReport(sessionID: session, event: .turnFinished, payload: [:]))
        let start = try XCTUnwrap(HookLifecycleReport(sessionID: session, event: .turnStarted, payload: [:]))

        HookLifecycleRelay.deliver(finish)
        HookLifecycleRelay.deliver(start)
        XCTAssertEqual(MailStopContinuationLedger.recordBlock(session, now: Date().addingTimeInterval(6)), .holdNextFinish)
        HookLifecycleRelay.deliver(finish)
        XCTAssertEqual(relayed.map(\.event), [.turnFinished, .turnStarted],
                       "the blocked turn's own finish is held, so the session is not shown idle")
        MailStopContinuationLedger.reset()
    }

    func testABlockAfterTheFinishWasRelayedReopensTheTurn() throws {
        let session = SessionID()
        let finish = try XCTUnwrap(HookLifecycleReport(sessionID: session, event: .turnFinished, payload: [:]))
        XCTAssertFalse(MailStopContinuationLedger.absorbsFinish(finish) { _ in })
        XCTAssertEqual(MailStopContinuationLedger.recordBlock(session), .reopenTurn)
        XCTAssertFalse(MailStopContinuationLedger.absorbsFinish(finish) { _ in },
                       "the reopened turn's own end is relayed normally")
    }
}

// MARK: - Sync

/// Two real controller stores, the second standing in for a remote host, joined by a fake SSH
/// runner that runs `owner-rpc` and `mail-rpc` against it in-process.
final class MacMailSyncTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMailSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Answers the two subcommands the Mac sends over SSH.
    private final class FakeRemote: RemoteHostCommandRunning, @unchecked Sendable {
        let store: ControllerStore
        var answersAs: HostID?
        private let lock = NSLock()
        private var _commands: [String] = []
        var commands: [String] { lock.lock(); defer { lock.unlock() }; return _commands }

        init(store: ControllerStore) { self.store = store }

        func run(on destination: RemoteHostDestination, command: String, input: RemoteHostCommandInput,
                 extraOptions: [String], timeout: TimeInterval) throws -> RemoteHostCommandResult {
            lock.lock(); _commands.append(command); lock.unlock()
            guard case .data(let bytes) = input else { return .init(output: "", termination: .exited(2)) }
            let store = store
            let answersAs = answersAs
            let output = Self.blocking {
                if command.hasSuffix(" owner-rpc") {
                    let request = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    let name = request["command"] as! String
                    let arguments = (request["arguments"] as! [[String: Any]])
                    switch name {
                    case "host": return try Self.encode(try await store.host())
                    case "mail-peers": return try Self.encode(try await store.mailPeers())
                    case "mail-peer-set":
                        let host = try HostID(arguments[0]["value"] as! String)
                        return try Self.encode(try await store.setMailPeer(
                            host: host, expectedRevision: Int(arguments[1]["value"] as! String)!,
                            name: arguments[2]["value"] as! String, transport: nil, push: false, pull: false))
                    default: throw ControllerError.forbidden
                    }
                }
                let peer = try HostID(String(command.split(separator: " ").last!))
                let request = try JSONDecoder().decode(MailRPCRequest.self, from: bytes)
                let response = try await store.handleMailRPC(request, peer: peer)
                guard let answersAs else { return try Self.encode(response) }
                var object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(response)) as! [String: Any]
                object["host"] = answersAs.description
                return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
            }
            guard let output else { return .init(output: "refused", termination: .exited(1)) }
            return .init(output: "Warning: banner\n" + output, termination: .exited(0))
        }

        static func encode<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self) + "\n"
        }

        static func blocking(_ body: @escaping @Sendable () async throws -> String) -> String? {
            let semaphore = DispatchSemaphore(value: 0)
            let box = Box()
            Task.detached { box.value = try? await body(); semaphore.signal() }
            semaphore.wait()
            return box.value
        }

        private final class Box: @unchecked Sendable { var value: String? }
    }

    func testPeeringPushAndPullCarryMailBothWaysAndRefuseAWrongHost() async throws {
        let mac = MacMailbox(databaseURL: directory.appendingPathComponent("mac/mailbox.db"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("host"), withIntermediateDirectories: true)
        let remote = try ControllerStore(path: directory.appendingPathComponent("host/controller.db").path)
        let fake = FakeRemote(store: remote)
        let sync = MacMailSync(mailbox: mac, runner: fake)
        let endpoint = MacMailSync.Endpoint(
            hostID: RemoteHostID(), name: "vps-1",
            destination: RemoteHostDestination(alias: "vps-1", configFile: nil),
            executable: "/opt/threading/threading-controller", database: "/var/lib/threading/controller.db"
        )

        // Peering happens on the first pass, both ways, with no transport on either side.
        let first = await sync.sync(endpoint)
        XCTAssertEqual(first.issues, [])
        let remoteHost = try await remote.host()
        let macHost = try await mac.host()
        let macPeer = try await mac.controllerStore().mailPeer(remoteHost.id)
        XCTAssertNotNil(macPeer)
        XCTAssertNil(macPeer?.transport)
        let theirPeer = try await remote.mailPeer(macHost.id)
        XCTAssertNotNil(theirPeer, "the host must know the Mac before it accepts its mail")
        XCTAssertTrue(fake.commands.contains { $0.contains("mail-rpc --peer \(macHost.id)") })
        XCTAssertTrue(fake.commands.allSatisfy { $0.hasPrefix("'/opt/threading/threading-controller' --database '/var/lib/threading/controller.db' ") })

        // A Mac session writes to a session mailbox on the host; the host's grant admits it.
        let hostSession = MailAddress(host: remoteHost.id, kind: .session, id: UUID())
        _ = try await remote.registerMailbox(hostSession, name: "Deploy bot")
        _ = try await remote.setMailGrant(recipient: hostSession, sender: "\(macHost.id)/*", expectedRevision: 0,
                                          mode: .notify, allowsInterrupt: false)
        let macSession = SessionID()
        let question = UUID()
        _ = try await mac.send(from: macSession, senderName: "Fix the importer", to: hostSession, id: question,
                               text: "Is the deploy done?", replyTo: nil, priority: .normal, ownerAdmitted: false)
        let pushed = await sync.sync(endpoint)
        XCTAssertEqual(pushed.pushed, 1)
        let arrived = try await remote.inbox(hostSession)
        XCTAssertEqual(arrived.items.map(\.message.envelope.text), ["Is the deploy done?"])
        let forwarded = try await mac.snapshot(for: macSession, limit: 5).sent.first?.state
        XCTAssertEqual(forwarded, .forwarded)

        // The reply needs no grant on the Mac: it answers mail the Mac session sent.
        _ = try await remote.sendMail(from: hostSession, to: MailAddress(host: macHost.id, kind: .session, id: macSession.rawValue),
                                      id: UUID(), text: "Yes, at 14:02.", replyTo: question, priority: .normal)
        let pulled = await sync.sync(endpoint)
        XCTAssertEqual(pulled.pulled, 1)
        XCTAssertEqual(pulled.recipients, [macSession])
        let inbox = try await mac.inbox(for: macSession, name: "Fix the importer", after: 0, limit: 5)
        XCTAssertEqual(inbox.items.map(\.message.envelope.text), ["Yes, at 14:02."])

        // A response naming another host is refused rather than trusted.
        _ = try await mac.send(from: macSession, senderName: "Fix the importer", to: hostSession, id: UUID(),
                               text: "One more thing.", replyTo: nil, priority: .normal, ownerAdmitted: false)
        fake.answersAs = HostID()
        let refused = await sync.sync(endpoint)
        XCTAssertEqual(refused.pushed, 0)
        XCTAssertFalse(refused.issues.isEmpty)
        let stillQueued = try await mac.controllerStore().outboundBatch(for: remoteHost.id).envelopes.count
        XCTAssertEqual(stillQueued, 1, "nothing is settled on a wrong host's word")
    }
}

// MARK: - The Info panel's Mail section

/// Draws the session Info panel's Mail section from a fixture presentation, light and dark under
/// System and one stock theme, and asserts what the picture is reviewed for: the rows exist, name
/// party, host and state, and never carry a message's text.
@MainActor
final class SessionMailRenderTests: XCTestCase {

    private static let fixture = SessionMailPresentation(
        received: [
            .init(id: UUID(), direction: .received, party: "Deploy bot", host: "vps-1",
                  state: SessionMailPresentation.words(for: .inbox), isUrgent: true, isProblem: false),
            .init(id: UUID(), direction: .received, party: "Review pass", host: "this Mac",
                  state: SessionMailPresentation.words(for: .noticed), isUrgent: false, isProblem: false)
        ],
        sent: [
            .init(id: UUID(), direction: .sent, party: "Worker", host: "vps-1",
                  state: SessionMailPresentation.words(for: .forwarded), isUrgent: false, isProblem: false),
            .init(id: UUID(), direction: .sent, party: "Session", host: "build-box",
                  state: SessionMailPresentation.words(for: .bounced), isUrgent: false, isProblem: true)
        ]
    ).granting([SessionMailRenderTests.wakeGrant]).located("Kept on vps-1, which can’t be reached; as of 3 min. ago.")

    static let wakeGrant: MailGrant = {
        let host = HostID()
        let json = #"{"recipient":"\#(host)/session/\#(UUID().uuidString)","sender":"\#(host)/*","mode":"wake","allowsInterrupt":false,"revision":1}"#
        return try! JSONDecoder().decode(MailGrant.self, from: Data(json.utf8))
    }()

    private func panel(_ presentation: SessionMailPresentation?) -> (SessionInfoViewController, ThemedSurfaceView) {
        let controller = SessionInfoViewController(sessionID: SessionID(), folderPath: NSHomeDirectory())
        controller.readSource = { completion in completion(.empty) }
        controller.usageSource = { nil }
        controller.mailSource = { presentation }
        let host = ThemedSurfaceView()
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        let view = controller.view
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        controller.apply(.empty, isRunning: false)
        host.layoutSubtreeIfNeeded()
        return (controller, host)
    }

    private static func rows(in view: NSView) -> [SessionInfoRowView] {
        view.subviews.flatMap { ($0 as? SessionInfoRowView).map { [$0] } ?? [] + rows(in: $0) }
    }

    private func labels(_ rows: [SessionInfoRowView]) -> [String] { rows.map { $0.accessibilityLabel() ?? "" } }

    func testTheSectionListsReceivedAndSentRowsWithoutBodies() {
        let (controller, _) = panel(Self.fixture)
        let rows = Self.rows(in: controller.view)
        XCTAssertEqual(rows.count, 4 + 1 + 2, "four messages, one grant, grant and contact actions")
        XCTAssertTrue(labels(rows).contains { $0.contains(SessionMailPresentation.words(for: .wake)) })
        let labels = labels(rows)
        XCTAssertTrue(labels.contains { $0.contains("Deploy bot") && $0.contains("vps-1") && $0.contains("Urgent") })
        XCTAssertTrue(labels.contains { $0.contains(SessionMailPresentation.words(for: .bounced)) })

        let (empty, _) = panel(nil)
        XCTAssertEqual(Self.rows(in: empty.view).count, 2, "only the grant and contact actions")
    }

    func testRendersTheMailSectionToImages() throws {
        let directory: URL = {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThreadingRenders", isDirectory: true)
        }()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }
        for (themeName, theme) in [("system", AppTheme.system), ("swiss", AppThemeStyles.swissMinimalist)] {
            AppThemePalette.set(theme)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                var data: Data?
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    MainActor.assumeIsolated {
                        let (_, host) = panel(Self.fixture)
                        host.appearance = NSAppearance(named: appearance)
                        AppThemeRefresh.repaint(host)
                        host.layoutSubtreeIfNeeded()
                        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                        host.cacheDisplay(in: host.bounds, to: rep)
                        data = rep.representation(using: .png, properties: [:])
                    }
                }
                let png = try XCTUnwrap(data, "the \(themeName) \(name) render produced no image")
                XCTAssertGreaterThan(png.count, 1_000)
                try png.write(to: directory.appendingPathComponent("session-mail-\(themeName)-\(name).png"))
            }
        }
    }

    func testPresentationNamesLocalSessionsAndHostsAndCarriesNoText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SessionMail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = MacMailbox(databaseURL: directory.appendingPathComponent("mailbox.db"))
        let sender = SessionID(), recipient = SessionID()
        let to = try await mailbox.register(recipient, name: "Review pass")
        _ = try await mailbox.send(from: sender, senderName: "Fix the importer", to: to, id: UUID(),
                                   text: "secret body", replyTo: nil, priority: .interrupt, ownerAdmitted: true)
        let received = SessionMailPresentation(try await mailbox.snapshot(for: recipient, limit: 5)) { _ in nil }
        XCTAssertEqual(received.received.map(\.party), ["Fix the importer"])
        XCTAssertEqual(received.received.first?.isUrgent, true)
        let sent = SessionMailPresentation(try await mailbox.snapshot(for: sender, limit: 5)) {
            $0 == recipient ? "Review pass" : nil
        }
        XCTAssertEqual(sent.sent.map(\.party), ["Review pass"])
        XCTAssertFalse("\(received)\(sent)".contains("secret body"))
    }
}
