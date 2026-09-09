import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class RemoteResponseNotificationServiceTests: HostedStoreTestCase {
    func testMacObserverDoesNotReannounceRestoredUnreadReceipts() async throws {
        let sessionID = try makeSession()
        let runtime = AgentRuntime.shared
        let terminal = QuestionTerminal()
        terminal.activityTracker.markDormant()
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(terminal, for: sessionID))
        defer { runtime.discard(sessionID: sessionID) }
        runtime.noteSessionAttention(sessionID)

        var posts: [AttentionAlert] = []
        var callbacks = 0
        let observer = AttentionAlertRuntimeObserver(
            appIsActive: { false }, isSnoozed: { _ in false }
        ) { event, action in
            guard event.sessionID == sessionID else { return }
            callbacks += 1
            if case .post(let alert) = action { posts.append(alert) }
        }
        terminal.activityTracker.markRunning()
        terminal.activityTracker.noteUnattendedLaunch()
        runtime.publishRuntimeChange(sessionID: sessionID)
        XCTAssertEqual(runtime.activity(sessionID: sessionID), .needsAttention,
                       "the prior unread badge must still be restored")
        XCTAssertEqual(runtime.runtimeSnapshot(sessionID: sessionID).activity, .idle)
        // Normal startup has dozens of sessions; stress the presentation callback with 1,000
        // invalidations. The notification observer should do no work for any of them.
        for _ in 0..<1_000 {
            NotificationCenter.default.post(SessionActivityDidChange(sessionID: sessionID))
        }
        let restored = expectation(description: "Restore events drained")
        Task { @MainActor in restored.fulfill() }
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(callbacks, 1, "only the actual runtime transition reaches alert policy")

        terminal.activityTracker.noteTurnStarted()
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.noteTurnFinished()
        runtime.publishRuntimeChange(sessionID: sessionID)
        let finished = expectation(description: "Fresh completion drained")
        Task { @MainActor in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(posts, [.unread], "real new work still deserves its alert")
        withExtendedLifetime(observer) {}
    }

    func testMacObserverDropsAQuestionAnsweredBeforeItsDeliveryJob() async throws {
        let sessionID = try makeSession()
        let runtime = AgentRuntime.shared
        let terminal = QuestionTerminal()
        terminal.activityTracker.markRunning()
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(terminal, for: sessionID))
        defer { runtime.discard(sessionID: sessionID) }
        var posts: [AttentionAlert] = []
        let observer = AttentionAlertRuntimeObserver(
            appIsActive: { false }, isSnoozed: { _ in false }
        ) { event, action in
            guard event.sessionID == sessionID else { return }
            if case .post(let alert) = action { posts.append(alert) }
        }
        terminal.activityTracker.noteTurnStarted()
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.noteAwaitingUser()
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.noteUserInput(submitsLine: true)
        runtime.publishRuntimeChange(sessionID: sessionID)
        let drained = expectation(description: "Answered question job drained")
        Task { @MainActor in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertTrue(posts.isEmpty)
        withExtendedLifetime(observer) {}
    }

    func testCompletedTurnAndLaterIdleNoticesNeverSendAQuestion() async throws {
        let sessionID = try makeSession()
        let runtime = AgentRuntime.shared
        let terminal = QuestionTerminal()
        terminal.activityTracker.markRunning()
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(terminal, for: sessionID))
        defer { runtime.discard(sessionID: sessionID) }
        let service = RemoteNotificationService(subscriptionStore: InMemoryRemoteNotificationSubscriptionStore())
        defer { service.reset() }
        let completed = expectation(description: "Completion delivered")
        var kinds: [RemoteNotificationKind] = []
        service.configureHostedPushSender(
            serviceURL: { URL(string: "https://example.test")! }, isAvailable: { true }
        ) { event, _, _ in
            kinds.append(event.kind)
            if event.kind == .turnCompleted { completed.fulfill() }
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        register(service, enabledKinds: [.agentQuestion, .turnCompleted])
        service.setMacApplicationActive(false)
        terminal.activityTracker.noteTurnStarted()
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.noteTurnFinished()
        runtime.publishRuntimeChange(sessionID: sessionID)
        XCTAssertEqual(terminal.activityTracker.activity, .needsAttention)
        XCTAssertEqual(terminal.activityTracker.runtimeSnapshot.blocker, .none)
        await fulfillment(of: [completed], timeout: 2)

        // Reading and then leaving the chat lets a later idle notice raise the unread flag
        // again. Neither that notice nor a BEL is a question when no turn is open.
        terminal.activityTracker.isVisible = true
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.isVisible = false
        terminal.activityTracker.noteAwaitingUser(.idlePrompt)
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.recordBell()
        runtime.publishRuntimeChange(sessionID: sessionID)
        let drained = expectation(description: "Notification queue drained")
        Task { @MainActor in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(kinds, [.turnCompleted])
    }

    func testFinishingOffScreenResolvesAnAcceptedQuestion() async throws {
        let sessionID = try makeSession()
        let runtime = AgentRuntime.shared
        let terminal = QuestionTerminal()
        terminal.activityTracker.markRunning()
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(terminal, for: sessionID))
        defer { runtime.discard(sessionID: sessionID) }
        let service = RemoteNotificationService(subscriptionStore: InMemoryRemoteNotificationSubscriptionStore())
        defer { service.reset() }
        let pushed = expectation(description: "Question delivered")
        let cleared = expectation(description: "Finished turn retracts question")
        var eventID: String?
        service.configureHostedPushSender(
            serviceURL: { URL(string: "https://example.test")! }, isAvailable: { true }
        ) { event, _, _ in
            eventID = event.id
            pushed.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        service.configureHostedRetractionSender { event, _ in
            XCTAssertEqual(event.eventID, eventID)
            cleared.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        register(service)
        service.setMacApplicationActive(false)
        terminal.activityTracker.noteTurnStarted()
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.noteAwaitingUser()
        runtime.publishRuntimeChange(sessionID: sessionID)
        await fulfillment(of: [pushed], timeout: 2)
        terminal.activityTracker.noteTurnFinished()
        runtime.publishRuntimeChange(sessionID: sessionID)
        XCTAssertEqual(terminal.activityTracker.activity, .needsAttention)
        XCTAssertEqual(terminal.activityTracker.runtimeSnapshot.blocker, .none)
        await fulfillment(of: [cleared], timeout: 2)
    }

    func testPermissionShippingSenderRetractsExactAcceptedRequestAfterMacAnswer() async throws {
        let sessionID = try makeSession()
        let service = RemoteNotificationService(subscriptionStore: InMemoryRemoteNotificationSubscriptionStore())
        let accepted = expectation(description: "Hosted alert accepted")
        let retracted = expectation(description: "Hosted retraction sent")
        var delivered: RemoteNotificationEventDTO?
        service.configureHostedPushSender(
            serviceURL: { URL(string: "https://example.test")! }, isAvailable: { true }
        ) { event, _, _ in
            delivered = event
            accepted.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        service.configureHostedRetractionSender { retraction, _ in
            XCTAssertEqual(retraction.eventID, delivered?.id)
            XCTAssertEqual(retraction.kind, .permissionRequest)
            XCTAssertEqual(retraction.sessionID, sessionID.uuidString)
            retracted.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        register(service)
        service.setMacApplicationActive(false)
        service.permissionRequested(sessionID: sessionID, toolName: "Bash", summary: "private")
        await fulfillment(of: [accepted], timeout: 2)
        service.permissionResolved(sessionID: sessionID)
        await fulfillment(of: [retracted], timeout: 2)
        XCTAssertFalse(delivered?.body.contains("private") ?? true)
        service.reset()
    }

    func testAnswerBeforeQueuedSenderRunsPreventsPermissionPush() async throws {
        let sessionID = try makeSession()
        let service = RemoteNotificationService(subscriptionStore: InMemoryRemoteNotificationSubscriptionStore())
        var pushes = 0
        service.configureHostedPushSender(
            serviceURL: { URL(string: "https://example.test")! }, isAvailable: { true }
        ) { _, _, _ in
            pushes += 1
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        register(service)
        service.setMacApplicationActive(false)
        service.permissionRequested(sessionID: sessionID, toolName: "Bash", summary: "private")
        service.permissionResolved(sessionID: sessionID)
        // Drain the main-actor sender enqueued by the shipping service.
        let drained = expectation(description: "Sender queue drained")
        Task { @MainActor in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(pushes, 0)
        service.reset()
    }

    func testTerminalQuestionRetractsWhenSubmittedAnswerLowersRuntimeBlocker() async throws {
        let sessionID = try makeSession()
        let runtime = AgentRuntime.shared
        let terminal = QuestionTerminal()
        terminal.activityTracker.markRunning()
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(terminal, for: sessionID))
        defer { runtime.discard(sessionID: sessionID) }
        let service = RemoteNotificationService(subscriptionStore: InMemoryRemoteNotificationSubscriptionStore())
        let pushed = expectation(description: "Question push")
        let cleared = expectation(description: "Question retracted after answer")
        var eventID: String?
        service.configureHostedPushSender(
            serviceURL: { URL(string: "https://example.test")! }, isAvailable: { true }
        ) { event, _, _ in
            XCTAssertEqual(event.kind, .agentQuestion)
            eventID = event.id
            pushed.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        service.configureHostedRetractionSender { retraction, _ in
            XCTAssertEqual(retraction.eventID, eventID)
            XCTAssertEqual(retraction.kind, .agentQuestion)
            cleared.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        register(service)
        terminal.activityTracker.noteTurnStarted()
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.noteAwaitingUser()
        NotificationCenter.default.post(SessionActivityDidChange(sessionID: sessionID))
        let presentationDrained = expectation(description: "Presentation event drained")
        Task { @MainActor in presentationDrained.fulfill() }
        await fulfillment(of: [presentationDrained], timeout: 2)
        XCTAssertNil(eventID, "Read/badge presentation must not authorize a question push")
        runtime.publishRuntimeChange(sessionID: sessionID)
        await fulfillment(of: [pushed], timeout: 2)
        terminal.activityTracker.noteUserInput(submitsLine: false)
        runtime.publishRuntimeChange(sessionID: sessionID)
        XCTAssertEqual(terminal.activityTracker.runtimeSnapshot.blocker, .awaitingUser)
        terminal.activityTracker.noteUserInput(submitsLine: true)
        runtime.publishRuntimeChange(sessionID: sessionID)
        XCTAssertEqual(terminal.activityTracker.runtimeSnapshot.blocker, .none)
        await fulfillment(of: [cleared], timeout: 2)
        service.reset()
    }

    private func makeSession() throws -> SessionID {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notification-service-\(UUID().uuidString)")
        ))
        return try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude)).id
    }

    private func register(
        _ service: RemoteNotificationService,
        enabledKinds: [RemoteNotificationKind] = [.permissionRequest, .agentQuestion]
    ) {
        let result = service.register(.init(
            deviceToken: String(repeating: "ab", count: 32),
            hostedRegistrationID: "th_push_" + String(repeating: "a", count: 43),
            environment: .sandbox,
            enabledKinds: enabledKinds,
            capabilities: [.notificationRetraction]
        ), deviceID: "phone", authorization: .init(
            shareID: "owner", capability: .interact, scope: .allSessions, boundDeviceID: "phone"
        ))
        XCTAssertEqual(result, .registered(.init(delivery: .push)))
    }
}

@MainActor
private final class QuestionTerminal: AgentTerminalRuntimeSurface, RemoteTerminalSurface {
    var isRunning = true
    var activity: SessionActivity { activityTracker.activity }
    let activityTracker = SessionActivityTracker()
    var runProgress: RunProgress?
    var isVisible = false
    var terminalRootProcessIdentifier: pid_t? { nil }
    var remoteTerminalSurface: any RemoteTerminalSurface { self }
    var remoteTerminalState: RemoteTerminalState {
        .init(grid: .init(cols: 0, rows: 0), title: "", remoteViewport: nil)
    }
    var remoteTerminalSnapshot: RemoteTerminalSnapshot {
        .init(grid: remoteTerminalState.grid, title: "", screenSeed: Data(), remoteViewport: nil)
    }
    func setRemoteOutputSink(_ sink: RemoteTerminalOutputSink?) {}
    func sendRemoteInput(_ bytes: [UInt8]) {}
    func setRemoteViewport(_ grid: RemoteTerminalGrid?) {}
    func pasteTerminalText(_ text: String) {}
    func insertTerminalText(_ text: String) {}
    func visibleTerminalScreenLines() -> [String] { [] }
    func noteLimitCleared() {}
    func noteLimitParked(recoveryArmed: Bool) {}
    func noteStateChanged() {}
    func applyRunProgress(_ report: HookRunProgressReport) {}
    func noteReportedCodexTranscript(path: String?, providerSessionID: TranscriptID?) {}
    func noteTurnFinishedForAttachmentDetection(lastAssistantMessage: String?) {}
    func terminate() { isRunning = false }
    func removeFromPresentation() {}
}
