import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class RemoteResponseNotificationCoordinatorTests: XCTestCase {
    func testBrowserAndNativePermissionLifetimesDoNotReplaceOrResolveEachOther() {
        let h = Harness()
        let native = h.event(id: "native", kind: .permissionRequest)
        let browser = h.event(id: "browser", kind: .permissionRequest)
        h.coordinator.requested(native, targets: [h.owner])
        h.coordinator.requested(browser, targets: [h.owner], scope: .browser)
        XCTAssertEqual(h.coordinator.count, 2)
        XCTAssertTrue(h.coordinator.canSend(native, to: h.owner))
        XCTAssertTrue(h.coordinator.canSend(browser, to: h.owner))
        h.coordinator.resolve(sessionID: "session", kind: .permissionRequest, scope: .session)
        XCTAssertEqual(h.coordinator.count, 1)
        XCTAssertTrue(h.coordinator.canSend(browser, to: h.owner))
        h.coordinator.resolve(sessionID: "session", kind: .permissionRequest, scope: .browser)
        XCTAssertEqual(h.coordinator.count, 0)
    }

    func testActiveMacDefersBothKindsAndAnswerCancelsEvenRacingTimer() {
        for kind in [RemoteNotificationKind.agentQuestion, .permissionRequest] {
            let h = Harness()
            h.activity.recordMacInteraction(at: 10)
            h.coordinator.requested(h.event(kind: kind), targets: [h.owner])
            XCTAssertTrue(h.pushes.isEmpty)
            XCTAssertEqual(h.liveCount, 0, "A background live-only phone must also stay quiet")
            h.coordinator.resolve(sessionID: "session", kind: kind)
            h.advance(to: 200, includingCancelled: true)
            XCTAssertTrue(h.pushes.isEmpty)
            XCTAssertEqual(h.retractions.first?.0.kind, kind)
            XCTAssertEqual(h.retractions.first?.1, false)
        }
    }

    func testContinuedMacUseExtendsUnansweredQuestionUntilInactivity() {
        let h = Harness()
        h.activity.recordMacInteraction(at: 10)
        h.coordinator.requested(h.event(), targets: [h.owner])
        h.activity.recordMacInteraction(at: 60)
        h.advance(to: 70)
        XCTAssertTrue(h.pushes.isEmpty)
        h.advance(to: 120)
        XCTAssertEqual(h.pushes.count, 1)
    }

    func testLeavingMacSendsUnansweredQuestionButMacDoesNotSuppressGuest() {
        let h = Harness()
        h.activity.recordMacInteraction(at: 10)
        h.coordinator.requested(h.event(), targets: [h.owner, h.guest])
        XCTAssertEqual(h.pushes.map(\.deviceID), ["guest-phone"])
        h.activity.setMacApplicationActive(false)
        h.coordinator.presenceChanged()
        XCTAssertEqual(h.pushes.count, 2)
    }

    func testForegroundPhoneDefersUntilItsLastConnectionLeaves() {
        let h = Harness()
        for _ in 0..<2 {
            h.activity.attachForegroundDevice(participantID: .owner, deviceID: "phone")
        }
        h.coordinator.requested(h.event(), targets: [h.owner])
        XCTAssertEqual(h.liveCount, 1)
        h.activity.detachForegroundDevice(participantID: .owner, deviceID: "phone")
        h.coordinator.presenceChanged()
        XCTAssertTrue(h.pushes.isEmpty)
        h.activity.detachForegroundDevice(participantID: .owner, deviceID: "phone")
        h.coordinator.presenceChanged()
        XCTAssertEqual(h.pushes.count, 1)
    }

    func testAcceptedPushRetractsOnResolutionAndLateAcceptanceAlsoRetracts() {
        for resolvesBeforeAcceptance in [false, true] {
            let h = Harness()
            h.coordinator.requested(h.event(), targets: [h.owner])
            if resolvesBeforeAcceptance { h.coordinator.resolve(sessionID: "session") }
            h.completions[0](.init(accepted: true, statusCode: 200, providerTrace: nil))
            if !resolvesBeforeAcceptance { h.coordinator.resolve(sessionID: "session") }
            XCTAssertEqual(h.retractions.filter { $0.1 }.count, 1)
            XCTAssertEqual(h.retractions.last?.0.eventID, "event")
            XCTAssertFalse(h.coordinator.canSend(h.event(), to: h.owner))
        }
    }

    func testResolutionDoesNotClearAnotherSessionOrNewRequest() {
        let h = Harness()
        h.coordinator.requested(h.event(), targets: [h.owner])
        h.coordinator.requested(h.event(id: "other", session: "other"), targets: [h.owner])
        h.coordinator.requested(h.event(id: "replacement"), targets: [h.owner])
        h.completions[0](.init(accepted: true, statusCode: 200, providerTrace: nil))
        XCTAssertEqual(h.retractions.last?.0.eventID, "event")
        XCTAssertTrue(h.coordinator.canSend(h.event(id: "replacement"), to: h.owner))
        XCTAssertTrue(h.coordinator.canSend(h.event(id: "other", session: "other"), to: h.owner))
    }

    func testConsentRevocationAtDeadlineAndOffPreference() {
        let h = Harness()
        h.activity.recordMacInteraction(at: 10)
        h.coordinator.requested(h.event(), targets: [h.owner])
        h.authorized = false
        h.advance(to: 100)
        XCTAssertTrue(h.pushes.isEmpty)
        XCTAssertEqual(h.coordinator.count, 0)
        let off = Harness(window: 0)
        off.activity.recordMacInteraction(at: 10)
        off.coordinator.requested(off.event(), targets: [off.owner])
        XCTAssertEqual(off.pushes.count, 1)
    }

    func testTransientRefusalRetriesSameRequestWithBoundedBackoff() {
        let h = Harness()
        h.coordinator.requested(h.event(), targets: [h.owner])
        for (index, delay) in RemoteResponseNotificationCoordinator.retryDelays.enumerated() {
            h.completions[index](.init(accepted: false, statusCode: 503, providerTrace: nil))
            h.coordinator.presenceChanged()
            XCTAssertEqual(h.pushes.count, index + 1, "Presence must not bypass backoff")
            h.advance(to: h.clock.uptime + delay)
            XCTAssertEqual(h.pushes.count, index + 2)
        }
        h.completions.last?(.init(accepted: false, statusCode: 503, providerTrace: nil))
        h.advance(to: 1_000)
        XCTAssertEqual(h.pushes.count, 4)
        h.coordinator.transportChanged()
        XCTAssertEqual(h.pushes.count, 5, "A refreshed registration/provider can recover refusal")
    }

    func testAnswerDuringRetryAndPermanentRefusalNeverBlindlyResend() {
        for status in [400, 503] {
            let h = Harness()
            h.coordinator.requested(h.event(), targets: [h.owner])
            h.completions[0](.init(accepted: false, statusCode: status, providerTrace: nil))
            if status == 503 { h.coordinator.resolve(sessionID: "session") }
            h.advance(to: 1_000, includingCancelled: true)
            XCTAssertEqual(h.pushes.count, 1)
        }
    }

    func testAcceptedUnansweredQuestionStillRetractsAfterPresenceChangedInFlight() {
        let h = Harness()
        h.coordinator.requested(h.event(), targets: [h.owner])
        h.activity.recordMacInteraction(at: 10)
        h.completions[0](.init(accepted: true, statusCode: 200, providerTrace: nil))
        XCTAssertTrue(h.retractions.isEmpty, "Returning is not an answer")
        h.coordinator.resolve(sessionID: "session")
        XCTAssertEqual(h.retractions.filter { $0.1 }.count, 1)
    }

    func testStressBoundsRequestDevicePairsAndResetCancelsTimers() {
        let h = Harness()
        h.activity.recordMacInteraction(at: 10)
        for index in 0..<1_000 {
            h.coordinator.requested(h.event(id: "e-\(index)", session: "s-\(index)"), targets: [h.owner])
        }
        XCTAssertEqual(h.coordinator.count, RemoteResponseNotificationCoordinator.maximumEntries)
        XCTAssertEqual(h.scheduler.tasks.count, RemoteResponseNotificationCoordinator.maximumEntries)
        h.coordinator.reset()
        h.advance(to: 500, includingCancelled: true)
        XCTAssertTrue(h.pushes.isEmpty)
    }
}

@MainActor
private final class Harness {
    let clock = ResponseClock()
    let scheduler = ResponseScheduler()
    let activity: RemoteNotificationParticipantActivitySource
    let owner = RemoteResponseNotificationCoordinator.Target(shareID: "owner", deviceID: "phone", participantID: .owner)
    let guest = RemoteResponseNotificationCoordinator.Target(shareID: "guest", deviceID: "guest-phone", participantID: .member("guest"))
    var authorized = true
    var liveCount = 0
    var pushes: [RemoteResponseNotificationCoordinator.Target] = []
    var completions: [@MainActor (RemoteNotificationPushResult) -> Void] = []
    var retractions: [(RemoteNotificationRetractionDTO, Bool)] = []
    lazy var coordinator = RemoteResponseNotificationCoordinator(
        clock: clock, scheduler: scheduler, activity: activity,
        isAuthorized: { [weak self] _, _ in self?.authorized == true },
        liveSink: { [weak self] _, _ in self?.liveCount += 1 },
        pushSink: { [weak self] _, target, completion in
            self?.pushes.append(target)
            self?.completions.append(completion)
        },
        retractionSink: { [weak self] event, _, background in self?.retractions.append((event, background)) }
    )
    init(window: TimeInterval = 60) {
        activity = RemoteNotificationParticipantActivitySource { window }
    }
    func event(id: String = "event", session: String = "session", kind: RemoteNotificationKind = .agentQuestion) -> RemoteNotificationEventDTO {
        .init(id: id, kind: kind, hostID: "host", sessionID: session, title: "Chat", body: "Respond")
    }
    func advance(to now: TimeInterval, includingCancelled: Bool = false) {
        clock.uptime = now
        scheduler.now = now
        let due = scheduler.tasks.filter { $0.deadline <= now && (includingCancelled || !$0.cancelled) }
        for task in due { task.cancel(); task.action() }
    }
}

private final class ResponseClock: RemoteTurnNotificationClock {
    var uptime: TimeInterval = 10
}

@MainActor
private final class ResponseScheduler: RemoteTurnNotificationScheduling {
    final class Scheduled: RemoteTurnNotificationScheduledTask {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
        func cancel() { cancelled = true }
    }
    var now: TimeInterval = 10
    var tasks: [Scheduled] = []
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any RemoteTurnNotificationScheduledTask {
        let task = Scheduled(deadline: now + delay, action: action)
        tasks.append(task)
        return task
    }
}
