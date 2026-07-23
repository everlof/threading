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

    // MARK: - Pop-Up Drop-in Behaviour

    /// `ThemedPopUp` replaces `NSPopUpButton` at call sites that add titled items and read the
    /// selection back, so the whole of that small surface has to behave the same — including
    /// AppKit's habit of selecting the first item a pop-up is given.
    func testAPopUpSelectsItsFirstItemAndReadsItBack() {
        let popUp = ThemedPopUp()
        XCTAssertEqual(popUp.indexOfSelectedItem, -1, "an empty pop-up claimed a selection")
        XCTAssertNil(popUp.selectedItem)

        popUp.addItem(withTitle: "Claude Code")
        popUp.addItem(withTitle: "Codex")

        XCTAssertEqual(popUp.numberOfItems, 2)
        XCTAssertEqual(popUp.indexOfSelectedItem, 0, "the first item was not selected")
        XCTAssertEqual(popUp.selectedItem?.title, "Claude Code")
        XCTAssertEqual(popUp.lastItem?.title, "Codex")

        popUp.selectItem(at: 1)
        XCTAssertEqual(popUp.selectedItem?.title, "Codex")
    }

    /// The index usually comes from looking a stored value up in a list, so one the list no
    /// longer holds must leave the control unselected rather than trap — the settings window is
    /// not a place to crash over a stale preference.
    func testAnOutOfRangeSelectionIsToleratedRatherThanTrapped() {
        let popUp = ThemedPopUp()
        popUp.addItem(withTitle: "Block")

        popUp.selectItem(at: 7)

        XCTAssertEqual(popUp.indexOfSelectedItem, -1)
        XCTAssertNil(popUp.selectedItem)
    }

    func testChoosingAnItemRecordsTheSelectionThenFiresTheAction() {
        let popUp = ThemedPopUp()
        popUp.addItem(withTitle: "System")
        popUp.addItem(withTitle: "Cyberpunk")

        let target = ActionSpy()
        popUp.target = target
        popUp.action = #selector(ActionSpy.fire)

        popUp.itemChosen(popUp.item(at: 1)!)

        XCTAssertEqual(popUp.indexOfSelectedItem, 1, "the choice was not recorded")
        XCTAssertEqual(target.count, 1, "the action did not fire")
    }

    /// A pull-down is an actions button: its entries do things rather than becoming the title,
    /// which is what the themes list's gear depends on.
    func testAPullDownKeepsItsLabelAndRecordsNoSelection() {
        let popUp = ThemedPopUp()
        popUp.pullsDown = true
        popUp.addItem(withTitle: "")
        popUp.addItem(withTitle: "Duplicate")

        popUp.itemChosen(popUp.item(at: 1)!)

        XCTAssertNil(popUp.selectedItem, "a pull-down recorded a selection")
        XCTAssertEqual(popUp.accessibilityValue() as? String, "",
                       "a pull-down stopped showing its own first item")
    }

    /// The retargeting rule, which is why a pull-down works at all: an item that already knows
    /// what to do keeps its action, and only an unclaimed one is routed through the control.
    func testOnlyUnclaimedItemsAreRoutedThroughTheControl() {
        let popUp = ThemedPopUp()
        let owner = ActionSpy()
        let claimed = NSMenuItem(title: "Rename…", action: #selector(ActionSpy.fire), keyEquivalent: "")
        claimed.target = owner
        popUp.menu?.addItem(claimed)
        popUp.addItem(withTitle: "Unclaimed")

        popUp.adoptUnclaimedItems()

        XCTAssertTrue(claimed.target === owner, "an item's own target was taken over")
        XCTAssertEqual(claimed.action, #selector(ActionSpy.fire))
        XCTAssertTrue(popUp.item(at: 1)?.target === popUp, "an unclaimed item was left unrouted")
    }

    func testTheHelperBuildsAThemedPopUpNotAnNSPopUpButton() {
        let spy = ActionSpy()
        let control = SettingsUI.popUp(target: spy, action: #selector(ActionSpy.fire))
        XCTAssertTrue(control is ThemedPopUp, "SettingsUI.popUp still hands back a raw pop-up")
    }

    // MARK: - Pop-Up Theming

    /// A stock `NSPopUpButton` draws the system bezel whatever the theme is. This one draws its
    /// fill from the theme's own `controlResting`, which is not a shade of grey but part of the
    /// style: Cyberpunk holds its neon accent far down so every control glows faintly green,
    /// where Swiss is a neutral wash on paper.
    ///
    /// Sampled from the control's own drawing rather than from a composited page — the fill is
    /// translucent by design, and what is being claimed here is which colour it lays down.
    func testThePopUpFillTakesTheThemeSurface() {
        func fill(under theme: AppTheme) -> NSColor {
            AppThemePalette.set(theme)
            let popUp = ThemedPopUp(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            let rep = popUp.bitmapImageRepForCachingDisplay(in: popUp.bounds)!
            popUp.cacheDisplay(in: popUp.bounds, to: rep)
            // Inside the fill, clear of the border, the chevron and any title.
            return rep.colorAt(x: 60, y: 13)!.usingColorSpace(.sRGB)!
        }

        let cyber = fill(under: AppThemeStyles.cyberpunk)
        XCTAssertGreaterThan(cyber.greenComponent, cyber.redComponent + 0.5,
                             "Cyberpunk's pop-up is not drawn in its neon")

        let swiss = fill(under: AppThemeStyles.swissMinimalist)
        XCTAssertEqual(swiss.redComponent, swiss.greenComponent, accuracy: 0.02)
        XCTAssertEqual(swiss.greenComponent, swiss.blueComponent, accuracy: 0.02,
                       "Swiss's pop-up is not the neutral wash the style calls for")
    }

    /// The other half of a style's identity is its silhouette. Swiss squares every corner, so the
    /// pop-up's corner is filled; a rounded theme leaves it empty. A stock control would round
    /// both.
    func testThePopUpCornerFollowsTheThemeSilhouette() {
        func cornerAlpha(under theme: AppTheme) -> CGFloat {
            AppThemePalette.set(theme)
            let popUp = ThemedPopUp(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            let rep = popUp.bitmapImageRepForCachingDisplay(in: popUp.bounds)!
            popUp.cacheDisplay(in: popUp.bounds, to: rep)
            return rep.colorAt(x: 0, y: 0)!.alphaComponent
        }

        XCTAssertEqual(cornerAlpha(under: AppThemeStyles.swissMinimalist), 1, accuracy: 0.05,
                       "a square theme did not fill the pop-up's corner")
        XCTAssertLessThan(cornerAlpha(under: .system), 0.5,
                          "a rounded theme filled the pop-up's corner")
    }
}

// MARK: - Helpers

private final class ActionSpy: NSObject {
    private(set) var count = 0
    @objc func fire() { count += 1 }
}
