import XCTest
@testable import Threading

@MainActor
final class ActiveTurnSleepInhibitorTests: XCTestCase {
    private final class Assertion: IdleSystemSleepAsserting {
        var acquireCount = 0
        var releaseCount = 0
        var acquireSucceeds = true
        var releaseSucceeds = true

        func acquire() -> Bool {
            acquireCount += 1
            return acquireSucceeds
        }

        func release() -> Bool {
            releaseCount += 1
            return releaseSucceeds
        }
    }

    private final class Fixture {
        let center = NotificationCenter()
        let assertion = Assertion()
        var enabled = false
        var activities: [SessionID: SessionActivity] = [:]

        lazy var inhibitor = ActiveTurnSleepInhibitor(
            center: center,
            currentInFlightSessionIDs: { [unowned self] in
                Set(activities.compactMap { $0.value.hasTurnInFlight ? $0.key : nil })
            },
            activity: { [unowned self] in activities[$0] ?? .dormant },
            isEnabled: { [unowned self] in enabled },
            assertion: assertion
        )

        func report(_ activity: SessionActivity, for sessionID: SessionID) {
            activities[sessionID] = activity
            center.post(SessionActivityDidChange(sessionID: sessionID))
        }
    }

    func testSettingDefaultsOffAndPersistsAnExplicitChoice() throws {
        let suite = "ActiveTurnSleepInhibitorTests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.preventsIdleSystemSleepWhileAgentsWork)
        settings.preventsIdleSystemSleepWhileAgentsWork = true
        XCTAssertTrue(settings.preventsIdleSystemSleepWhileAgentsWork)
    }

    func testDisabledPreferenceNeverAcquiresForAnActiveTurn() {
        let fixture = Fixture()
        fixture.inhibitor.start()

        fixture.report(.working, for: SessionID())

        XCTAssertEqual(fixture.assertion.acquireCount, 0)
        XCTAssertEqual(fixture.assertion.releaseCount, 0)
    }

    func testEnablingDuringAnActiveTurnAcquiresImmediately() {
        let fixture = Fixture()
        let sessionID = SessionID()
        fixture.report(.working, for: sessionID)
        fixture.inhibitor.start()

        fixture.enabled = true
        fixture.center.post(AppSettingsDidChange())

        XCTAssertEqual(fixture.assertion.acquireCount, 1)
        XCTAssertEqual(fixture.assertion.releaseCount, 0)
    }

    func testOneAssertionSpansConcurrentTurnsUntilTheLastOneFinishes() {
        let fixture = Fixture()
        fixture.enabled = true
        fixture.inhibitor.start()
        let first = SessionID()
        let second = SessionID()

        fixture.report(.working, for: first)
        fixture.report(.awaitingUser, for: second)
        fixture.report(.idle, for: first)

        XCTAssertEqual(fixture.assertion.acquireCount, 1)
        XCTAssertEqual(fixture.assertion.releaseCount, 0)

        fixture.report(.needsAttention, for: second)

        XCTAssertEqual(fixture.assertion.acquireCount, 1)
        XCTAssertEqual(fixture.assertion.releaseCount, 1)
    }

    func testTurningThePreferenceOffReleasesAndTurningItBackOnReacquires() {
        let fixture = Fixture()
        fixture.enabled = true
        fixture.activities[SessionID()] = .working
        fixture.inhibitor.start()

        fixture.enabled = false
        fixture.center.post(AppSettingsDidChange())
        fixture.enabled = true
        fixture.center.post(AppSettingsDidChange())

        XCTAssertEqual(fixture.assertion.acquireCount, 2)
        XCTAssertEqual(fixture.assertion.releaseCount, 1)
    }

    func testSessionEndAndStopBothReleaseWithoutDuplicateCalls() {
        let fixture = Fixture()
        fixture.enabled = true
        fixture.inhibitor.start()
        let sessionID = SessionID()
        fixture.report(.working, for: sessionID)

        fixture.center.post(TerminalSessionDidEnd(sessionID: sessionID))
        fixture.inhibitor.stop()

        XCTAssertEqual(fixture.assertion.acquireCount, 1)
        XCTAssertEqual(fixture.assertion.releaseCount, 1)
    }

    func testFailedAcquireRetriesOnTheNextRelevantEdge() {
        let fixture = Fixture()
        fixture.enabled = true
        fixture.assertion.acquireSucceeds = false
        fixture.inhibitor.start()
        let sessionID = SessionID()

        fixture.report(.working, for: sessionID)
        fixture.assertion.acquireSucceeds = true
        fixture.report(.awaitingUser, for: sessionID)

        XCTAssertEqual(fixture.assertion.acquireCount, 2)
        XCTAssertEqual(fixture.assertion.releaseCount, 0)
    }
}
