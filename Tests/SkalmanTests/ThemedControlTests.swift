import AppKit
import XCTest
@testable import Skalman

/// The themed controls that replace stock AppKit, so a styled app is themed all the way down
/// rather than themed cards around system-blue switches.
@MainActor
final class ThemedControlTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Drop-in Behaviour

    /// `ThemedToggle` replaces `NSSwitch` at call sites that read `.state == .on` and fire an
    /// action, so it has to behave like one: a click flips the state and sends the action.
    func testAToggleFlipsAndFiresLikeASwitch() {
        let toggle = ThemedToggle()
        toggle.state = .off

        let target = ActionSpy()
        toggle.target = target
        toggle.action = #selector(ActionSpy.fire)

        toggle.mouseDown(with: .init())

        XCTAssertEqual(toggle.state, .on, "a click did not flip the state")
        XCTAssertEqual(target.count, 1, "the action did not fire")

        toggle.mouseDown(with: .init())
        XCTAssertEqual(toggle.state, .off)
        XCTAssertEqual(target.count, 2)
    }

    func testADisabledToggleIgnoresClicks() {
        let toggle = ThemedToggle()
        toggle.isEnabled = false
        toggle.state = .off

        toggle.mouseDown(with: .init())

        XCTAssertEqual(toggle.state, .off, "a disabled toggle changed state")
    }

    func testTheHelperBuildsAThemedToggleNotAnNSSwitch() {
        let spy = ActionSpy()
        let control = SettingsUI.toggle(isOn: true, target: spy, action: #selector(ActionSpy.fire))
        XCTAssertTrue(control is ThemedToggle, "SettingsUI.toggle still hands back a raw switch")
        XCTAssertEqual(control.state, .on)
    }

    // MARK: - Theming

    /// The whole point: the on-track is the theme's accent, not the system's. Sampled from the
    /// drawn control rather than asserted by hex — exact bytes drift with anti-aliasing, but the
    /// *hue* is unmistakable: Cyberpunk's green-dominant accent draws a green track, Swiss's
    /// red-dominant one draws a red track, and a stock `NSSwitch` would draw the same system
    /// blue under both.
    func testTheOnTrackTakesTheThemeAccent() {
        func trackColour(under theme: AppTheme) -> NSColor {
            AppThemePalette.set(theme)
            let toggle = ThemedToggle(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
            toggle.state = .on

            let rep = toggle.bitmapImageRepForCachingDisplay(in: toggle.bounds)!
            toggle.cacheDisplay(in: toggle.bounds, to: rep)
            // Well inside the track on the left, clear of the knob and the rounded edges.
            return rep.colorAt(x: 8, y: 11)!.usingColorSpace(.sRGB)!
        }

        let cyber = trackColour(under: AppThemeStyles.cyberpunk)
        let swiss = trackColour(under: AppThemeStyles.swissMinimalist)

        XCTAssertGreaterThan(cyber.greenComponent, cyber.redComponent,
                             "Cyberpunk's track is not green")
        XCTAssertGreaterThan(swiss.redComponent, swiss.greenComponent,
                             "Swiss's track is not red")
    }
}

// MARK: - Helpers

private final class ActionSpy: NSObject {
    private(set) var count = 0
    @objc func fire() { count += 1 }
}
