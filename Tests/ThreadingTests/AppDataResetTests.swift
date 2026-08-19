import AppKit
import XCTest
@testable import Threading

/// Starting over: what a reset takes, what it keeps, and what it must not reach.
///
/// Every case runs against injected locations under a temporary directory. A test that reset
/// the *live* ones would delete the developer's own preferences and projects, which is the one
/// bug this feature could plausibly ship — and `PreferenceStore`'s own note is the precedent:
/// the suite is hosted in the app, so "the app's state" and "the developer's state" are the
/// same state.
@MainActor
final class AppDataResetTests: XCTestCase {

    private var root: URL!
    private var domain: String!
    private var defaults: UserDefaults!
    private var locations: AppDataReset.Locations!

    /// A fixed instant, so the folder a reset makes has a name the test can name too.
    private let noon = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        domain = "codes.threading.reset-test.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        locations = AppDataReset.Locations(
            preferencesDomain: domain,
            support: root.appendingPathComponent("Threading", isDirectory: true),
            resets: root.appendingPathComponent("Threading Resets", isDirectory: true)
        )
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: domain)
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: - Helpers

    /// A support directory with something recognisable in it, standing in for the store.
    @discardableResult
    private func makeSupportDirectory(containing name: String = "threading.db") throws -> URL {
        try FileManager.default.createDirectory(
            at: locations.support,
            withIntermediateDirectories: true
        )
        let file = locations.support.appendingPathComponent(name)
        try Data("rows".utf8).write(to: file)
        return file
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func perform(_ scope: AppDataReset.Scope) throws -> AppDataReset.Outcome {
        try AppDataReset.perform(scope, at: noon, defaults: defaults, locations: locations)
    }

    // MARK: - Scope

    /// The narrow reset exists so a broken preference does not cost the conversations. If it
    /// took the store too there would be no reason to offer two.
    func testResettingSettingsLeavesEveryProjectAndSessionWhereItIs() throws {
        let store = try makeSupportDirectory()
        defaults.set("cyberpunk", forKey: "appThemeID")

        let outcome = try perform(.settings)

        XCTAssertTrue(exists(store), "resetting settings took the store with it")
        XCTAssertTrue(exists(locations.support), "resetting settings removed the data directory")
        XCTAssertFalse(outcome.tookSupportDirectory)
        XCTAssertNil(defaults.string(forKey: "appThemeID"), "the preference survived its reset")
    }

    /// The wide one is the first-launch state: the directory goes, and goes *whole*.
    func testResettingEverythingMovesTheDataDirectoryIntoTheBackup() throws {
        try makeSupportDirectory()
        defaults.set("cyberpunk", forKey: "appThemeID")

        let outcome = try perform(.everything)

        XCTAssertFalse(exists(locations.support), "the data directory stayed behind")
        XCTAssertTrue(outcome.tookSupportDirectory)
        XCTAssertTrue(
            exists(outcome.backup.appendingPathComponent("Threading/threading.db")),
            "the store did not arrive in the backup"
        )
    }

    // MARK: - Kept, Not Deleted

    /// The whole posture: a reset performed by mistake costs a drag back, and a store reset
    /// because it was corrupt is still there to be read.
    func testTheOldStateIsKeptInADatedFolderRatherThanDeleted() throws {
        try makeSupportDirectory()
        defaults.set("cyberpunk", forKey: "appThemeID")

        let outcome = try perform(.everything)

        // Matched by shape rather than by value: the stamp is deliberately in the user's own
        // time zone, so a literal here would pass in Stockholm and fail in Denver.
        XCTAssertNotNil(
            outcome.backup.lastPathComponent.range(
                of: #"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}$"#,
                options: .regularExpression
            ),
            "the backup folder is not named for the moment it was taken: "
                + outcome.backup.lastPathComponent
        )
        XCTAssertFalse(
            outcome.backup.lastPathComponent.contains(":"),
            "a colon in the name reads as a path separator in the Finder"
        )
        XCTAssertEqual(
            outcome.backup.deletingLastPathComponent().lastPathComponent,
            "Threading Resets"
        )

        let snapshot = outcome.backup.appendingPathComponent("preferences.plist")
        let restored = try XCTUnwrap(NSDictionary(contentsOf: snapshot) as? [String: Any])
        XCTAssertEqual(
            restored["appThemeID"] as? String,
            "cyberpunk",
            "the preferences were removed without being written down first"
        )
        XCTAssertTrue(outcome.tookPreferences)
    }

    /// A backup inside the directory being moved is not a backup. The two live side by side, so
    /// a second reset cannot carry the first one's contents off with it.
    func testASecondResetKeepsTheFirstOnesBackup() throws {
        try makeSupportDirectory()
        defaults.set("first", forKey: "appThemeID")
        let first = try perform(.everything)

        try makeSupportDirectory()
        defaults.set("second", forKey: "appThemeID")
        let second = try AppDataReset.perform(
            .everything,
            at: noon.addingTimeInterval(60),
            defaults: defaults,
            locations: locations
        )

        XCTAssertNotEqual(first.backup, second.backup)
        XCTAssertTrue(exists(first.backup), "the second reset swallowed the first one's backup")
        XCTAssertTrue(exists(first.backup.appendingPathComponent("Threading/threading.db")))
    }

    // MARK: - Reach

    /// The claim the page makes in as many words. Anything Threading wrote into *another*
    /// program's folder — the Claude status-line cache under `Claudex`, a session's hook config
    /// handed to an agent — is not Threading's to reset, and a reset that walked
    /// Application Support looking for its own leavings would take those too.
    func testNothingOutsideThreadingsOwnTwoLocationsIsTouched() throws {
        try makeSupportDirectory()
        let neighbour = root.appendingPathComponent("Claudex", isDirectory: true)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)
        let cache = neighbour.appendingPathComponent("ClaudeStatus.json")
        try Data("{}".utf8).write(to: cache)

        let otherDomain = "codes.threading.reset-test.bystander.\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherDomain))
        defer { otherDefaults.removePersistentDomain(forName: otherDomain) }
        otherDefaults.set("kept", forKey: "someoneElsesKey")

        _ = try perform(.everything)

        XCTAssertTrue(exists(cache), "a reset reached into another program's directory")
        XCTAssertEqual(
            otherDefaults.string(forKey: "someoneElsesKey"),
            "kept",
            "a reset emptied a domain that was not Threading's"
        )
    }

    /// An empty domain is not an error and not a snapshot: a first-launch app has nothing to
    /// write down, and a `preferences.plist` holding `{}` claims otherwise.
    func testAResetWithNothingStoredWritesNoSnapshot() throws {
        let outcome = try perform(.settings)

        XCTAssertFalse(outcome.tookPreferences)
        XCTAssertFalse(exists(outcome.backup.appendingPathComponent("preferences.plist")))
    }

    /// Resetting everything before anything has been written is the case a new install hits if
    /// it presses the button, and it must not throw its way to a half-reset.
    func testResettingEverythingWithNoDataDirectorySucceeds() throws {
        let outcome = try perform(.everything)

        XCTAssertFalse(outcome.tookSupportDirectory)
        XCTAssertTrue(exists(outcome.backup))
    }

    // MARK: - Locations

    /// Read from the bundle rather than written out, so a build under another identifier resets
    /// its own preferences instead of a string somebody typed into the source.
    func testThePreferencesDomainIsTheBundlesOwn() {
        XCTAssertEqual(AppDataLocations.preferencesDomain, Bundle.main.bundleIdentifier)
        XCTAssertTrue(
            AppDataLocations.preferencesFile.path.hasSuffix(
                "\(AppDataLocations.preferencesDomain).plist"
            )
        )
    }

    /// The reset folder is a **sibling** of the directory a reset moves, not a child of it.
    func testTheResetsFolderSitsBesideTheDataItHolds() {
        XCTAssertEqual(
            AppDataLocations.resetsDirectory.deletingLastPathComponent(),
            AppDataLocations.supportDirectory.deletingLastPathComponent()
        )
        XCTAssertFalse(
            AppDataLocations.resetsDirectory.path
                .hasPrefix(AppDataLocations.supportDirectory.path + "/")
        )
    }

    // MARK: - Relaunch

    /// `SingleInstanceLock` is an `flock` held for the process's lifetime, so a copy started
    /// before this one has finished exiting finds the lock and refuses to launch. The wait is
    /// the whole reason a shell is involved rather than `NSWorkspace`.
    func testTheRelauncherWaitsForTheInstanceLockToBeDropped() {
        let command = AppRelaunch.relaunchCommand(for: URL(fileURLWithPath: "/Applications/T.app"))

        XCTAssertEqual(command.first, "-c")
        let script = command[1]
        XCTAssertTrue(script.contains("read"), "the relauncher can run before reset commits")
        XCTAssertTrue(script.contains("sleep"), "the relauncher does not wait at all")
        XCTAssertTrue(script.contains("/usr/bin/open"))
        XCTAssertEqual(
            command.last,
            "/Applications/T.app",
            "the bundle path is not passed as an argument, so a path with a space would split"
        )
    }

    /// The helper is a precondition for mutation, not a best-effort epilogue. Otherwise a
    /// missing or unlaunchable shell lets Reset Everything move the data, quit the app, and
    /// simply never open it again.
    func testResetDoesNothingWhenTheRelauncherCannotBePrepared() {
        enum PreparationFailure: Error { case unavailable }
        var resetWasCalled = false

        XCTAssertThrowsError(
            try AppDataResetFlow.perform(
                .settings,
                at: noon,
                prepareRelaunch: { throw PreparationFailure.unavailable },
                reset: { _, _ in
                    resetWasCalled = true
                    throw PreparationFailure.unavailable
                }
            )
        )
        XCTAssertFalse(resetWasCalled, "the reset began before relaunch was proved possible")
    }

    func testAnUnlaunchableHelperIsReported() {
        XCTAssertThrowsError(
            try AppRelaunch.prepare(
                for: URL(fileURLWithPath: "/Applications/T.app"),
                executableURL: root.appendingPathComponent("missing-shell")
            )
        )
    }

    // MARK: - The Page

    /// The page is reachable, and searchable by the words somebody in trouble would actually
    /// type — "reset" and "start over" rather than "advanced".
    func testTheAdvancedPageIsInTheCatalogueAndFoundByWhatItDoes() throws {
        let page = try XCTUnwrap(
            SettingsPages.builtIn.first { $0.id == SettingsPages.advancedID },
            "the Advanced page is not in the settings catalogue"
        )

        for term in ["reset", "start over", "corrupt", "location"] {
            XCTAssertTrue(
                page.searchableText.localizedCaseInsensitiveContains(term),
                "Settings search does not find the reset page by \"\(term)\""
            )
        }
        XCTAssertNil(page.hostPage, "an extension can contribute rows to the reset page")
    }

    /// Both resets and every reveal are on it, and the reset buttons say so with an ellipsis —
    /// the platform's own promise that a button asks before it acts.
    ///
    /// The reveal count is guarded the way the page itself is: a development build carries a
    /// third location for the report outbox, because reports pile up in a folder nobody collects
    /// from when no intake is configured. Asserting the same condition the page branches on keeps
    /// this a count rather than a floor — a fourth row appearing unannounced still fails here.
    func testThePageOffersBothResetsAndBothLocations() throws {
        let page = try XCTUnwrap(
            SettingsPages.builtIn.first { $0.id == SettingsPages.advancedID }
        )
        let controller = page.make()
        controller.loadView()
        controller.viewDidLoad()
        controller.view.layoutSubtreeIfNeeded()

        let titles = descendants(of: controller.view)
            .compactMap { ($0 as? ThemedButton)?.title }

#if DEBUG
        let expectedReveals = 3
#else
        let expectedReveals = 2
#endif
        XCTAssertEqual(titles.filter { $0 == AdvancedStrings.reveal }.count, expectedReveals)
        XCTAssertTrue(titles.contains(AdvancedStrings.resetSettingsButton))
        XCTAssertTrue(titles.contains(AdvancedStrings.resetEverythingButton))
        XCTAssertTrue(
            AdvancedStrings.resetEverythingButton.hasSuffix("…"),
            "a button that asks first has to say so"
        )
    }

    /// Both paths are shown rather than described, since the answer to "where is my data" is
    /// something to be copied.
    func testThePageNamesBothLocationsAsPaths() throws {
        let page = try XCTUnwrap(
            SettingsPages.builtIn.first { $0.id == SettingsPages.advancedID }
        )
        let controller = page.make()
        controller.loadView()
        controller.viewDidLoad()

        let strings = descendants(of: controller.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertTrue(
            strings.contains { $0.hasSuffix(".plist") && $0.hasPrefix("~") },
            "the preferences file is not shown as a path"
        )
        XCTAssertTrue(
            strings.contains { $0.hasSuffix("/Threading") && $0.hasPrefix("~") },
            "the data directory is not shown as a path"
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
