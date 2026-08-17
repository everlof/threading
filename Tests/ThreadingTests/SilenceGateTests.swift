import AppKit
import UserNotifications
import XCTest
@testable import Threading

/// The one switch that stops every sound the app can make.
///
/// Its whole claim is that it is a **gate rather than a scope**: it sits ahead of the resolution
/// chain instead of at the front of it, so it beats every answer the chain could give and yet
/// writes none of them. The tests below are the two halves of that — what it silences while it
/// holds, and what it has left untouched once it is released — plus the ordering on the bell
/// path, where a gate placed one step too late would quietly eat the rate limiter's window.
@MainActor
final class SilenceGateTests: XCTestCase {

    // MARK: - Fixtures

    /// The keys this reads and writes, spelled out.
    ///
    /// The bundle is hosted in the app, so `AppSettings.shared` is the developer's own defaults
    /// domain: every one of these is snapshotted and put back exactly as it was found, including
    /// being absent. The literals mirror `AppSettings.Keys`, which is private for the same reason
    /// every other key there is — `SoundResolutionTests` states one the same way.
    private enum Key {
        static let gate = "silencesAllSounds"
        static let bell = "terminalBellSound"
        static let alert = "attentionAlertSound"
        static let events = "soundEventChoices"
        static let all = [gate, bell, alert, events]
    }

    private var restored = false

    override func setUp() {
        super.setUp()
        let previous = Key.all.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        restored = true
        addTeardownBlock {
            for (key, value) in previous {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    // MARK: - The Setting

    /// Absent is audible, which is what every install has been. Nothing seeds it.
    func testAnAbsentKeyIsAnAudibleApp() throws {
        let suite = "SilenceGate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(AppSettings(defaults: defaults).silencesAllSounds)
    }

    /// It survives a relaunch, which a deliberate state that is visibly worn can do without
    /// becoming a mystery — the speaker at the sidebar's foot is the wearing.
    func testTheGatePersists() throws {
        let suite = "SilenceGate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        AppSettings(defaults: defaults).silencesAllSounds = true
        XCTAssertTrue(AppSettings(defaults: defaults).silencesAllSounds)
    }

    // MARK: - Beating Every Scope

    /// A bell with a cause and an alert event both resolve audible; the gate silences both, and
    /// releasing it hands each one back the answer it already had.
    ///
    /// The second half is the important one. The gate is transient state and configuration is
    /// not, so it may not rewrite a single stored choice on its way past — the map and the two
    /// kind entries are asserted whole after the round trip, not just their resolved answers.
    func testTheGateBeatsEveryScopeAndGivesEveryAnswerBackUntouched() {
        XCTAssertTrue(restored, "the defaults snapshot did not run, so this would leak")

        let settings = AppSettings.shared
        settings.silencesAllSounds = false
        settings.terminalBellSound = .named("Glass.aiff")
        settings.attentionAlertSound = .named("Submarine.aiff")
        settings.setSoundChoice(.named("Purr.aiff"), for: .alertFinished)

        let storedEvents = settings.soundEventChoices

        XCTAssertEqual(SoundResolution.sound(for: .bellAgentAsking), .named("Glass.aiff"))
        XCTAssertEqual(SoundResolution.sound(for: .alertBlocked), .named("Submarine.aiff"))
        XCTAssertEqual(SoundResolution.sound(for: .alertFinished), .named("Purr.aiff"))
        XCTAssertEqual(SoundResolution.sound(for: SoundEvent.Kind.bell), .named("Glass.aiff"))

        settings.silencesAllSounds = true

        for event in SoundEvent.allCases {
            XCTAssertEqual(SoundResolution.sound(for: event), .silent, event.rawValue)
        }
        for kind in SoundEvent.Kind.allCases {
            XCTAssertEqual(SoundResolution.sound(for: kind), .silent, kind.rawValue)
        }

        // Nothing was written on the way through: the chain still holds every choice, which is
        // what makes releasing the gate a restoration rather than a reconstruction.
        XCTAssertEqual(settings.terminalBellSound, .named("Glass.aiff"))
        XCTAssertEqual(settings.attentionAlertSound, .named("Submarine.aiff"))
        XCTAssertEqual(settings.soundEventChoices, storedEvents)

        settings.silencesAllSounds = false

        XCTAssertEqual(SoundResolution.sound(for: .bellAgentAsking), .named("Glass.aiff"))
        XCTAssertEqual(SoundResolution.sound(for: .alertBlocked), .named("Submarine.aiff"))
        XCTAssertEqual(SoundResolution.sound(for: .alertFinished), .named("Purr.aiff"))
        XCTAssertEqual(SoundResolution.sound(for: SoundEvent.Kind.bell), .named("Glass.aiff"))
    }

    /// The gate is not in the chain, and this is what says so: the same scope, resolved as a
    /// pure function of its arguments, answers the same thing whichever way the gate is set.
    /// Keeping it out is what leaves `resolve` testable without the app around it.
    func testThePureChainNeverLearnsAboutTheGate() {
        let scope = SoundResolution.Scope(kinds: [.bell: .named("Glass.aiff")])

        AppSettings.shared.silencesAllSounds = true
        XCTAssertEqual(
            SoundResolution.resolve(.bellAgentAsking, through: [scope]),
            .named("Glass.aiff")
        )
        XCTAssertEqual(SoundResolution.resolve(kind: .bell, through: [scope]), .named("Glass.aiff"))
    }

    /// A silenced alert posts its banner with no sound at all — the value both posting paths
    /// assign to `content.sound`, asked here exactly the way `AttentionAlertCenter.chosenSound`
    /// and `ScheduledMessageNotifier.post` ask it.
    func testEveryAlertPathBuildsItsBannerWithNoSoundWhileGated() {
        let settings = AppSettings.shared
        settings.silencesAllSounds = false
        settings.attentionAlertSound = .named("Submarine.aiff")
        settings.setSoundChoice(.named("Purr.aiff"), for: .alertScheduledMessage)

        let events: [SoundEvent] = [.alertBlocked, .alertRequestedUpdate, .alertScheduledMessage]
        for event in events {
            let content = UNMutableNotificationContent()
            content.sound = SoundResolution.sound(for: event).notificationSound()
            XCTAssertNotNil(content.sound, event.rawValue)
        }

        settings.silencesAllSounds = true

        for event in events {
            let content = UNMutableNotificationContent()
            content.sound = SoundResolution.sound(for: event).notificationSound()
            XCTAssertNil(content.sound, event.rawValue)
        }
    }

    /// The one attribution that costs syscalls is not computed for a sound nobody can hear.
    /// The *cause* is still classified — `SessionActivityTracker.recordBell` sets the sidebar's
    /// hand from state of its own — so nothing visual turns on this.
    func testAttributionIsNotPaidForWhileGated() {
        let settings = AppSettings.shared
        settings.silencesAllSounds = false
        settings.setSoundChoice(.named("Tink.aiff"), for: .bellOtherProgram)
        XCTAssertTrue(SoundResolution.attributesOtherPrograms())

        settings.silencesAllSounds = true
        XCTAssertFalse(SoundResolution.attributesOtherPrograms())
    }

    // MARK: - The Bell's Ordering

    /// A silenced bell costs one Boolean read and nothing else.
    ///
    /// **The limiter is not consulted**, which is the part worth a test of its own: the window
    /// is consumed by asking, so a gate placed after it would let a silenced storm eat the
    /// admission the first audible bell after the gate opened was going to use.
    func testASilencedBellNeverReachesTheLimiterTheChainOrTheSpeaker() {
        var admissions = 0
        var resolutions = 0
        var plays = 0

        for cause in SoundEvent.allCases where cause.kind == .bell {
            TerminalBell.ring(
                cause: cause,
                silenced: { true },
                admits: {
                    admissions += 1
                    return true
                },
                resolve: { _ in
                    resolutions += 1
                    return .system
                },
                play: { _ in plays += 1 }
            )
        }

        XCTAssertEqual(admissions, 0, "a silenced bell consumed the rate-limit window")
        XCTAssertEqual(resolutions, 0, "a silenced bell walked the resolution chain")
        XCTAssertEqual(plays, 0)
    }

    /// And with the gate open the order is unchanged: gate, limiter, chain, speaker.
    func testAnAudibleBellStillAsksTheLimiterBeforeTheChain() {
        var order: [String] = []

        TerminalBell.ring(
            cause: .bellAgentAsking,
            silenced: {
                order.append("gate")
                return false
            },
            admits: {
                order.append("limiter")
                return true
            },
            resolve: { _ in
                order.append("chain")
                return .system
            },
            play: { _ in order.append("play") }
        )

        XCTAssertEqual(order, ["gate", "limiter", "chain", "play"])
    }

    /// The gate is on the app's own route and not on the audition route.
    ///
    /// Choosing a sound is an explicit ask to hear it, and a picker that played nothing while
    /// the app was quiet would read as broken rather than as quiet. The two routes are told
    /// apart by what they are handed: the app *asks* for a sound and is answered `silent`,
    /// while an audition arrives with the choice already in hand and has nothing left to ask.
    ///
    /// Playback itself is `NSSound` and cannot be heard by a test, so what is pinned here is
    /// the one observable half — that the gated question is not on the audition's route.
    func testTheGateIsOnTheAppsRouteAndNotOnTheAuditionsRoute() {
        AppSettings.shared.silencesAllSounds = true

        XCTAssertEqual(SoundResolution.sound(for: SoundEvent.Kind.bell), .silent)
        XCTAssertEqual(SoundResolution.sound(for: .alertBlocked), .silent)

        // Handed a choice rather than asked for one, and silence is the one choice a test may
        // audition without making a noise in whoever's room the suite is running in.
        TerminalBell.play(.silent)
        NotificationSoundPreview.stop()
    }
}

// MARK: - The Footer's Control

/// The gate as the sidebar wears it: an audible speaker at the footer's trailing edge, becoming
/// slashed and filled while the app cannot be heard.
///
/// Asserted inside the sidebar itself rather than against a loose button, because a control
/// tested outside the container it ships in can pass while being unreachable — the footer band,
/// its margins and the outline view above it are all part of whether this control exists where
/// it claims to.
@MainActor
final class SilenceGateFooterTests: XCTestCase {

    private var directories: [URL] = []
    private var stateManagers: [StateManager] = []
    private var windows: [NSWindow] = []

    /// Hosted in the app, so these writes land in the developer's own defaults domain: every
    /// key is put back exactly as it was found, including being absent.
    override func setUp() {
        super.setUp()
        let keys = ["silencesAllSounds", "terminalBellSound", "soundEventChoices"]
        let previous = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        addTeardownBlock {
            for (key, value) in previous {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for window in windows {
                window.contentViewController = nil
                window.close()
            }
            windows = []
            for manager in stateManagers { manager.closeDatabase() }
            stateManagers = []
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
            directories = []
        }
        super.tearDown()
    }

    // MARK: - Fixture

    /// The real sidebar over a store of its own, laid out in a window that is built and never
    /// shown — the same fixture shape as `SidebarCompactTreeTests`.
    private func makeSidebar() -> ProjectSidebarViewController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-silence-gate-\(UUID().uuidString)",
            isDirectory: true
        )
        directories.append(directory)

        let manager = StateManager(appSupportDirectory: directory)
        stateManagers.append(manager)
        let controller = ProjectSidebarViewController(projectStore: ProjectStore(stateManager: manager))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 320, height: 600))
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    /// Matched by `accessibilityTitle()`, which is what `ThemedIconButton` answers with — its
    /// accessibility *label* is a different question and would find nothing.
    private func gateButton(in controller: NSViewController) -> ThemedIconButton? {
        func search(_ view: NSView) -> ThemedIconButton? {
            if let button = view as? ThemedIconButton,
               button.accessibilityTitle() == SidebarStrings.silenceSounds {
                return button
            }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(controller.view)
    }

    private func footer(in controller: NSViewController) -> PaneFooterView? {
        func search(_ view: NSView) -> PaneFooterView? {
            if let band = view as? PaneFooterView { return band }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(controller.view)
    }

    /// Delivery is on the main queue, and a settings write from a test is not always drained
    /// before the next line. One short slice of the run loop is enough, and the fixture window
    /// is never ordered on screen, so nothing here can queue a termination decision.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Where It Is

    func testTheGateSitsInTheFooterBandAtItsTrailingEdge() throws {
        AppSettings.shared.silencesAllSounds = false
        let sidebar = makeSidebar()
        let button = try XCTUnwrap(gateButton(in: sidebar), "the footer carries no silence gate")
        let band = try XCTUnwrap(footer(in: sidebar))

        XCTAssertTrue(
            button.isDescendant(of: band),
            "the gate is somewhere in the sidebar but not in the band that states its margins"
        )
        // Trailing: past the middle of the band, and its ink on the band's own stated margin.
        XCTAssertGreaterThan(button.frame.midX, band.bounds.midX)
        XCTAssertEqual(
            button.frame.maxX - button.opticalHorizontalInset,
            band.contentGuide.frame.maxX - Design.Spacing.inset,
            accuracy: 0.5
        )
        XCTAssertEqual(button.toolTip, SidebarStrings.silenceSoundsHint)
    }

    // MARK: - What It Says and Does

    func testTheGateUsesSpeakerStatesInsteadOfMakingTheFrameCarryTheMeaning() {
        XCTAssertEqual(
            SidebarDefaults.silenceSymbol(isSilenced: false),
            SidebarDefaults.soundsAudibleSymbol
        )
        XCTAssertEqual(
            SidebarDefaults.silenceSymbol(isSilenced: true),
            SidebarDefaults.soundsSilencedSymbol
        )
        XCTAssertNotEqual(
            SidebarDefaults.soundsAudibleSymbol,
            SidebarDefaults.soundsSilencedSymbol
        )
    }

    /// It follows the setting rather than its own presses, which is what keeps it agreeing with
    /// the Settings row, the menu item and a second window.
    func testTheButtonWearsWhateverTheSettingSays() throws {
        AppSettings.shared.silencesAllSounds = false
        let sidebar = makeSidebar()
        let button = try XCTUnwrap(gateButton(in: sidebar))

        XCTAssertFalse(button.isSelected)

        AppSettings.shared.silencesAllSounds = true
        settle()
        XCTAssertTrue(button.isSelected, "a silenced app is not wearing it")
        XCTAssertEqual(button.toolTip, SidebarStrings.silencedHint)

        AppSettings.shared.silencesAllSounds = false
        settle()
        XCTAssertFalse(button.isSelected)
        XCTAssertEqual(button.toolTip, SidebarStrings.silenceSoundsHint)
    }

    /// A sidebar built while the gate already holds comes up wearing it — the state persists,
    /// so a window opened later must not read as an audible app.
    func testASidebarBuiltWhileGatedComesUpWearingIt() throws {
        AppSettings.shared.silencesAllSounds = true
        let button = try XCTUnwrap(gateButton(in: makeSidebar()))

        XCTAssertTrue(button.isSelected)
    }

    func testPressingItTogglesTheSettingAndNothingElse() throws {
        AppSettings.shared.silencesAllSounds = false
        AppSettings.shared.terminalBellSound = .named("Glass.aiff")
        let stored = AppSettings.shared.soundEventChoices
        let sidebar = makeSidebar()
        let button = try XCTUnwrap(gateButton(in: sidebar))

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(AppSettings.shared.silencesAllSounds)

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertFalse(AppSettings.shared.silencesAllSounds)

        XCTAssertEqual(AppSettings.shared.terminalBellSound, .named("Glass.aiff"))
        XCTAssertEqual(AppSettings.shared.soundEventChoices, stored)
    }
}
