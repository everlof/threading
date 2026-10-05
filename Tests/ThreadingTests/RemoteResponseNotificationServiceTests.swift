import XCTest
import ThreadingRemoteKit
import AppKit
import AVFoundation
@testable import Threading

@MainActor
final class RemoteResponseNotificationServiceTests: HostedStoreTestCase {
    func testCustomSoundRequiresCurrentAssetDeviceReceiptSoundChoiceAndPreviewConsent() async throws {
        let previous = AppThemeLibrary.current
        let custom = try AppThemeLibrary.duplicate(AppThemeStyles.cyberpunk, name: "Phone sound \(UUID())")
        defer { AppThemeLibrary.installResolved(previous); _ = AppThemeLibrary.delete(custom) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("attention.caf")
        let bytes = try await Task.detached {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            do {
                var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
                buffer.frameLength = 1_600
                memset(buffer.int16ChannelData![0], 0, 3_200)
                try file?.write(from: buffer)
                file = nil
            }
            return try Data(contentsOf: url)
        }.value
        let sound = try XCTUnwrap(ThemeAssetStore.storeSound(data: bytes, for: custom.id,
            event: .needsAttention, variant: .dark, pathExtension: "caf"))
        let variant = try XCTUnwrap(custom.variant(.dark))
        let theme = AppTheme(id: custom.id, name: custom.name, mode: .dark, summary: nil,
            variants: [.dark: variant.replacingCharacter(sprites: variant.sprites,
                moments: .init(moments: [.needsAttention: .init(sound: sound)]), words: variant.words)])
        AppThemeLibrary.installResolved(theme)
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        _ = RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let asset = try XCTUnwrap(RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance)?.first { $0.kind == .sound })
        let name = try XCTUnwrap(asset.notificationSoundName)
        let sessionID = try makeSession()
        let service = RemoteNotificationService(subscriptionStore: InMemoryRemoteNotificationSubscriptionStore())
        defer { service.reset() }
        var delivered: XCTestExpectation!
        var names: [String?] = []
        var soundChoices: [Bool] = []
        service.configureHostedThemePushSender(serviceURL: { URL(string: "https://example.test")! }, isAvailable: { true }) { _, _, plays, sound in
            names.append(sound); soundChoices.append(plays); delivered.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        for (consent, enabled, receipts, expected) in [
            (true, true, ["sound.needsAttention": name], name as String?),
            (false, true, ["sound.needsAttention": name], nil),
            (true, false, ["sound.needsAttention": name], nil),
            (true, true, [:], nil)
        ] {
            delivered = expectation(description: "push \(names.count)")
            let result = service.register(.init(deviceToken: String(repeating: "ab", count: 32),
                hostedRegistrationID: "th_push_" + String(repeating: "a", count: 43), environment: .sandbox,
                enabledKinds: [.permissionRequest], soundEnabledKinds: enabled ? [.permissionRequest] : [],
                capabilities: [.turnCompletionPreview, .notificationRetraction],
                includesResponsePreviews: consent, themeSoundNames: receipts), deviceID: "phone",
                authorization: .init(shareID: "owner", capability: .interact, scope: .allSessions, boundDeviceID: "phone"))
            XCTAssertEqual(result, .registered(.init(delivery: .push)))
            service.permissionRequested(sessionID: sessionID, toolName: "Bash", summary: "private")
            await fulfillment(of: [delivered], timeout: 2)
            XCTAssertEqual(names.last!, expected)
            XCTAssertEqual(soundChoices.last, enabled)
            service.permissionResolved(sessionID: sessionID)
        }
        XCTAssertEqual(RemoteThemeAssets.shared.soundName(for: .permissionRequest, confirmed: [asset.slot: name]), name)
        AppThemeLibrary.installResolved(previous)
        XCTAssertNil(RemoteThemeAssets.shared.soundName(for: .permissionRequest, confirmed: [asset.slot: name]))
    }

    func testRunningShellAcrossWatchRepliesNotifiesOnlyAfterItsResult() async throws {
        let sessionID = try makeSession()
        let runtime = AgentRuntime.shared
        let terminal = QuestionTerminal()
        terminal.activityTracker.markRunning()
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(terminal, for: sessionID))
        defer { runtime.discard(sessionID: sessionID) }
        let service = RemoteNotificationService(subscriptionStore: InMemoryRemoteNotificationSubscriptionStore())
        defer { service.reset() }
        let completed = expectation(description: "Shell result delivered")
        var kinds: [RemoteNotificationKind] = []
        service.configureHostedPushSender(
            serviceURL: { URL(string: "https://example.test")! }, isAvailable: { true }
        ) { event, _, _ in
            kinds.append(event.kind)
            completed.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        register(service, enabledKinds: [.agentQuestion, .turnCompleted])
        service.setMacApplicationActive(false)
        var macPosts: [AttentionAlert] = []
        let observer = AttentionAlertRuntimeObserver(
            appIsActive: { false }, isSnoozed: { _ in false }
        ) { event, action in
            guard event.sessionID == sessionID else { return }
            if case .post(let alert) = action { macPosts.append(alert) }
        }
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: sessionID, event: .turnFinished,
            payload: ["background_tasks": [
                ["id": "test-run", "type": "shell", "status": "running"]
            ]]
        ))

        // The first turn starts the test shell. Two host watch messages then wake Claude,
        // which checks progress and yields again with that same shell still running.
        for turn in 0..<3 {
            terminal.activityTracker.noteTurnStarted()
            runtime.publishRuntimeChange(sessionID: sessionID)
            terminal.activityTracker.noteTurnFinished(backgroundWork: report.backgroundWork)
            runtime.publishRuntimeChange(sessionID: sessionID)
            XCTAssertEqual(terminal.activityTracker.activity, .readyWithBackgroundWork)
            terminal.activityTracker.noteAwaitingUser(.idlePrompt)
            runtime.publishRuntimeChange(sessionID: sessionID)
            let drained = expectation(description: "Watch reply \(turn) drained")
            Task { @MainActor in drained.fulfill() }
            await fulfillment(of: [drained], timeout: 2)
            XCTAssertTrue(kinds.isEmpty, "a running shell has no completed result to push")
            XCTAssertTrue(macPosts.isEmpty, "Mac alerts follow the same pending outcome")
        }

        terminal.activityTracker.noteTurnStarted()
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.noteTurnFinished()
        runtime.publishRuntimeChange(sessionID: sessionID)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(kinds, [.turnCompleted])
        XCTAssertEqual(macPosts, [.unread])
        withExtendedLifetime(observer) {}
    }

    func testSessionDependencyAcrossRepliesNotifiesOnlyAfterNoticeResponse() async throws {
        try await assertSessionDependencyCompletion(delaysReceipt: false)
    }

    func testSessionDependencyReceiptAfterResponseStillNotifiesExactlyOnce() async throws {
        try await assertSessionDependencyCompletion(delaysReceipt: true)
    }

    private func assertSessionDependencyCompletion(delaysReceipt: Bool) async throws {
        let sessionID = try makeSession()
        var watches: SessionWatchCenter?
        var deliveryReceipt: (@MainActor (SessionMessageDelivery.Outcome) -> Void)?
        let runtime = AgentRuntime(
            currentSessionProjection: .projectStore(ProjectStore.shared),
            sessionDependency: { watches?.dependencyState(for: $0) ?? .none }
        )
        let target = SessionID()
        var targetRuntime = SessionRuntimeSnapshot.test(activity: .working)
        watches = SessionWatchCenter(dependencies: .init(
            activity: { _ in targetRuntime.activity },
            runtime: { id in id == target ? targetRuntime : runtime.runtimeSnapshot(sessionID: id) },
            sessionTitle: { _ in "Dependency" },
            deliverNotice: { _, _, completion in
                if delaysReceipt { deliveryReceipt = completion }
                else { completion(.sentNow) }
            },
            dependencyChanged: { runtime.sessionDependencyChanged(sessionID: $0) }
        ))
        defer { watches = nil }
        let terminal = QuestionTerminal()
        terminal.activityTracker.markRunning()
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(terminal, for: sessionID))
        defer { runtime.discard(sessionID: sessionID) }
        let service = RemoteNotificationService(subscriptionStore: InMemoryRemoteNotificationSubscriptionStore())
        defer { service.reset() }
        let completed = expectation(description: "Session result delivered")
        var kinds: [RemoteNotificationKind] = []
        service.configureHostedPushSender(
            serviceURL: { URL(string: "https://example.test")! }, isAvailable: { true }
        ) { event, _, _ in
            kinds.append(event.kind)
            completed.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        register(service, enabledKinds: [.agentQuestion, .turnCompleted])
        service.setMacApplicationActive(false)
        var macPosts: [AttentionAlert] = []
        let observer = AttentionAlertRuntimeObserver(
            appIsActive: { false }, isSnoozed: { _ in false },
            currentSnapshot: { runtime.runtimeSnapshot(sessionID: $0) }
        ) { event, action in
            guard event.sessionID == sessionID else { return }
            if case .post(let alert) = action { macPosts.append(alert) }
        }
        terminal.activityTracker.noteTurnStarted()
        runtime.publishRuntimeChange(sessionID: sessionID)
        XCTAssertEqual(watches?.arm(watcher: sessionID, target: target),
                       .armed(awaiting: .turnSettled, expiresAfter: nil))

        // Neither interim replies nor provider idle reminders finish a host-owned dependency.
        for turn in 0..<3 {
            terminal.activityTracker.noteTurnStarted()
            runtime.publishRuntimeChange(sessionID: sessionID)
            terminal.activityTracker.noteTurnFinished()
            runtime.publishRuntimeChange(sessionID: sessionID)
            XCTAssertEqual(runtime.activity(sessionID: sessionID), .readyWithBackgroundWork)
            XCTAssertEqual(runtime.runtimeSnapshot(sessionID: sessionID).dependency, .awaitingSessionResult)
            terminal.activityTracker.noteAwaitingUser(.idlePrompt)
            runtime.publishRuntimeChange(sessionID: sessionID)
            let drained = expectation(description: "Watch reply \(turn) drained")
            Task { @MainActor in drained.fulfill() }
            await fulfillment(of: [drained], timeout: 2)
            XCTAssertTrue(kinds.isEmpty, "a sibling result is still outstanding")
            XCTAssertTrue(macPosts.isEmpty, "Mac alerts follow the same pending outcome")
        }

        let previous = targetRuntime
        targetRuntime = .test(activity: .idle)
        NotificationCenter.default.post(SessionRuntimeDidChange(
            sessionID: target,
            transition: .init(previous: previous, current: targetRuntime), cause: .turnFinished
        ))
        XCTAssertEqual(runtime.activity(sessionID: sessionID), .readyWithBackgroundWork,
                       "notice delivery is not the agent's response")
        XCTAssertTrue(kinds.isEmpty)

        terminal.activityTracker.noteTurnStarted()
        runtime.publishRuntimeChange(sessionID: sessionID)
        terminal.activityTracker.noteTurnFinished()
        runtime.publishRuntimeChange(sessionID: sessionID)
        if delaysReceipt {
            XCTAssertTrue(kinds.isEmpty, "the response cannot finish before its receipt")
            XCTAssertEqual(runtime.activity(sessionID: sessionID), .readyWithBackgroundWork)
            deliveryReceipt?(.sentNow)
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(kinds, [.turnCompleted])
        XCTAssertEqual(macPosts, [.unread])
        withExtendedLifetime(observer) {}
    }

    func testHostWaitStopAndIdlePromptDoNotWakeSnoozedSession() throws {
        let sessionID = try makeSession()
        let runtime = AgentRuntime(
            currentSessionProjection: .projectStore(ProjectStore.shared),
            sessionDependency: { _ in .awaitingSessionResult }
        )
        let terminal = QuestionTerminal()
        terminal.activityTracker.markRunning()
        terminal.activityTracker.noteTurnStarted()
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(terminal, for: sessionID))
        defer { runtime.discard(sessionID: sessionID) }
        let snooze = SessionSnoozeCenter(
            runtime: { runtime.runtimeSnapshot(sessionID: $0) }
        )
        snooze.snooze(sessionID, until: Date().addingTimeInterval(60))
        defer { snooze.unsnooze(sessionID) }
        runtime.applyLifecycle(try XCTUnwrap(HookLifecycleReport(
            sessionID: sessionID, event: .turnFinished, payload: [:]
        )))
        XCTAssertTrue(snooze.isSnoozed(sessionID), "Stop is not the pending outcome's end")
        runtime.applyLifecycle(try XCTUnwrap(HookLifecycleReport(
            sessionID: sessionID, event: .awaitingUser,
            payload: ["notification_type": "idle_prompt"]
        )))
        XCTAssertTrue(snooze.isSnoozed(sessionID), "an idle reminder does not request input")
        runtime.applyLifecycle(try XCTUnwrap(HookLifecycleReport(
            sessionID: sessionID, event: .awaitingUser,
            payload: ["notification_type": "permission_prompt"]
        )))
        XCTAssertFalse(snooze.isSnoozed(sessionID), "a real permission still wakes the chat")
    }

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

    /// keyvault's Face ID alert goes to the enrolled phone on the grant it enrolled with, nowhere
    /// else, and in fixed words: the request itself is read inside the app.
    func testAFaceIDApprovalAlertReachesOnlyTheEnrolledPhoneAndSaysNothingOfTheRequest() async throws {
        let service = RemoteNotificationService(subscriptionStore: InMemoryRemoteNotificationSubscriptionStore())
        let sent = expectation(description: "Hosted alert sent")
        var delivered: [RemoteNotificationEventDTO] = []
        service.configureHostedPushSender(
            serviceURL: { URL(string: "https://example.test")! }, isAvailable: { true }
        ) { event, _, _ in
            delivered.append(event)
            sent.fulfill()
            return .init(statusCode: 200, reason: "Accepted", apnsID: nil)
        }
        register(service, enabledKinds: [.secretApproval])
        XCTAssertEqual(service.secretApprovalRequested(requestID: UUID(), shareID: "someone-else", deviceID: "phone"), 0,
                       "another grant on the same phone is not the enrolled one")
        XCTAssertEqual(service.secretApprovalRequested(requestID: UUID(), shareID: "owner", deviceID: "other-phone"), 0,
                       "another phone is not the enrolled one")
        let id = UUID()
        XCTAssertEqual(service.secretApprovalRequested(requestID: id, shareID: "owner", deviceID: "phone"), 1)
        await fulfillment(of: [sent], timeout: 2)
        let event = try XCTUnwrap(delivered.first)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(event.kind, .secretApproval)
        XCTAssertEqual(event.id, id.uuidString.lowercased())
        XCTAssertEqual(event.sessionID, RemoteNotificationKind.secretApprovalThread)
        XCTAssertEqual(event.title, "Face ID approval waiting")
        XCTAssertEqual(event.titleLocalization?.key, "Face ID approval waiting")
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
