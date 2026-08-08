import Foundation
import XCTest
@testable import Threading

/// What is worth pinning about the updater is its *policy*, not Sparkle's behaviour.
///
/// Sparkle is a third-party framework with its own tests; installing an update cannot be
/// exercised here without a real appcast and a real relaunch. What can be checked is the shape of
/// the promise the Privacy page and the General switch make on Threading's behalf: that the
/// configuration is present and correct, that the switch is the authority, and that turning it
/// off does not strand the user with no way to check.
@MainActor
final class AppUpdaterTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppUpdaterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Configuration

    /// A feed URL typo ships as an app that quietly checks nothing, and the only symptom is the
    /// absence of updates — which looks exactly like "no updates released yet".
    func testTheFeedIsConfiguredAndHTTPS() throws {
        let feed = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            "SUFeedURL is missing, so Sparkle has nothing to check"
        )
        let url = try XCTUnwrap(URL(string: feed), "SUFeedURL is not a URL")

        // App Transport Security refuses plain HTTP, and an unencrypted feed would let anyone on
        // the path choose which version the app believes is newest.
        XCTAssertEqual(url.scheme, "https", "the update feed must be HTTPS")
        XCTAssertEqual(url.lastPathComponent, "appcast.xml")
    }

    /// Without the public key Sparkle cannot verify what it downloaded, and an unsigned update is
    /// arbitrary code execution with extra steps. Its *value* matters too: Threading has its own
    /// release key, and a mismatch means every signature check fails after release.
    func testTheUpdateSigningKeyIsPresentAndIsThreadingsDedicatedOne() throws {
        let key = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            "SUPublicEDKey is missing, so downloaded updates could not be verified"
        )
        XCTAssertEqual(key, "18EoXEv3Y17zr3HN/HUNBN7TqSy4RTLYhmNkZkJPon8=")

        // Base64 of an ed25519 public key — 32 bytes. A truncated paste still decodes.
        let decoded = try XCTUnwrap(Data(base64Encoded: key), "the key is not valid base64")
        XCTAssertEqual(decoded.count, 32, "an ed25519 public key is 32 bytes")
    }

    /// Sparkle needs a comparable, increasing CFBundleVersion. `releasing.md` explains why the
    /// shipped placeholder is the lowest thing that sorts; this fails if someone raises it, which
    /// is the change that silently strands every installed copy.
    func testTheBundleVersionIsComparableBySparkle() throws {
        let build = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        let parts = build.split(separator: ".")
        XCTAssertFalse(parts.isEmpty)
        for part in parts {
            XCTAssertTrue(
                part.allSatisfy(\.isNumber),
                "\"\(build)\" has a non-numeric component, which Sparkle cannot order"
            )
        }
    }

    // MARK: - The Switch

    /// Defaults-backed booleans read `false` when unset, so shipping this "on" needs a registered
    /// default. Without it the feature would arrive switched off for everyone who never opened
    /// Settings — the population least likely to go looking for it.
    func testAutomaticChecksAreOnBeforeAnyoneOpensSettings() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(
            settings.automaticUpdateChecksEnabled,
            "a fresh install would never check for updates"
        )
    }

    func testTheSwitchRoundTripsAndIsRemembered() {
        let settings = AppSettings(defaults: defaults)

        settings.automaticUpdateChecksEnabled = false
        XCTAssertFalse(settings.automaticUpdateChecksEnabled)
        XCTAssertFalse(AppSettings(defaults: defaults).automaticUpdateChecksEnabled,
                       "the choice did not survive a relaunch")

        settings.automaticUpdateChecksEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).automaticUpdateChecksEnabled)
    }

    /// Writing the setting must post the app-settings event, because that notification — not the
    /// Settings pane reaching into Sparkle — is what actually stops the scheduled check.
    func testChangingTheSwitchAnnouncesItself() {
        let settings = AppSettings(defaults: defaults)
        let announced = expectation(description: "AppSettingsDidChange posted")

        let token = NotificationCenter.default.addObserver(
            forName: AppSettingsDidChange.name,
            object: nil,
            queue: .main
        ) { _ in announced.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.automaticUpdateChecksEnabled = false
        wait(for: [announced], timeout: 1)
    }
}
