import XCTest
@testable import Threading

/// A failed *load* must not authorise the *overwrite* that follows it.
///
/// `ProjectStore` learned this for `projects.json` — quarantine the unreadable bytes, and permit
/// writes only if that succeeded. The small stores keeping their state as one encoded blob in
/// `UserDefaults` had the same hole with worse odds: a decode failure fell through to defaults,
/// and for a settings store the *next save is any ordinary edit*. One schema change would erase
/// a user's keyboard bindings or their account names the first time they touched either.
@MainActor
final class DefaultsQuarantineTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "codes.threading.tests.quarantine.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - The helper

    func testUnreadableBytesAreKeptUnderTheirOwnKey() throws {
        let original = Data("not json at all".utf8)
        defaults.set(original, forKey: "example")

        XCTAssertTrue(DefaultsQuarantine.quarantine(original, forKey: "example", in: defaults))
        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "example")),
            original,
            "the unreadable value was not kept"
        )
    }

    /// One slot per key: a second failure means the first quarantine has already been superseded
    /// by whatever the user did next, and an unbounded pile of dead blobs is its own small bug.
    func testASecondFailureReplacesTheFirstQuarantine() {
        DefaultsQuarantine.quarantine(Data("first".utf8), forKey: "example", in: defaults)
        DefaultsQuarantine.quarantine(Data("second".utf8), forKey: "example", in: defaults)

        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "example")),
            Data("second".utf8)
        )
    }

    // MARK: - Shortcut overrides

    func testUnreadableShortcutOverridesAreKeptRatherThanOverwritten() throws {
        let corrupt = Data("{".utf8)
        defaults.set(corrupt, forKey: "keyboardShortcutOverrides")

        let store = ShortcutOverrideStore(defaults: defaults)
        let command = try XCTUnwrap(CommandRegistry.shared.all.first(where: \.isEditable))

        // The edit lands, because the bytes it would destroy were kept first.
        store.setShortcut(KeyboardShortcut(key: "j", modifiers: [.command]), for: command)

        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "keyboardShortcutOverrides")),
            corrupt,
            "the unreadable overrides were overwritten without being kept"
        )
        XCTAssertNotEqual(
            defaults.data(forKey: "keyboardShortcutOverrides"),
            corrupt,
            "the store never wrote the user's new binding"
        )
    }

    /// A store with nothing saved yet is not a store that failed to load: the first run must
    /// write normally, and must not leave a quarantine behind.
    func testAFirstRunWritesNormallyAndQuarantinesNothing() throws {
        let store = ShortcutOverrideStore(defaults: defaults)
        let command = try XCTUnwrap(CommandRegistry.shared.all.first(where: \.isEditable))

        store.setShortcut(KeyboardShortcut(key: "k", modifiers: [.command]), for: command)

        XCTAssertNotNil(defaults.data(forKey: "keyboardShortcutOverrides"))
        XCTAssertNil(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "keyboardShortcutOverrides")),
            "a first run left a quarantine behind"
        )
    }

    /// Readable overrides still load, which is the case every launch actually takes.
    func testReadableOverridesSurviveARoundTrip() throws {
        let command = try XCTUnwrap(CommandRegistry.shared.all.first(where: \.isEditable))
        let shortcut = KeyboardShortcut(key: "l", modifiers: [.command, .shift])

        ShortcutOverrideStore(defaults: defaults).setShortcut(shortcut, for: command)

        let reopened = ShortcutOverrideStore(defaults: defaults)
        XCTAssertEqual(reopened.shortcut(for: command), shortcut)
    }

    // MARK: - Shared recoverable stores

    func testFutureEnvelopeIsUnreadableUntilAnExplicitMigrationExists() {
        let future = Data(#"{"formatVersion":99,"value":{"old":"state"}}"#.utf8)
        defaults.set(future, forKey: "versioned")
        let store = RecoverableDefaultsStore<[String: String]>(
            defaults: defaults,
            key: "versioned",
            criticality: .preference
        )

        let outcome = store.load(defaultValue: [:])
        guard case .unreadable(let fallback, let recovery) = outcome else {
            return XCTFail("A future format must not be guessed at")
        }
        XCTAssertEqual(fallback, [:])
        XCTAssertEqual(
            recovery,
            .defaultsKey(DefaultsQuarantine.quarantineKey(for: "versioned"))
        )
        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "versioned")),
            future
        )
    }

    func testUnreadableProfilesArePreservedBeforeAnEdit() {
        let corrupt = Data("{".utf8)
        defaults.set(corrupt, forKey: "terminalProfiles")
        let storage = ProfileStorage(defaults: defaults)

        XCTAssertEqual(storage.profiles, [.default])

        var replacement = TerminalProfile.default
        replacement.shellPath = "/bin/zsh"
        storage.save(replacement)

        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "terminalProfiles")),
            corrupt
        )
        XCTAssertEqual(
            ProfileStorage(defaults: defaults).defaultProfile.shellPath,
            "/bin/zsh"
        )
    }

    func testUnreadableAISettingsArePreservedBeforeAnEdit() {
        let corrupt = Data(#"{"providerType":"future-provider"}"#.utf8)
        defaults.set(corrupt, forKey: "aiSettings")
        let storage = AISettingsStorage(defaults: defaults)

        XCTAssertEqual(storage.settings, .default)

        var replacement = AISettings.default
        replacement.providerType = .ollama
        storage.settings = replacement

        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "aiSettings")),
            corrupt
        )
        XCTAssertEqual(
            AISettingsStorage(defaults: defaults).settings.providerType,
            .ollama
        )
    }

    func testUnreadableTokenUsageIsPreservedAndNewCountsRoundTrip() async {
        let corrupt = Data("{".utf8)
        defaults.set(corrupt, forKey: "tokenUsage")
        let manager = TokenUsageManager(defaults: defaults)

        await manager.record(model: "safe-model", inputTokens: 3, outputTokens: 5)

        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "tokenUsage")),
            corrupt
        )
        let reopened = TokenUsageManager(defaults: defaults)
        let total = await reopened.total(for: "safe-model")
        XCTAssertEqual(total, TokenUsage(inputTokens: 3, outputTokens: 5))
    }

    func testUnreadableTerminalThemesArePreservedBeforeCreatingAPalette() {
        let corrupt = Data("{".utf8)
        defaults.set(corrupt, forKey: "customTerminalThemes")
        let manager = ThemeManager(defaults: defaults)
        let theme = TerminalTheme.ocean.duplicated(named: "Recovered Ocean")

        manager.addTheme(theme)

        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "customTerminalThemes")),
            corrupt
        )
        XCTAssertEqual(
            ThemeManager(defaults: defaults).customThemes.map(\.id),
            [theme.id]
        )
    }

    func testUnreadableAppThemesArePreservedBeforeCreatingATheme() {
        let corrupt = Data("{".utf8)
        defaults.set(corrupt, forKey: "customAppThemes")
        let store = AppThemeStore(defaults: defaults)

        store.insert(AppThemeStyles.cyberpunk)

        XCTAssertEqual(
            defaults.data(forKey: DefaultsQuarantine.quarantineKey(for: "customAppThemes")),
            corrupt
        )
        XCTAssertEqual(
            AppThemeStore(defaults: defaults).themes.map(\.id),
            [AppThemeStyles.cyberpunk.id]
        )
    }
}
