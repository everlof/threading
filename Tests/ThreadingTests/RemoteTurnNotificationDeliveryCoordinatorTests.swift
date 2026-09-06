import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class RemoteTurnNotificationDeliveryCoordinatorTests: XCTestCase {
    func testLocalAPNSRetractionSharesCompletionCollapseIdentifier() {
        let event = RemoteNotificationEventDTO(
            id: "event-1",
            kind: .turnCompleted,
            hostID: "host-1",
            sessionID: "session-1",
            title: "Chat",
            body: "Finished its turn."
        )
        let retraction = RemoteNotificationRetractionDTO(
            hostID: event.hostID,
            sessionID: event.sessionID,
            eventID: event.id,
            kind: event.kind
        )

        XCTAssertEqual(
            RemoteAPNSPushSender.collapseIdentifier(for: event),
            RemoteAPNSPushSender.collapseIdentifier(for: retraction)
        )
    }

    func testOffSendsImmediatelyAndEveryConfiguredWindowWaitsForItsDeadline() {
        let sessionID = SessionID()

        let off = Harness(window: 0, sessionID: sessionID)
        off.activity.setMacApplicationActive(true)
        off.activity.recordMacInteraction(at: 100)
        off.coordinator.completed(off.completion())
        XCTAssertEqual(off.pushes.count, 1)
        XCTAssertEqual(off.coordinator.pendingCount, 0)

        off.coordinator.macInteracted(at: 101)
        off.scheduler.fireAllIncludingCancelled()
        XCTAssertTrue(off.retractions.isEmpty)

        for seconds in [60.0, 120.0, 300.0, 600.0] {
            let harness = Harness(window: seconds, sessionID: sessionID)
            harness.clock.uptime = 100
            harness.scheduler.setNow(100)
            harness.activity.setMacApplicationActive(true)
            harness.activity.recordMacInteraction(at: 100)
            harness.coordinator.completed(harness.completion())
            XCTAssertTrue(harness.pushes.isEmpty)
            XCTAssertEqual(harness.coordinator.pendingCount, 1)

            harness.clock.uptime = 100 + seconds - 0.001
            harness.scheduler.fireDue(now: harness.clock.uptime)
            XCTAssertTrue(harness.pushes.isEmpty)
            XCTAssertEqual(harness.coordinator.pendingCount, 1)

            harness.clock.uptime = 100 + seconds
            harness.scheduler.fireDue(now: harness.clock.uptime)
            XCTAssertEqual(harness.pushes.count, 1, "window \(seconds)")
            XCTAssertEqual(harness.coordinator.pendingCount, 0)
        }
    }

    func testForegroundPhoneGetsLiveEventWithoutLaterPush() {
        let harness = Harness(window: 0)
        harness.coordinator.foregroundDeviceAttached(
            participantID: .owner,
            deviceID: "phone-1"
        )
        harness.coordinator.completed(harness.completion())

        XCTAssertEqual(harness.liveEvents.count, 1)
        XCTAssertTrue(harness.pushes.isEmpty)

        harness.coordinator.foregroundDeviceDetached(
            participantID: .owner,
            deviceID: "phone-1"
        )
        harness.coordinator.completed(harness.completion(eventID: "event-2"))
        XCTAssertEqual(harness.pushes.count, 1)
    }

    func testFollowUpAndNewTurnInvalidateDeferredCompletionDespiteTimerRace() {
        let interaction = Harness(window: 120)
        interaction.activity.setMacApplicationActive(true)
        interaction.activity.recordMacInteraction(at: 10)
        interaction.coordinator.completed(interaction.completion())
        interaction.coordinator.participantInteracted(.owner, source: "followUp")
        interaction.scheduler.fireAllIncludingCancelled()
        XCTAssertTrue(interaction.pushes.isEmpty)

        let newTurn = Harness(window: 120)
        newTurn.activity.setMacApplicationActive(true)
        newTurn.activity.recordMacInteraction(at: 10)
        newTurn.coordinator.completed(newTurn.completion())
        newTurn.generation = 2
        newTurn.coordinator.turnStarted(sessionID: newTurn.sessionID, generation: 2)
        newTurn.scheduler.fireAllIncludingCancelled()
        XCTAssertTrue(newTurn.pushes.isEmpty)
    }

    func testMacInputBurstCoalescesQueueWork() {
        let harness = Harness(window: 120)

        for offset in 0..<240 {
            harness.coordinator.macInteracted(at: 10 + Double(offset) / 240)
        }

        XCTAssertEqual(harness.scheduler.activeTaskCount, 1)
        XCTAssertEqual(
            harness.activity.activeReason(for: .owner, nowUptime: 11),
            .mac
        )
    }

    func testPreviewConsentIsIndependentForEachDevice() {
        let preview = RemoteTurnNotificationTarget(
            shareID: "owner", deviceID: "phone-preview", participantID: .owner,
            includesResponsePreviews: true, supportsRetraction: true
        )
        let generic = RemoteTurnNotificationTarget(
            shareID: "owner", deviceID: "phone-generic", participantID: .owner,
            includesResponsePreviews: false, supportsRetraction: false
        )
        let harness = Harness(window: 0, targets: [preview, generic])
        harness.coordinator.completed(harness.completion(text: "# Done\n\nEverything is ready."))

        let byDevice = Dictionary(uniqueKeysWithValues: harness.pushes.map {
            ($0.target.deviceID, $0.event)
        })
        XCTAssertEqual(byDevice["phone-preview"]?.body, "Done")
        XCTAssertNil(byDevice["phone-preview"]?.bodyLocalization)
        XCTAssertEqual(byDevice["phone-generic"]?.body, "Finished its turn.")
        XCTAssertEqual(byDevice["phone-generic"]?.bodyLocalization?.key, "Finished its turn.")
    }

    func testConsentedDeviceUsesGenericBodyWithoutAReliableSnapshot() {
        let target = RemoteTurnNotificationTarget(
            shareID: "owner", deviceID: "phone-1", participantID: .owner,
            includesResponsePreviews: true, supportsRetraction: true
        )
        let harness = Harness(window: 0, targets: [target])

        harness.coordinator.completed(harness.completion(text: nil))

        XCTAssertEqual(harness.pushes.first?.event.body, "Finished its turn.")
        XCTAssertEqual(
            harness.pushes.first?.event.bodyLocalization?.key,
            "Finished its turn."
        )
    }

    func testMacActivityAffectsOnlyOwnerWhileGuestSendsImmediately() {
        let owner = RemoteTurnNotificationTarget(
            shareID: "owner", deviceID: "owner-phone", participantID: .owner,
            includesResponsePreviews: false, supportsRetraction: true
        )
        let guestID = RemoteNotificationParticipantID.member("guest-1")
        let guest = RemoteTurnNotificationTarget(
            shareID: "guest-1", deviceID: "guest-phone", participantID: guestID,
            includesResponsePreviews: false, supportsRetraction: true
        )
        let harness = Harness(window: 120, targets: [owner, guest])
        harness.activity.setMacApplicationActive(true)
        harness.activity.recordMacInteraction(at: harness.clock.uptime)

        harness.coordinator.completed(harness.completion(participantID: .owner))
        harness.coordinator.completed(harness.completion(
            eventID: "guest-event",
            participantID: guestID
        ))

        XCTAssertEqual(harness.coordinator.pendingCount, 1)
        XCTAssertEqual(harness.pushes.map(\.target.deviceID), ["guest-phone"])
    }

    func testParticipantInteractionInvalidatesThatParticipantsPendingWorkAcrossSessions() {
        let harness = Harness(window: 120)
        let secondSessionID = SessionID()
        harness.activity.setMacApplicationActive(true)
        harness.activity.recordMacInteraction(at: harness.clock.uptime)
        harness.coordinator.completed(harness.completion())
        harness.coordinator.completed(harness.completion(
            eventID: "event-2",
            sessionID: secondSessionID
        ))
        XCTAssertEqual(harness.coordinator.pendingCount, 2)

        harness.coordinator.participantInteracted(.owner, source: "followUp")
        harness.scheduler.fireAllIncludingCancelled()

        XCTAssertEqual(harness.coordinator.pendingCount, 0)
        XCTAssertTrue(harness.pushes.isEmpty)
    }

    func testAuthorizationRevocationAtDeadlinePreventsDelivery() {
        let harness = Harness(window: 120)
        harness.activity.setMacApplicationActive(true)
        harness.activity.recordMacInteraction(at: harness.clock.uptime)
        harness.coordinator.completed(harness.completion())
        harness.targets.removeAll()

        harness.clock.uptime += 120
        harness.scheduler.fireDue(now: harness.clock.uptime)

        XCTAssertTrue(harness.pushes.isEmpty)
        XCTAssertEqual(harness.coordinator.pendingCount, 0)
    }

    func testPendingQueueRefusesWorkBeyondItsBound() {
        let harness = Harness(window: 120)
        harness.activity.setMacApplicationActive(true)
        harness.activity.recordMacInteraction(at: harness.clock.uptime)

        for index in 0...RemoteTurnNotificationDeliveryCoordinator.maximumPendingCompletions {
            harness.coordinator.completed(harness.completion(
                eventID: "event-\(index)",
                sessionID: SessionID()
            ))
        }

        XCTAssertEqual(
            harness.coordinator.pendingCount,
            RemoteTurnNotificationDeliveryCoordinator.maximumPendingCompletions
        )
        XCTAssertTrue(harness.diagnostics.contains {
            $0.fields[.phase] == "refused" && $0.fields[.reason] == "queueBound"
        })
    }

    func testAcceptedPushIsRetractedAfterInteractionOnlyForCapableDevice() {
        let capable = RemoteTurnNotificationTarget(
            shareID: "owner", deviceID: "phone-1", participantID: .owner,
            includesResponsePreviews: false, supportsRetraction: true
        )
        let harness = Harness(window: 0, targets: [capable])
        harness.coordinator.completed(harness.completion())
        XCTAssertEqual(harness.coordinator.acceptedDeliveryCount, 1)

        harness.coordinator.participantInteracted(.owner, source: "phone")

        XCTAssertEqual(harness.retractions.count, 1)
        XCTAssertEqual(harness.retractions.first?.value.eventID, "event-1")
        XCTAssertTrue(harness.retractions.first?.live == true)
        XCTAssertTrue(harness.retractions.first?.background == true)
    }

    func testPreviewPreferenceChangeDoesNotMakeAcceptedPushUnretractable() {
        let original = RemoteTurnNotificationTarget(
            shareID: "owner", deviceID: "phone-1", participantID: .owner,
            includesResponsePreviews: true, supportsRetraction: true
        )
        let harness = Harness(window: 0, targets: [original])
        harness.coordinator.completed(harness.completion(text: "Sensitive result"))

        harness.targets = [RemoteTurnNotificationTarget(
            shareID: "owner", deviceID: "phone-1", participantID: .owner,
            includesResponsePreviews: false, supportsRetraction: true
        )]
        harness.coordinator.participantInteracted(.owner, source: "phone")

        XCTAssertEqual(harness.retractions.map(\.value.eventID), ["event-1"])
    }

    func testInteractionCanRetractAfterTargetDisablesTurnCompletions() {
        let harness = Harness(window: 0)
        harness.coordinator.completed(harness.completion())
        let disabled = RemoteTurnNotificationTarget(
            shareID: "owner",
            deviceID: "phone-1",
            participantID: .owner,
            isTurnCompletionEnabled: false,
            includesResponsePreviews: false,
            supportsRetraction: true
        )
        harness.targets = [disabled]

        harness.coordinator.participantInteracted(.owner, source: "phone")

        XCTAssertEqual(harness.retractions.map(\.value.eventID), ["event-1"])
    }

    func testDisabledTargetDoesNotReceiveLiveOrPushDelivery() {
        let disabled = RemoteTurnNotificationTarget(
            shareID: "owner",
            deviceID: "phone-1",
            participantID: .owner,
            isTurnCompletionEnabled: false,
            includesResponsePreviews: false,
            supportsRetraction: true
        )
        let harness = Harness(window: 0, targets: [disabled])

        harness.coordinator.completed(harness.completion())

        XCTAssertTrue(harness.liveEvents.isEmpty)
        XCTAssertTrue(harness.pushes.isEmpty)
    }

    func testExpiredAcceptedPushIsNotRetracted() {
        let harness = Harness(window: 0)
        harness.coordinator.completed(harness.completion())
        XCTAssertEqual(harness.coordinator.acceptedDeliveryCount, 1)

        harness.clock.uptime +=
            RemoteTurnNotificationDeliveryCoordinator.acceptedDeliveryLifetime + 1
        harness.coordinator.participantInteracted(.owner, source: "phone")

        XCTAssertEqual(harness.coordinator.acceptedDeliveryCount, 0)
        XCTAssertTrue(harness.retractions.isEmpty)
    }

    func testNewTurnAlsoPrunesExpiredAcceptedPush() {
        let harness = Harness(window: 0)
        harness.coordinator.completed(harness.completion())

        harness.clock.uptime +=
            RemoteTurnNotificationDeliveryCoordinator.acceptedDeliveryLifetime + 1
        harness.generation = 2
        harness.coordinator.turnStarted(sessionID: harness.sessionID, generation: 2)

        XCTAssertEqual(harness.coordinator.acceptedDeliveryCount, 0)
        XCTAssertTrue(harness.retractions.isEmpty)
    }

    func testInteractionWhilePushIsInFlightRetractsALateAcceptedDelivery() {
        let harness = Harness(window: 0)
        harness.completesPushesImmediately = false

        harness.coordinator.completed(harness.completion())
        harness.coordinator.participantInteracted(.owner, source: "followUp")

        XCTAssertEqual(harness.coordinator.acceptedDeliveryCount, 0)
        XCTAssertTrue(harness.retractions.isEmpty)

        harness.finishPendingPushes()

        XCTAssertEqual(harness.coordinator.acceptedDeliveryCount, 1)
        XCTAssertEqual(harness.retractions.map(\.value.eventID), ["event-1"])
    }

    func testBrokerRejectionKeepsHTTPStatusAndMachineCodeInDiagnostics() {
        let harness = Harness(window: 0)
        harness.completesPushesImmediately = false
        harness.coordinator.completed(harness.completion())

        harness.finishPendingPushes(with: .init(
            accepted: false,
            statusCode: 400,
            providerTrace: nil,
            failureCode: "invalidRequest"
        ))

        let refused = harness.diagnostics.last { $0.fields[.result] == "refused" }
        XCTAssertEqual(refused?.fields[.status], "400")
        XCTAssertEqual(refused?.fields[.code], "invalidRequest")
    }

    func testDiagnosticBoundaryContainsNoSnapshotOrNotificationBody() {
        let secret = "prompt assistant token device-token preview-body"
        let harness = Harness(window: 0)
        harness.coordinator.completed(harness.completion(text: secret))

        XCTAssertFalse(harness.diagnostics.isEmpty)
        for diagnostic in harness.diagnostics {
            XCTAssertFalse(diagnostic.fields.values.contains(secret))
            XCTAssertFalse(String(describing: diagnostic.context).contains(secret))
        }
    }
}

@MainActor
private final class Harness {
    struct Push { let event: RemoteNotificationEventDTO; let target: RemoteTurnNotificationTarget }
    struct Retraction {
        let value: RemoteNotificationRetractionDTO
        let live: Bool
        let background: Bool
    }
    struct Diagnostic {
        let context: RemoteTurnNotificationDiagnosticContext
        let fields: [RemoteDiagnosticField: String]
    }

    let sessionID: SessionID
    let clock = TestClock()
    let scheduler = TestScheduler()
    let activity: RemoteNotificationParticipantActivitySource
    var generation: UInt64 = 1
    var targets: [RemoteTurnNotificationTarget]
    var pushes: [Push] = []
    var liveEvents: [RemoteNotificationEventDTO] = []
    var retractions: [Retraction] = []
    var diagnostics: [Diagnostic] = []
    var completesPushesImmediately = true
    var pendingPushCompletions: [@MainActor (RemoteTurnNotificationPushResult) -> Void] = []
    lazy var coordinator = RemoteTurnNotificationDeliveryCoordinator(
        clock: clock,
        scheduler: scheduler,
        activity: activity,
        targetSource: { [unowned self] _, participantID in
            return self.targets.filter { $0.participantID == participantID }
        },
        generationSource: { [unowned self] _ in
            self.generation
        },
        liveSink: { [unowned self] event, _ in
            self.liveEvents.append(event)
            return 1
        },
        pushSink: { [unowned self] event, target, completion in
            self.pushes.append(Push(event: event, target: target))
            let result = RemoteTurnNotificationPushResult(
                accepted: true,
                statusCode: 200,
                providerTrace: "apns-1"
            )
            if self.completesPushesImmediately {
                completion(result)
            } else {
                self.pendingPushCompletions.append(completion)
            }
        },
        retractionSink: { [unowned self] value, _, live, background in
            self.retractions.append(.init(value: value, live: live, background: background))
        },
        diagnosticSink: { [unowned self] _, context, _, fields in
            self.diagnostics.append(.init(context: context, fields: fields))
        }
    )

    init(
        window: TimeInterval,
        sessionID: SessionID = SessionID(),
        targets: [RemoteTurnNotificationTarget]? = nil
    ) {
        self.sessionID = sessionID
        self.targets = targets ?? [RemoteTurnNotificationTarget(
            shareID: "owner", deviceID: "phone-1", participantID: .owner,
            includesResponsePreviews: false, supportsRetraction: true
        )]
        activity = RemoteNotificationParticipantActivitySource { window }
    }

    func finishPendingPushes(
        with result: RemoteTurnNotificationPushResult = .init(
            accepted: true,
            statusCode: 200,
            providerTrace: "apns-1"
        )
    ) {
        let completions = pendingPushCompletions
        pendingPushCompletions.removeAll()
        completions.forEach { $0(result) }
    }

    func completion(
        eventID: String = "event-1",
        sessionID: SessionID? = nil,
        participantID: RemoteNotificationParticipantID = .owner,
        text: String? = nil
    ) -> RemoteTurnNotificationCompletion {
        let sessionID = sessionID ?? self.sessionID
        return RemoteTurnNotificationCompletion(
            eventID: eventID,
            hostID: "host-1",
            sessionID: sessionID,
            participantID: participantID,
            generation: generation,
            title: "Chat",
            snapshot: .init(
                sessionID: sessionID,
                generation: generation,
                finalAssistantText: text
            ),
            createdAt: clock.wallTime.timeIntervalSince1970
        )
    }
}

private final class TestClock: RemoteTurnNotificationClock {
    var wallTime = Date(timeIntervalSince1970: 1_000)
    var uptime: TimeInterval = 10
}

@MainActor
private final class TestScheduler: RemoteTurnNotificationScheduling {
    final class Scheduled: RemoteTurnNotificationScheduledTask {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false

        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    private var now: TimeInterval = 10
    private var tasks: [Scheduled] = []

    var activeTaskCount: Int { tasks.lazy.filter { !$0.isCancelled }.count }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any RemoteTurnNotificationScheduledTask {
        let task = Scheduled(deadline: now + delay, action: action)
        tasks.append(task)
        return task
    }

    func setNow(_ now: TimeInterval) {
        self.now = now
    }

    func fireDue(now: TimeInterval) {
        self.now = now
        for task in tasks where task.deadline <= now && !task.isCancelled {
            task.isCancelled = true
            task.action()
        }
    }

    func fireAllIncludingCancelled() {
        let actions = tasks.map(\.action)
        tasks.removeAll()
        actions.forEach { $0() }
    }
}

final class TurnCompletionPreviewFormatterTests: XCTestCase {
    func testSelectsFirstUsefulParagraphAndRemovesMarkdownAndUnsafeFormatting() {
        XCTAssertEqual(
            TurnCompletionPreviewFormatter.preview(
                from: "```swift\nlet secret = true\n```\n\n## **Ready** [now](https://example.test)\u{202E}\n\nLater"
            ),
            "Ready now"
        )
        XCTAssertEqual(
            TurnCompletionPreviewFormatter.preview(from: "*Ready* with _details_"),
            "Ready with details"
        )
    }

    func testTruncatesAtAWordBoundaryWithin320UTF8Bytes() {
        let preview = TurnCompletionPreviewFormatter.preview(
            from: Array(repeating: "återställd", count: 80).joined(separator: " ")
        )
        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(preview?.utf8.count ?? .max, 320)
        XCTAssertTrue(preview?.hasSuffix("…") == true)
    }

    func testControlOnlyAndUnavailableTextFallBackToNil() {
        XCTAssertNil(TurnCompletionPreviewFormatter.preview(from: nil))
        XCTAssertNil(TurnCompletionPreviewFormatter.preview(from: "\u{0000}\u{0007}"))
        XCTAssertNil(TurnCompletionPreviewFormatter.preview(from: "```swift\nlet value = 1\n```"))
    }

    func testEmojiPreviewRespectsTheUTF8ByteLimit() {
        let preview = TurnCompletionPreviewFormatter.preview(
            from: Array(repeating: "ready 🚀", count: 80).joined(separator: " ")
        )
        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(preview?.utf8.count ?? .max, 320)
        XCTAssertTrue(preview?.hasSuffix("…") == true)
    }
}
