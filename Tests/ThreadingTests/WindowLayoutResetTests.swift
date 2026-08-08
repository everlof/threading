import AppKit
import XCTest
@testable import Threading

/// Forgetting where the user left the window and its dividers.
///
/// The offer earns its place because `setFrameUsingName` is the one door into a window's frame
/// that AppKit does not police — measured, it calls `constrainFrameRect(_:to:)` not at all — so a
/// frame saved on a display that no longer exists comes back whole, and a window that opens
/// somewhere unusable is indistinguishable, from the outside, from an app that will not start.
@MainActor
final class WindowLayoutResetTests: XCTestCase {

    // MARK: - Fixture

    /// The five values a reset clears, named here as the test's own list. Deliberately a second
    /// spelling: if a key moves and only one of the two changes, this fails, which is the whole
    /// point of a reset having a test at all.
    private let preferenceKeys = [
        "ThreadingSidebarWidth",
        "ThreadingDisplayPaneWidth",
        "ThreadingShowsStatusCard"
    ]
    private let standardKeys = ["ThreadingShellDrawerHeight"]
    private var frameKey: String { "NSWindow Frame \(MainWindowDefaults.frameAutosaveName)" }

    private func writeEverything() {
        SidebarWidth.record(SidebarDefaults.minWidth + 40)
        DisplayPaneWidth.stored = DisplayPaneDefaults.minWidth + 40
        StatusCardVisibility.isEnabled = false
        ShellDrawerHeight.stored = ShellDrawerDefaults.minimumHeight + 40
        UserDefaults.standard.set("0 0 800 600 0 0 1440 900 ", forKey: frameKey)
    }

    override func tearDown() {
        for key in preferenceKeys { PreferenceStore.shared.removeObject(forKey: key) }
        for key in standardKeys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: frameKey)
        super.tearDown()
    }

    // MARK: - Tests

    func testEveryRememberedGeometryIsForgotten() {
        writeEverything()
        for key in preferenceKeys {
            XCTAssertNotNil(PreferenceStore.shared.object(forKey: key), "\(key) was not written")
        }
        for key in standardKeys {
            XCTAssertNotNil(UserDefaults.standard.object(forKey: key), "\(key) was not written")
        }
        XCTAssertNotNil(UserDefaults.standard.object(forKey: frameKey))

        WindowLayoutReset.perform()

        for key in preferenceKeys {
            XCTAssertNil(PreferenceStore.shared.object(forKey: key), "\(key) survived the reset")
        }
        for key in standardKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key) survived the reset")
        }
        XCTAssertNil(
            UserDefaults.standard.object(forKey: frameKey),
            "the window frame survived the reset, which is the value the offer exists for"
        )
    }

    /// Each value goes back to the answer it gives when nobody has ever chosen one, which is not
    /// the same as being set to a default: the status card is on when *absent*, so a reset that
    /// wrote `true` would be recording a choice nobody made.
    func testTheValuesReturnToTheirNeverAskedAnswers() {
        writeEverything()
        WindowLayoutReset.perform()

        XCTAssertNil(SidebarWidth.stored)
        XCTAssertEqual(DisplayPaneWidth.stored, DisplayPaneDefaults.defaultWidth)
        XCTAssertTrue(StatusCardVisibility.isEnabled)
        XCTAssertEqual(
            ShellDrawerHeight.stored,
            ShellDrawerDefaults.defaultHeight + ThemedTabStripView.bandHeight
        )
    }

    /// A reset is geometry only. It must not reach a behavioural setting or a theme — the two
    /// resets on the Advanced page are what those are for, and both say so before they run.
    func testItTouchesNothingButGeometry() {
        let theme = AppThemeLibrary.storedThemeID
        let grouping = AppSettings.shared.groupsSessionsByBranch

        writeEverything()
        WindowLayoutReset.perform()

        XCTAssertEqual(AppThemeLibrary.storedThemeID, theme)
        XCTAssertEqual(AppSettings.shared.groupsSessionsByBranch, grouping)
    }

    /// Clearing what was never set is not an error, and not a write either: the offer is on a
    /// crash screen, where a second press must be as safe as the first.
    func testResettingTwiceIsSafe() {
        WindowLayoutReset.perform()
        WindowLayoutReset.perform()

        XCTAssertNil(SidebarWidth.stored)
    }
}
