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
}
