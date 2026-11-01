import ThreadingGlanceKit
import ThreadingRemoteKit
import XCTest

@testable import ThreadingMobile

/// The phone's half of Mirror's promise: turning it on at the Mac asks nothing, and a phone being
/// used is never taken over.
@MainActor
final class MobileMirrorPolicyTests: XCTestCase {
    private func context(
        enabled: Bool = true,
        active: Bool = true,
        showing: Bool = false,
        awaiting: Bool = false,
        age: TimeInterval = 0,
        rejoin: Bool = false,
        inUse: Bool = false
    ) -> MobileMirrorArrivalContext {
        MobileMirrorArrivalContext(
            isEnabled: enabled, isAppActive: active, isShowingThisMirror: showing,
            isAwaitingThisMirror: awaiting, offerAge: age, rejoin: rejoin, isInUse: inUse
        )
    }

    // MARK: - Arrival

    func testAnIdlePhoneTakesTheStageWithNoQuestion() {
        XCTAssertEqual(MobileMirrorArrivalPolicy.decide(context()), .stage)
    }

    func testAPhoneInUseOnlyShowsTheQuietOffer() {
        XCTAssertEqual(MobileMirrorArrivalPolicy.decide(context(inUse: true)), .quietOffer(.inUse))
        XCTAssertEqual(
            MobileMirrorArrivalPolicy.decide(context(rejoin: true, inUse: true)),
            .quietOffer(.inUse),
            "even the stage the person left waits while they type"
        )
    }

    func testALateArrivalWaitsAndNeverPromotesItself() {
        XCTAssertEqual(
            MobileMirrorArrivalPolicy.decide(context(age: RemoteMirror.freshStartWindow)),
            .quietOffer(.waiting)
        )
        XCTAssertEqual(
            MobileMirrorArrivalPolicy.decide(context(age: RemoteMirror.freshStartWindow - 1)),
            .stage,
            "an activation within thirty seconds of the click enters"
        )
    }

    func testARevisionOfAnOfferedMirrorKeepsWaiting() {
        var offered = context()
        offered.isOfferingThisMirror = true
        XCTAssertEqual(MobileMirrorArrivalPolicy.decide(offered), .quietOffer(.waiting))
        offered.isAwaitingThisMirror = true
        XCTAssertEqual(MobileMirrorArrivalPolicy.decide(offered), .stage, "a tap on the offer opens it")
    }

    func testTheStageThePersonLeftTakesThemBack() {
        XCTAssertEqual(MobileMirrorArrivalPolicy.decide(context(age: 3_600, rejoin: true)), .stage)
    }

    func testANotificationTapOrANewerRevisionAlwaysShows() {
        XCTAssertEqual(MobileMirrorArrivalPolicy.decide(context(awaiting: true, age: 3_600, inUse: true)), .stage)
        XCTAssertEqual(MobileMirrorArrivalPolicy.decide(context(showing: true, inUse: true)), .stage)
    }

    func testAnAppNotInFrontPostsTheInviteInstead() {
        XCTAssertEqual(MobileMirrorArrivalPolicy.decide(context(active: false)), .notify)
    }

    func testMirrorSwitchedOffForThisMacRefusesEvenATap() {
        XCTAssertEqual(MobileMirrorArrivalPolicy.decide(context(enabled: false, awaiting: true)), .refuse)
    }

    // MARK: - In use

    func testOnlyThePresentCountsAsInUse() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = MobileInteractionState()
        XCTAssertFalse(state.isInUse(at: now))

        state.activeTouches = 1
        XCTAssertTrue(state.isInUse(at: now), "a finger on the screen")

        state.activeTouches = 0
        state.lastTouchEndedAt = now.addingTimeInterval(-4)
        XCTAssertTrue(state.isInUse(at: now), "a finger that just left")
        state.lastTouchEndedAt = now.addingTimeInterval(-MobileMirrorDefaults.recentTouchWindow - 1)
        XCTAssertFalse(state.isInUse(at: now), "a minute ago is not now: the click on the Mac is newer")

        state.isKeyboardVisible = true
        state.keyboardShownAt = now.addingTimeInterval(-30)
        XCTAssertTrue(state.isInUse(at: now), "the keyboard is up")
    }

    func testAKeyboardRestoredOnActivationIsNotInput() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = MobileInteractionState()
        state.activatedAt = now.addingTimeInterval(-1)
        state.isKeyboardVisible = true
        state.keyboardShownAt = now.addingTimeInterval(-0.5)
        XCTAssertFalse(state.isInUse(at: now))

        state.keyboardShownAt = state.activatedAt?.addingTimeInterval(MobileMirrorDefaults.restoredKeyboardWindow + 1)
        XCTAssertTrue(state.isInUse(at: now.addingTimeInterval(10)))
    }

    // MARK: - Preferences

    func testMirrorIsOnForEveryMacUntilSwitchedOff() {
        let preferences = MobileMirrorPreferences(defaults: makeDefaults())
        XCTAssertTrue(preferences.isEnabled(hostID: "mac-a"))
        preferences.setEnabled(false, hostID: "mac-a")
        XCTAssertFalse(preferences.isEnabled(hostID: "mac-a"))
        XCTAssertTrue(preferences.isEnabled(hostID: "mac-b"), "the switch is per Mac")
        preferences.setEnabled(true, hostID: "mac-a")
        XCTAssertTrue(preferences.isEnabled(hostID: "mac-a"))
    }

    func testTheGuideRunsOnceThenTheArrivalRemindsThreeTimes() {
        let guide = MobileMirrorGuideStore(defaults: makeDefaults())
        XCTAssertFalse(guide.hasCompletedGuide)
        XCTAssertFalse(guide.takeGestureReminder(), "no reminder before the guide itself")
        guide.completeGuide()
        XCTAssertTrue(guide.hasCompletedGuide)
        XCTAssertEqual((0..<5).map { _ in guide.takeGestureReminder() }, [true, true, true, false, false])
        guide.resetGuide()
        XCTAssertFalse(guide.hasCompletedGuide)
    }

    // MARK: - Return from the Live Activity

    func testTheReturnLinkRoundTripsAndRefusesAnythingElse() throws {
        let attributes = MirrorActivityAttributes(macName: "MacBook Pro", hostID: "host-1", mirrorID: "m-1")
        let url = try XCTUnwrap(attributes.returnURL)
        XCTAssertEqual(MirrorReturnRoute(url: url), MirrorReturnRoute(url: url))
        XCTAssertEqual(MirrorReturnRoute(url: url)?.mirrorID, "m-1")
        XCTAssertEqual(MirrorReturnRoute(url: url)?.hostID, "host-1")
        XCTAssertNil(MirrorReturnRoute(url: URL(string: "threading://mirror?host=a")!))
        XCTAssertNil(MirrorReturnRoute(url: URL(string: "threading://usage?host=a&id=b")!))
        XCTAssertNil(MirrorReturnRoute(url: URL(string: "threading://mirror?host=a%20b&id=c")!))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "MobileMirrorPolicyTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
