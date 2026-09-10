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

    /// The composer makes the provider of an accepted start the next new-session provider. Its
    /// render tests deliberately exercise every runtime, so this choice needs the redirect just
    /// as much as a theme does — otherwise an interrupted test run can leave the real app opening
    /// on OpenCode even when the developer never uses it.
    @MainActor
    func testAComposerProviderChoiceDoesNotTouchTheStandardDefaults() {
        let key = "defaultAgentKind"
        let previousScratchValue = PreferenceStore.shared.object(forKey: key)
        defer {
            if let previousScratchValue {
                PreferenceStore.shared.set(previousScratchValue, forKey: key)
            } else {
                PreferenceStore.shared.removeObject(forKey: key)
            }
        }
        let standardValue = UserDefaults.standard.string(forKey: key)
        let sentinel: AgentKind = standardValue == AgentKind.claude.rawValue ? .codex : .claude

        AppSettings.shared.defaultAgentKind = sentinel

        XCTAssertEqual(PreferenceStore.shared.string(forKey: key), sentinel.rawValue)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: key),
            standardValue,
            "a hosted composer test changed the provider the real app opens on"
        )
    }

    /// An origin grant controls access to a browser carrying the user's signed-in state. A bare
    /// production store is constructed by both the browser coordinator and Tools settings, so its
    /// default must follow the same redirect as every other recorded choice.
    @MainActor
    func testTheDefaultBrowserGrantStoreStaysOutOfTheUsersPreferences() throws {
        XCTAssertTrue(PreferenceStore.isRedirected)
        let origin = try XCTUnwrap(BrowserOrigin(url: XCTUnwrap(
            URL(string: "https://probe-\(UUID().uuidString.lowercased()).invalid/account")
        )))
        let store = BrowserAccessStore()
        let productionStore = BrowserAccessStore(defaults: .standard)
        XCTAssertFalse(productionStore.isPersistentlyAllowed(origin))
        defer {
            store.revoke(origin)
            // If the default ever regresses, remove only this unique probe and preserve every
            // real grant around it rather than replacing the developer's complete allowlist.
            productionStore.revoke(origin)
        }

        store.allowPersistently(origin)

        XCTAssertTrue(store.isPersistentlyAllowed(origin))
        XCTAssertFalse(
            productionStore.isPersistentlyAllowed(origin),
            "a hosted test wrote its browser grant into the developer's real allowlist"
        )
    }

    /// **And away from the other suite runs on the same machine.**
    ///
    /// The redirect above answers "not the user's preferences"; this answers "not another test
    /// host's either", which is a different question and was unanswered for as long as the suite
    /// name was a constant. Several agents run this suite at once in this repository, and a
    /// shared domain made them read each other's recorded choices: a test applied Cyberpunk and
    /// read Claymorphism back, a recovery test that stored `threading` read a contributed theme
    /// id no test in its own process had ever installed. It presents as flakiness with no
    /// culprit — every case passes alone, passes on a re-run, and bisects somewhere new each
    /// time — because the interfering write is not in this process at all.
    ///
    /// Asserted on the name rather than by spawning a second host: the pid is the whole
    /// mechanism, and a name carrying this process's pid cannot be a name another process picked.
    func testTheScratchSuiteBelongsToThisProcessAlone() throws {
        XCTAssertTrue(
            PreferenceStore.hostedTestSuiteName.hasPrefix(PreferenceStore.hostedTestSuitePrefix),
            "the sweep in scripts/test.sh finds these domains by prefix"
        )
        XCTAssertNotEqual(
            PreferenceStore.hostedTestSuiteName,
            PreferenceStore.hostedTestSuitePrefix,
            "one name for every test host is a domain two concurrent runs share"
        )

        let suffix = PreferenceStore.hostedTestSuiteName
            .dropFirst(PreferenceStore.hostedTestSuitePrefix.count)
            .drop(while: { $0 == "." })
        XCTAssertEqual(
            String(suffix),
            String(ProcessInfo.processInfo.processIdentifier),
            "the suite is not named after the process that owns it"
        )
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
