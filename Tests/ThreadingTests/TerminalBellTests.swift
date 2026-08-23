import AppKit
import XCTest
@testable import SwiftTerm
@testable import Threading

/// What a program's `BEL` sounds like.
///
/// The choice itself is `SoundChoice`, shared with the notification alert and held to its own
/// stored form in `SoundChoiceTests`; what belongs here is the bell's half — that an absent key
/// keeps meaning what the bell did before it was a setting, that silence is reachable, and that
/// a bell has exactly one way out of the terminal view. Playback itself is `NSSound`, which a
/// test cannot hear.
final class TerminalBellTests: XCTestCase {

    // MARK: - Stored Choice

    /// An install that never chose hears exactly what it heard before: SwiftTerm rang
    /// `NSSound.beep()` unconditionally, so the absent key has to mean the system alert. The
    /// decode declines to answer for an absent key precisely so this default is the bell's own
    /// rather than one the alert sound would have to share.
    @MainActor
    func testAnAbsentPreferenceIsTheSoundTheBellAlreadyMade() throws {
        let suite = "TerminalBellSoundAbsent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(TerminalBellDefaults.sound, .system)
        XCTAssertNil(SoundChoice(storedValue: nil))
        XCTAssertEqual(AppSettings(defaults: defaults).terminalBellSound, .system)
    }

    @MainActor
    func testTheChoicePersists() throws {
        let suite = "TerminalBellSound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.terminalBellSound, .system)

        settings.terminalBellSound = .silent
        XCTAssertEqual(AppSettings(defaults: defaults).terminalBellSound, .silent)

        settings.terminalBellSound = .named("Submarine.aiff")
        XCTAssertEqual(
            AppSettings(defaults: defaults).terminalBellSound,
            .named("Submarine.aiff")
        )
    }

    // MARK: - The Seam

    /// A bell has exactly one host route, after SwiftTerm's parser-to-main event queue.
    ///
    /// `LocalProcessTerminalView` sets itself as `terminalDelegate`, and owns an open witness for
    /// that protocol requirement. The subclass overrides that main-actor method; the distinct
    /// parser-level `bell(source: Terminal)` stays inherited so it can release `TerminalLock`
    /// without waiting for any host work.
    @MainActor
    func testTheBellLeavesTheViewThroughOnBellAndNowhereElse() {
        let view = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        // Half one: the delegate SwiftTerm would consult is the view, not anything of ours.
        XCTAssertTrue(
            view.terminalDelegate === view,
            "the terminal's delegate is no longer the view, so the bell may have another route"
        )

        // Half two: our main-actor override answers through the hook the session owns.
        var rang = 0
        let delivered = expectation(description: "bell delivered after the parser transaction")
        view.onBell = {
            rang += 1
            delivered.fulfill()
        }
        view.feed(text: "\u{7}")
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(rang, 1, "a bell no longer reaches the hook that decides its sound")
    }

    /// Reproduces the production deadlock without a live process.
    ///
    /// A terminal output callback can make the main actor read the terminal buffer while the next
    /// parse batch owns `TerminalLock`. Before the fix, a BEL in that batch entered `onBell`
    /// directly on the parser thread and `NotificationCenter` synchronously waited for its
    /// main-queue observer. Main was waiting for the terminal lock, so neither side could finish.
    /// Blocking main until the feed returns makes that inversion deterministic: the parser must
    /// enqueue the bell and return independently, then the callback and observer may run on main.
    @MainActor
    func testBackgroundBellDoesNotWaitForMainWhileHoldingTerminalLock() {
        let view = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let feed = BackgroundTerminalFeed(view)
        let center = NotificationCenter()
        let notificationName = Notification.Name("TerminalBellTests.backgroundBell")
        let callbackDelivered = expectation(description: "bell callback delivered on main")
        let observerDelivered = expectation(description: "main-queue notification delivered")
        let observer = center.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            observerDelivered.fulfill()
        }
        defer { center.removeObserver(observer) }

        view.onBell = {
            XCTAssertTrue(Thread.isMainThread, "host bell work escaped SwiftTerm's main event queue")
            center.post(name: notificationName, object: nil)
            callbackDelivered.fulfill()
        }

        let feedFinished = DispatchSemaphore(value: 0)
        Thread {
            feed.sendBell()
            feedFinished.signal()
        }.start()

        XCTAssertEqual(
            feedFinished.wait(timeout: .now() + 1),
            .success,
            "the parser waited for main while its terminal transaction was still active"
        )
        wait(for: [callbackDelivered, observerDelivered], timeout: 1)
    }

    // MARK: - Rate Limit

    /// A program can write `BEL` in a loop, and the terminal's output path may not do unbounded
    /// work. The player collapses a storm into one sound; without the limit this is a hundred
    /// overlapping `NSSound`s per second.
    @MainActor
    func testABellStormCollapsesIntoOneSound() {
        let player = SoundPlayer(minimumInterval: 60)

        XCTAssertTrue(player.admitsPlaybackNow())
        for _ in 0..<100 {
            XCTAssertFalse(player.admitsPlaybackNow(), "a second bell got through the limit")
        }
    }

    /// The window is short enough that two deliberate bells are still two, rather than a
    /// setting that quietly swallows every second one.
    @MainActor
    func testTwoBellsFurtherApartThanTheWindowAreBothHeard() {
        let player = SoundPlayer(minimumInterval: 0.01)

        XCTAssertTrue(player.admitsPlaybackNow())
        let waited = XCTestExpectation(description: "past the window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waited.fulfill() }
        wait(for: [waited], timeout: 1)
        XCTAssertTrue(player.admitsPlaybackNow())
    }

    /// The settings preview has no limit, because every click is a deliberate ask to hear
    /// something — including clicking the same item twice.
    @MainActor
    func testAuditioningTheSameSoundTwiceIsAllowed() {
        let player = SoundPlayer()
        XCTAssertTrue(player.admitsPlaybackNow())
        XCTAssertTrue(player.admitsPlaybackNow())
    }

    /// The limiter is consulted **before** anything else the bell would do — the global silence
    /// gate excepted, which comes before even it; see `SilenceGateTests`. A `BEL` arrives as
    /// fast as a program can write a byte, and a rejected one must cost a date comparison and
    /// nothing else — no walk through the resolution chain, and none of the `stat`s a chosen
    /// file name is looked up with. It used to pay for both on every bell of a storm.
    @MainActor
    func testABellTheWindowRejectsIsNeverResolved() {
        var resolutions = 0
        var plays = 0

        TerminalBell.ring(
            cause: .bellAgentAsking,
            silenced: { false },
            admits: { false },
            resolve: { _ in
                resolutions += 1
                return .system
            },
            play: { _ in plays += 1 }
        )

        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(plays, 0)
    }

    /// And an admitted one resolves its own cause, once.
    @MainActor
    func testAnAdmittedBellResolvesItsCauseAndPlaysItOnce() {
        var seen: [SoundEvent?] = []
        var played: [SoundChoice] = []

        TerminalBell.ring(
            cause: .bellLaunch,
            silenced: { false },
            admits: { true },
            resolve: { cause in
                seen.append(cause)
                return .named("Tink.aiff")
            },
            play: { played.append($0) }
        )

        XCTAssertEqual(seen, [.bellLaunch])
        XCTAssertEqual(played, [.named("Tink.aiff")])
    }

    // MARK: - The Note An Audible Bell Leaves

    /// The note that keeps the attention alert quiet is written **in the play step**, and that
    /// position is the whole guarantee.
    ///
    /// A bell the global gate holds and a bell the limiter rejects never reach the speaker, so
    /// neither may leave a note: nobody heard anything, and the banner a moment later is the
    /// only sound there is. Placed any earlier — beside the gate, or beside the limiter — a
    /// silenced storm or a rejected bell would quietly disarm the next alert's sound instead.
    ///
    /// The composition asserted here is the one `ring(cause:owner:)` itself uses; only the
    /// speaker and the register are handed in, so the test hears nothing and keeps its own map.
    @MainActor
    func testTheNoteIsWrittenInThePlayStepAndNowhereEarlier() {
        let sessionID = SessionID()
        let owner = SoundOwner.session(sessionID)

        func ring(silenced: Bool, admits: Bool, into register: AudibleBellRegister) -> [SoundChoice] {
            var spoken: [SoundChoice] = []
            TerminalBell.ring(
                cause: .bellAgentAsking,
                silenced: { silenced },
                admits: { admits },
                resolve: { _ in .system },
                play: {
                    TerminalBell.playAndRegister(
                        $0,
                        owner: owner,
                        speaker: { spoken.append($0) },
                        register: register
                    )
                }
            )
            return spoken
        }

        let gated = AudibleBellRegister(window: 60)
        XCTAssertEqual(ring(silenced: true, admits: true, into: gated), [])
        XCTAssertFalse(gated.heardBell(for: sessionID), "a bell nobody heard disarmed the alert")

        let rejected = AudibleBellRegister(window: 60)
        XCTAssertEqual(ring(silenced: false, admits: false, into: rejected), [])
        XCTAssertFalse(
            rejected.heardBell(for: sessionID),
            "a bell the limiter swallowed disarmed the alert"
        )

        let heard = AudibleBellRegister(window: 60)
        XCTAssertEqual(ring(silenced: false, admits: true, into: heard), [.system])
        XCTAssertTrue(heard.heardBell(for: sessionID), "a bell that rang left no note")
    }

    /// Which bells speak for their session, and which have nothing to say.
    ///
    /// `silent` is the user's own answer — the finding's mitigation was setting this bell to
    /// Off — and a sound nobody heard cannot be doubled, so it leaves nothing. A standalone or
    /// ephemeral terminal leaves nothing either: neither has a conversation, and attention
    /// alerts are a conversation's. A **named sound whose file has gone still counts**, because
    /// `deliver` falls back to the alert beep rather than to silence, and a beep is a sound —
    /// getting that one backwards would make a missing file audible twice.
    @MainActor
    func testOnlyAnAudibleBellFromAConversationLeavesANote() {
        let sessionID = SessionID()
        let session = SoundOwner.session(sessionID)
        let terminal = SoundOwner.terminal(TerminalID())
        let gone = "ThisSoundHasNoFile.\(UUID().uuidString).aiff"
        XCTAssertNil(NotificationSoundLibrary.resolve(fileName: gone))

        XCTAssertEqual(TerminalBell.registration(for: .system, owner: session), sessionID)
        XCTAssertEqual(
            TerminalBell.registration(for: .named("Tink.aiff"), owner: session),
            sessionID
        )
        XCTAssertEqual(
            TerminalBell.registration(for: .named(gone), owner: session),
            sessionID,
            "the fallback beep is a sound the user hears, so the alert must not double it"
        )

        XCTAssertNil(TerminalBell.registration(for: .silent, owner: session))
        XCTAssertNil(TerminalBell.registration(for: .system, owner: terminal))
        XCTAssertNil(TerminalBell.registration(for: .system, owner: nil))
    }

    /// A surface with no activity tracker says nothing about the cause, and still rings.
    @MainActor
    func testABellWithNoCauseStillRings() {
        var played: [SoundChoice] = []

        TerminalBell.ring(
            cause: nil,
            silenced: { false },
            admits: { true },
            resolve: { cause in
                XCTAssertNil(cause)
                return SoundResolution.resolve(kind: .bell, through: [])
            },
            play: { played.append($0) }
        )

        XCTAssertEqual(played, [.system])
    }
}

/// `TerminalView.feed(text:)` is explicitly nonisolated and thread-safe. This wrapper narrows the
/// unchecked crossing to that one API so the test does not claim the AppKit view is generally
/// safe to use away from the main actor.
private final class BackgroundTerminalFeed: @unchecked Sendable {
    private let view: EmojiFixedTerminalView

    init(_ view: EmojiFixedTerminalView) {
        self.view = view
    }

    func sendBell() {
        view.feed(text: "\u{7}")
    }
}
