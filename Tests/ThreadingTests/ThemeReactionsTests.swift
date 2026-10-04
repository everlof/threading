import AppKit
import ThreadingExtensionKit
@testable import Threading
import XCTest

/// The person's Threading-wide Reaction strength (`ThemeReactions`): the arithmetic, the setting
/// it reads, and each place a reactive reading enters decoration.
@MainActor
final class ThemeReactionsTests: XCTestCase {

    private var previousSettings: DesignSettingsReading?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            previousSettings = DesignSettings.current
            DesignSettings.current = StubDesignSettings()
            Design.Motion.reduceMotionOverrideForTesting = false
            ThemeParticleHold.seenOverrideForTesting = true
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let previousSettings { DesignSettings.current = previousSettings }
            Design.Motion.reduceMotionOverrideForTesting = nil
            ThemeParticleHold.seenOverrideForTesting = nil
        }
        super.tearDown()
    }

    private func strength(_ value: Double, activity: Bool = true) {
        DesignSettings.current = StubDesignSettings(
            themeReactionStrength: value,
            themeReactsToActivity: activity
        )
    }

    // MARK: - Arithmetic

    func testTheScaleHoldsDoublesAndClamps() {
        strength(1)
        XCTAssertEqual(ThemeReactions.scaledActivity(0.4), 0.4, accuracy: 1e-9, "as authored")
        XCTAssertEqual(ThemeReactions.scaledMusic(0.4), 0.4, accuracy: 1e-9)
        strength(0)
        XCTAssertEqual(ThemeReactions.scaledActivity(0.9), 0, "0% holds decoration at rest")
        XCTAssertEqual(ThemeReactions.scaledMusic(0.9), 0)
        XCTAssertEqual(ThemeReactions.activityFloor(0.35), 0)
        strength(2)
        XCTAssertEqual(ThemeReactions.scaledActivity(0.3), 0.6, accuracy: 1e-9)
        XCTAssertEqual(ThemeReactions.scaledMusic(0.8), 1, "a reading never exceeds full")
        XCTAssertEqual(ThemeReactions.activityCount(3), 6, "counts scale as counts")
        XCTAssertEqual(ThemeReactions.activityFloor(0.35), 0.35, accuracy: 1e-9, "the floor never rises")
        strength(5)
        XCTAssertEqual(ThemeReactions.strength, ThemeReactions.maximumStrength)
    }

    func testTurningActivityOffHoldsActivityButNotMusic() {
        strength(2, activity: false)
        XCTAssertNil(ThemeReactions.activity(0.5), "activity off reads as no reading")
        XCTAssertNil(ThemeReactions.activityCount(3))
        XCTAssertEqual(ThemeReactions.scaledActivity(0.5), 0)
        XCTAssertEqual(ThemeReactions.activityFloor(0.35), 0, "a working pose's stream stops")
        XCTAssertEqual(ThemeReactions.scaledMusic(0.3), 0.6, accuracy: 1e-9,
                       "music keeps its own switch, which is capture consent")
    }

    // MARK: - Setting

    func testTheSettingDefaultsToAsAuthoredAndStaysInRange() throws {
        let suiteName = "ThemeReactionsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, userChoiceDefaults: defaults)

        XCTAssertEqual(settings.themeReactionStrength, 100)
        settings.themeReactionStrength = 150
        XCTAssertEqual(settings.themeReactionStrength, 150)
        settings.themeReactionStrength = 900
        XCTAssertEqual(settings.themeReactionStrength, 200, "clamped to the scale")
        settings.themeReactionStrength = -5
        XCTAssertEqual(settings.themeReactionStrength, 0)
    }

    // MARK: - Where reactions enter decoration

    func testAnExtensionsReactiveInputsScaleButItsFactsDoNot() throws {
        strength(2)
        XCTAssertEqual(try XCTUnwrap(ExtensionMetalSurfaceView.reacted(.workloadIntensity, 0.3)), 0.6, accuracy: 1e-9)
        XCTAssertEqual(ExtensionMetalSurfaceView.reacted(.audioBass, 0.7), 1)
        XCTAssertEqual(ExtensionMetalSurfaceView.reacted(.workloadWorkingCount, 2), 4)
        XCTAssertEqual(ExtensionMetalSurfaceView.reacted(.audioAvailable, 1), 1, "a fact passes through")
        XCTAssertEqual(ExtensionMetalSurfaceView.reacted(.timeOfDayFraction, 0.25), 0.25)
        strength(0)
        XCTAssertEqual(ExtensionMetalSurfaceView.reacted(.workloadIntensity, 1), 0)
        XCTAssertEqual(ExtensionMetalSurfaceView.reacted(.audioAvailable, 1), 1)

        strength(1, activity: false)
        XCTAssertNil(ExtensionMetalSurfaceView.reacted(.workloadIntensity, 1),
                     "activity off: the binding reads its idle fallback")
        XCTAssertNil(ExtensionMetalSurfaceView.reacted(.momentTurnFinished, 1))
        XCTAssertNil(ExtensionMetalSurfaceView.reacted(.workloadWorkingCount, 3))
        XCTAssertEqual(ExtensionMetalSurfaceView.reacted(.audioBass, 0.4), 0.4)
        XCTAssertEqual(ExtensionMetalSurfaceView.reacted(.themeDark, 1), 1)
    }

    func testALogosWorkingStreamFollowsTheScale() throws {
        let logo = ThemeLogoView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        logo.layout()
        let fizz = ThemeParticles(
            style: .fizz,
            colors: [.role(.accent), .color(NSColor(hex: "#FFFFFF")!)],
            density: 0.6
        )
        logo.configure(
            image: NSImage(size: NSSize(width: 24, height: 24)),
            motion: SidebarAppearance.Brand.LogoMotion(
                spec: .init(hover: .tilt, particles: fizz, working: true),
                particles: .init(spec: fizz, colors: [NSColor(hex: "#FFFFFF")!])
            )
        )
        logo.setWorkingIntensity(0.4)
        let authored = logo.streamRate
        XCTAssertGreaterThan(authored, 0)

        strength(2)
        logo.refreshParticleMotion()
        XCTAssertGreaterThan(logo.streamRate, authored, "200% answers the same work harder")

        strength(0)
        logo.refreshParticleMotion()
        XCTAssertEqual(logo.streamRate, 0, "0% holds the stream still")

        strength(2, activity: false)
        logo.refreshParticleMotion()
        XCTAssertEqual(logo.streamRate, 0, "activity off holds it still at any strength")
    }

    func testTheMotionPageCarriesTheScaleInWholeTens() throws {
        let suiteName = "ThemeReactionsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, userChoiceDefaults: defaults)
        let preferences = ThemeReactionPreferences(settings: settings)
        let section = preferences.section()
        let scrubber = try XCTUnwrap(
            section.firstDescendant(identifier: "motion.theme-reaction-strength") as? ThemedScrubber
        )
        XCTAssertEqual(scrubber.value, 0.5, accuracy: 1e-9, "100% sits mid-track")
        XCTAssertEqual(scrubber.accessibilityLabel(), L10n.string("Reaction strength"))

        scrubber.onChange?(0.687)
        XCTAssertEqual(settings.themeReactionStrength, 140, "lands on a whole ten")
        scrubber.onChange?(0)
        XCTAssertEqual(settings.themeReactionStrength, 0)

        let toggle = try XCTUnwrap(
            section.firstDescendant(identifier: "motion.theme-reacts-to-activity") as? ThemedToggle
        )
        XCTAssertEqual(toggle.state, .on, "activity reactions default on")
        toggle.state = .off
        _ = toggle.target?.perform(toggle.action, with: toggle)
        XCTAssertFalse(settings.themeReactsToActivity)
        settings.sharesThemeAudio = false
        XCTAssertFalse(scrubber.isEnabled, "with no reaction on there is nothing to scale")
        settings.themeReactsToActivity = true
        XCTAssertTrue(scrubber.isEnabled)
    }
}

private extension NSView {
    func firstDescendant(identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier { return self }
        for subview in subviews {
            if let found = subview.firstDescendant(identifier: identifier) { return found }
        }
        return nil
    }
}
