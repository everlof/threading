import UserNotifications
import XCTest
@testable import Threading

/// One `BEL` in a background session, and the two subsystems that both answer it.
///
/// The bell is the program asking; the `.blocked` banner is Threading noticing the `awaitsUser`
/// that same bell settled. Neither is wrong on its own, so one of them has to know about the
/// other — and the direction is not a preference, it is forced by when each of them decides.
/// The ring is synchronous inside `TerminalSession.onBell`; `AttentionAlertCenter` decides a
/// main-actor turn later. So the bell reports what it *did*, and the alert reads it.
///
/// What belongs here is the seam itself: the note's lifetime, who it speaks for, and that only
/// the alert's sound is ever dropped. Where the note is *written* — inside the play step, after
/// the gate and the limiter — is pinned in `TerminalBellTests` beside the rest of the ordering.
/// Nothing here posts a notification: the judgement is reachable without `UNUserNotificationCenter`
/// for the same reason `AttentionAlertPolicyTests` is.
@MainActor
final class BellAlertSuppressionTests: XCTestCase {

    // MARK: - Fixtures

    /// The chain's own answer for one alert on one session, with the register taken out of it.
    ///
    /// Asserted against as a *nil-parity*, never as a fixed sound: this test host reads the
    /// developer's real preferences, so whether `.blocked` sounds at all depends on their
    /// silence gate and their pickers. What must hold either way is that the guard changes the
    /// answer inside the window and changes nothing outside it.
    private func chainAnswer(
        for alert: AttentionAlert,
        sessionID: SessionID
    ) -> SoundChoice {
        SoundResolution.sound(for: SoundEvent(alert), sessionID: sessionID)
    }

    // MARK: - The Pair

    /// The finding itself: a bell was heard for this session, so the banner describing the same
    /// edge arrives silently.
    func testABellThatWasHeardKeepsItsOwnSessionsAlertQuiet() {
        let register = AudibleBellRegister(window: 0.5)
        let sessionID = SessionID()
        let rang = Date()

        register.recordAudibleBell(for: sessionID, at: rang)

        XCTAssertNil(
            AttentionAlertCenter.stateAlertSound(
                for: .blocked,
                sessionID: sessionID,
                bells: register,
                now: rang.addingTimeInterval(0.001)
            ),
            "the alert sounded on top of the bell that had just rung for the same edge"
        )
    }

    /// Every state alert is a possible echo, not only the one the finding was written from: a
    /// bell settles `awaitsUser` in a background session, but the same session can settle to
    /// `needsAttention` or finish a turn within the window.
    func testEveryStateAlertKindIsHeldByTheSameNote() {
        let register = AudibleBellRegister(window: 0.5)
        let sessionID = SessionID()
        let rang = Date()

        register.recordAudibleBell(for: sessionID, at: rang)

        for alert in AttentionAlert.allCases {
            XCTAssertNil(
                AttentionAlertCenter.stateAlertSound(
                    for: alert,
                    sessionID: sessionID,
                    bells: register,
                    now: rang.addingTimeInterval(0.1)
                ),
                alert.rawValue
            )
        }
    }

    // MARK: - What The Note Does Not Cover

    /// Outside the window the alert is a separate event and keeps whatever the chain gives it.
    /// The guard must not become a general quieting of alerts for sessions that ever rang.
    func testOutsideTheWindowTheAlertSoundsAgain() {
        let register = AudibleBellRegister(window: 0.5)
        let sessionID = SessionID()
        let rang = Date()

        register.recordAudibleBell(for: sessionID, at: rang)
        let sound = AttentionAlertCenter.stateAlertSound(
            for: .blocked,
            sessionID: sessionID,
            bells: register,
            now: rang.addingTimeInterval(0.6)
        )

        XCTAssertEqual(
            sound == nil,
            chainAnswer(for: .blocked, sessionID: sessionID) == .silent,
            "an expired note still quieted an alert the chain wanted to sound"
        )
    }

    /// A note is one session's. Four sessions ringing in a row must not silence the fifth's
    /// banner — the register is keyed, not a global "something rang recently".
    func testAnotherSessionsBellSaysNothingAboutThisOne() {
        let register = AudibleBellRegister(window: 0.5)
        let rang = Date()
        let noisy = SessionID()
        let quiet = SessionID()

        register.recordAudibleBell(for: noisy, at: rang)
        let sound = AttentionAlertCenter.stateAlertSound(
            for: .blocked,
            sessionID: quiet,
            bells: register,
            now: rang.addingTimeInterval(0.01)
        )

        XCTAssertEqual(
            sound == nil,
            chainAnswer(for: .blocked, sessionID: quiet) == .silent,
            "one session's bell quieted another session's alert"
        )
        XCTAssertNil(
            AttentionAlertCenter.stateAlertSound(
                for: .blocked,
                sessionID: noisy,
                bells: register,
                now: rang.addingTimeInterval(0.01)
            )
        )
    }

    /// A session that has never rung is the ordinary case, and it must cost the guard nothing.
    func testASessionWithNoNoteIsUntouched() {
        let register = AudibleBellRegister(window: 0.5)
        let sessionID = SessionID()

        let sound = AttentionAlertCenter.stateAlertSound(
            for: .blocked,
            sessionID: sessionID,
            bells: register,
            now: Date()
        )

        XCTAssertEqual(sound == nil, chainAnswer(for: .blocked, sessionID: sessionID) == .silent)
    }

    /// An update the user asked an agent to send is not an echo of a bell — nothing about the
    /// `BEL` produced it — so one arriving inside a bell's window keeps its sound. This is the
    /// one place the scoping is visible, since both sounds come from the same chain.
    func testARequestedUpdateStillSoundsInsideABellsWindow() {
        let sessionID = SessionID()
        // The default register, because this asserts the wiring the app itself uses. A single
        // entry for an id nothing else knows, which expires on its own.
        AudibleBellRegister.shared.recordAudibleBell(for: sessionID)

        XCTAssertNil(
            AttentionAlertCenter.stateAlertSound(for: .blocked, sessionID: sessionID),
            "the shared register is not what the alert center reads"
        )
        XCTAssertEqual(
            AttentionAlertCenter.requestedUpdateSound(for: sessionID) == nil,
            SoundResolution.sound(for: .alertRequestedUpdate, sessionID: sessionID) == .silent,
            "a requested update was quieted by a bell it has nothing to do with"
        )
    }

    // MARK: - The Register Itself

    /// The note expires on its own, at the boundary rather than near it.
    func testTheNoteExpiresAtTheWindow() {
        let register = AudibleBellRegister(window: 0.5)
        let sessionID = SessionID()
        let rang = Date()

        register.recordAudibleBell(for: sessionID, at: rang)

        XCTAssertTrue(register.heardBell(for: sessionID, at: rang))
        XCTAssertTrue(register.heardBell(for: sessionID, at: rang.addingTimeInterval(0.499)))
        XCTAssertFalse(register.heardBell(for: sessionID, at: rang.addingTimeInterval(0.5)))
    }

    /// One entry per session, overwritten rather than appended: a storm of bells in one session
    /// leaves one note, and the *latest* one is what the window is measured from.
    func testASecondBellOverwritesTheFirstRatherThanStacking() {
        let register = AudibleBellRegister(window: 0.5)
        let sessionID = SessionID()
        let first = Date()

        register.recordAudibleBell(for: sessionID, at: first)
        register.recordAudibleBell(for: sessionID, at: first.addingTimeInterval(0.4))

        XCTAssertTrue(
            register.heardBell(for: sessionID, at: first.addingTimeInterval(0.6)),
            "the window was measured from the older bell"
        )
        XCTAssertFalse(register.heardBell(for: sessionID, at: first.addingTimeInterval(0.95)))
    }

    /// Bounded with no timer to own: any touch drops what has gone stale, so the map cannot
    /// outgrow the sessions that rang inside one window. Asserted through the only thing a
    /// caller can see — a pruned session is no longer known — rather than through the storage.
    func testAnyTouchDropsWhatHasExpired() {
        let register = AudibleBellRegister(window: 0.5)
        let stale = SessionID()
        let fresh = SessionID()
        let rang = Date()

        register.recordAudibleBell(for: stale, at: rang)
        register.recordAudibleBell(for: fresh, at: rang.addingTimeInterval(1))

        XCTAssertFalse(register.heardBell(for: stale, at: rang.addingTimeInterval(1)))
        XCTAssertTrue(register.heardBell(for: fresh, at: rang.addingTimeInterval(1)))
    }

    /// A note dated in the future is a clock that moved under us, and "did a bell just ring"
    /// then has no answer. Uncertainty rings: the note is discarded rather than believed.
    func testANoteFromTheFutureIsNotBelieved() {
        let register = AudibleBellRegister(window: 0.5)
        let sessionID = SessionID()
        let rang = Date()

        register.recordAudibleBell(for: sessionID, at: rang)

        XCTAssertFalse(register.heardBell(for: sessionID, at: rang.addingTimeInterval(-1)))
    }

    // MARK: - The Window

    /// The window answers the same shape of question the bell's own limiter does — how far
    /// apart two sounds have to be to be two events — so it belongs in that order of magnitude.
    /// Long enough to survive a stalled main-actor turn, far short of a deliberate later alert.
    func testTheWindowStaysInTheOrderOfTheBellsOwnLimiter() {
        XCTAssertGreaterThan(
            TerminalBellDefaults.audibleBellWindow,
            TerminalBellDefaults.minimumInterval,
            "a window under the bell's own limiter cannot cover the hop it exists for"
        )
        XCTAssertLessThan(
            TerminalBellDefaults.audibleBellWindow,
            1,
            "a window measured in seconds starts eating alerts that are their own event"
        )
    }
}
