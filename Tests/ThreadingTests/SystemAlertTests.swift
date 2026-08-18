import XCTest
@testable import Threading

/// The third sound: the beep an action makes when it does not happen.
///
/// It used to be the only one nothing could turn off. Fifty-eight call sites rang `NSSound.beep()`
/// themselves, so `AppSettings.silencesAllSounds` — which reaches `SoundResolution` and
/// `TerminalBell` — silenced the bell and the banners and left the app's most frequent sound
/// alone. Playback is `NSSound` and a test cannot hear it, so what is pinned here is the decision
/// in front of it: who may be heard, and in which process.
@MainActor
final class SystemAlertTests: XCTestCase {

    // MARK: - The Gate

    /// The row that was the bug: a silenced app does not beep.
    func testASilencedAppRefusesQuietly() {
        XCTAssertFalse(
            SystemAlert.isAudible(silenced: true, isAutomated: false),
            "Silence Sounds silenced the bell and the banners and left this one audible"
        )
    }

    /// And the rest of the table, so neither input can be dropped without a failure.
    func testARefusalIsHeardOnlyWhenNothingIsHoldingIt() {
        XCTAssertTrue(SystemAlert.isAudible(silenced: false, isAutomated: false))
        XCTAssertFalse(SystemAlert.isAudible(silenced: false, isAutomated: true))
        XCTAssertFalse(SystemAlert.isAudible(silenced: true, isAutomated: true))
    }

    // MARK: - This Process

    /// The wiring, asked of the process running the assertion.
    ///
    /// The table above is pure and would pass with the live inputs never connected to it. This is
    /// the half that cannot: a hosted test is automated, is therefore inaudible, and calling the
    /// entry point proves the guard — not the caller's restraint — is what keeps this suite quiet.
    func testThisSuiteCannotBeHeard() {
        XCTAssertFalse(SystemAlert.isAudible, "this test run can beep in the developer's room")

        SystemAlert.refuse()
    }
}
