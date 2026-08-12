import AppKit
import XCTest
@testable import SwiftTerm
@testable import Threading

/// What a program's `BEL` sounds like.
///
/// The stored form carries three states in one string, which is the part worth holding: two
/// reserved words and a file name, in a preference where an absent key has to keep meaning what
/// the bell did before it was a setting. Playback itself is `NSSound`, which a test cannot hear;
/// what it can hold is that silence is reachable, that a missing file still rings, and that the
/// tokens can never be mistaken for a sound.
final class TerminalBellTests: XCTestCase {

    // MARK: - Stored Choice

    /// An install that never chose hears exactly what it heard before: SwiftTerm rang
    /// `NSSound.beep()` unconditionally, so the absent key has to mean the system alert.
    func testAnAbsentPreferenceIsTheSoundTheBellAlreadyMade() {
        XCTAssertEqual(TerminalBellSound(storedValue: nil), .systemAlert)
        XCTAssertEqual(TerminalBellSound(storedValue: ""), .systemAlert)
    }

    func testEveryCaseRoundTripsThroughItsStoredValue() {
        for sound: TerminalBellSound in [.silent, .systemAlert, .named("Tink.aiff")] {
            XCTAssertEqual(TerminalBellSound(storedValue: sound.storedValue), sound)
        }
    }

    /// The reserved words are only safe because a stored sound is always a *file* name, and
    /// every file name the picker can offer carries a playable extension. If that ever stopped
    /// being true, a sound called "silent" would switch the bell off instead of playing.
    func testTheReservedWordsCannotCollideWithASound() {
        for token in [TerminalBellDefaults.silentToken, TerminalBellDefaults.systemToken] {
            XCTAssertFalse(
                NotificationSoundLibrary.supportedExtensions
                    .contains((token as NSString).pathExtension.lowercased()),
                "\(token) could be a sound file name"
            )
            XCTAssertNotEqual(TerminalBellSound(storedValue: token), .named(token))
        }
    }

    @MainActor
    func testTheChoicePersists() throws {
        let suite = "TerminalBellSound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.terminalBellSound, .systemAlert)

        settings.terminalBellSound = .silent
        XCTAssertEqual(AppSettings(defaults: defaults).terminalBellSound, .silent)

        settings.terminalBellSound = .named("Submarine.aiff")
        XCTAssertEqual(
            AppSettings(defaults: defaults).terminalBellSound,
            .named("Submarine.aiff")
        )
    }

    // MARK: - The Seam

    /// A bell has exactly one way out of the terminal view, and this is it.
    ///
    /// The obvious place to answer a bell is the delegate, and it is the wrong place twice over.
    /// A `LocalProcessTerminalView` sets **itself** as the view's `terminalDelegate` and does not
    /// implement `bell`, so the call lands on `TerminalViewDelegate`'s protocol-extension
    /// default — a bare `NSSound.beep()`. And `LocalProcessTerminalViewDelegate`, which is what
    /// `TerminalSession` conforms to, forwards four methods to its `processDelegate` and the
    /// bell is not among them. So a `bell(source:)` written on the session compiles, satisfies
    /// nothing, and is never called: the beep would go on exactly as before, and the setting
    /// would look wired up while doing nothing.
    ///
    /// Both halves are asserted, because either one changing upstream would silently restore
    /// the beep or silently kill the bell.
    @MainActor
    func testTheBellLeavesTheViewThroughOnBellAndNowhereElse() {
        let view = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        // Half one: the delegate SwiftTerm would consult is the view, not anything of ours.
        XCTAssertTrue(
            view.terminalDelegate === view,
            "the terminal's delegate is no longer the view, so the bell may have another route"
        )

        // Half two: our override answers, and it answers through the hook the session owns.
        var rang = 0
        view.onBell = { rang += 1 }
        view.bell(source: view.getTerminal())
        XCTAssertEqual(rang, 1, "a bell no longer reaches the hook that decides its sound")
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
}
