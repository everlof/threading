import Foundation
import XCTest
@testable import Threading

/// The suite runs **inside the shipping app**, so anything it writes to `UserDefaults.standard`
/// is written to the developer's own preferences.
///
/// The report was "theme selection doesn't persist between app launches", and the app was not
/// forgetting anything: `AppThemeLibrary.apply` records the choice on its first line, three test
/// classes apply a theme in `setUp`, and exactly one of them put the old value back — so the last
/// test to run answered the question, and the next launch honoured that answer. Measured before
/// the fix: a stored `swiss-minimalist` came back as `system` after one `-only-testing` run.
///
/// These hold the seam that ends it, rather than each test's memory to put things back.
final class PreferenceStoreTests: XCTestCase {

    func testAHostedTestBundleIsRedirectedAwayFromTheUsersPreferences() {
        XCTAssertTrue(
            PreferenceStore.isRedirected,
            "the suite is writing recorded choices into the developer's own preferences"
        )
        XCTAssertFalse(PreferenceStore.shared === UserDefaults.standard)
    }

    /// The specific write that was reaching the user, asserted at the library rather than at the
    /// key: any future store that records a choice should come through the same seam.
    @MainActor
    func testApplyingAnAppThemeDoesNotTouchTheStandardDefaults() {
        let key = "appThemeID"
        let sentinel = "sentinel-\(UUID().uuidString)"
        let preserved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(sentinel, forKey: key)
        defer {
            if let preserved {
                UserDefaults.standard.set(preserved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }

        AppThemeLibrary.apply(AppThemeStyles.cyberpunk)

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: key),
            sentinel,
            "a test applying a theme rewrote what the app launches into"
        )
        XCTAssertEqual(
            PreferenceStore.shared.string(forKey: key),
            AppThemeStyles.cyberpunk.id.rawValue,
            "the choice was not recorded anywhere, so nothing would restore it either"
        )
    }

    /// Custom palettes are a recorded choice too. A probe named "Reserved Name Probe" was found
    /// standing in the developer's real terminal-theme list, left by a suite run that failed
    /// before its cleanup.
    @MainActor
    func testACustomTerminalThemeCreatedByATestStaysOutOfTheUsersList() throws {
        let name = "Routing Probe \(UUID().uuidString.prefix(8))"
        var theme = TerminalTheme.basic
        theme.name = String(name)
        theme.id = TerminalThemeID("custom-\(UUID().uuidString.lowercased())")

        XCTAssertTrue(ThemeAssignments.create(theme))
        defer { _ = ThemeManager.shared.deleteTheme(theme) }

        let stored = UserDefaults.standard.data(forKey: "customTerminalThemes")
            .flatMap { try? JSONDecoder().decode([TerminalTheme].self, from: $0) } ?? []

        XCTAssertFalse(
            stored.contains { $0.id == theme.id },
            "a palette a test invented landed in the developer's own theme list"
        )
    }
}
