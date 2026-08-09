import XCTest
@testable import Threading

/// Switching a login off.
///
/// An account is discovered from a config directory, so it cannot be deleted from inside the
/// app — turning it off is how a user with five logins stops being asked about four of them.
/// What that must *not* do is lose anything: the directory stays, the conversations stay, and a
/// session already running on the account still resolves to it.
@MainActor
final class AccountEnablementTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: AccountPreferencesStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "AccountEnablementTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = AccountPreferencesStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Stored State

    func testAnUntouchedAccountIsOn() {
        XCTAssertTrue(store.isEnabled(.init(provider: .claude, handle: .standard)))
    }

    func testSwitchingOffPersistsAndSwitchingBackOnLeavesNothingBehind() throws {
        let id = AccountID(provider: .claude, handle: .named("claude-work"))

        store.setEnabled(false, for: id)
        XCTAssertFalse(store.isEnabled(id))

        let reloaded = AccountPreferencesStore(defaults: defaults)
        XCTAssertFalse(reloaded.isEnabled(id), "the switch did not survive a relaunch")

        // Enabling clears the flag rather than storing `false`, so a re-enabled account and one
        // nobody ever touched are the same stored value — and the entry goes away entirely.
        reloaded.setEnabled(true, for: id)
        XCTAssertTrue(reloaded.isEnabled(id))
        XCTAssertEqual(reloaded.preference(for: id), AccountPreference())
    }

    /// The switch is one of three things stored per account, and it must not take the other two
    /// with it in either direction.
    func testTheSwitchAndThePresentationAreIndependent() {
        let id = AccountID(provider: .codex, handle: .named("codex-alt"))

        store.setEmoji("🌀", for: id)
        store.setDisplayNameOverride("Night Shift", for: id)
        store.setEnabled(false, for: id)

        XCTAssertEqual(store.emoji(for: id), "🌀")
        XCTAssertEqual(store.displayNameOverride(for: id), "Night Shift")

        // Restore Name & Icon is about presentation and says nothing about whether the account
        // is in use.
        store.clearPresentation(for: id)
        XCTAssertNil(store.emoji(for: id))
        XCTAssertNil(store.displayNameOverride(for: id))
        XCTAssertFalse(
            store.isEnabled(id),
            "restoring the name and icon quietly put a switched-off login back in use"
        )
    }

    func testThePresentationRestoreNamesExactlyWhatItChanges() {
        XCTAssertEqual(
            AccountsPreferencesStrings.restorePresentationButton,
            "Restore Name & Icon"
        )
        XCTAssertFalse(
            AccountsPreferencesStrings.restorePresentationButton.localizedCaseInsensitiveContains(
                "reset"
            ),
            "the account action can still be mistaken for resetting usage limits"
        )
    }

    /// Preferences stored before the switch existed carry no such key, and a decoder that
    /// treated the absence as a failure would drop every icon and name the user had set.
    func testPreferencesWrittenBeforeTheSwitchStillDecodeAsOn() throws {
        let legacy = Data(#"{"emoji":"✳️","displayNameOverride":"Daniel"}"#.utf8)
        let decoded = try JSONDecoder().decode(AccountPreference.self, from: legacy)

        XCTAssertEqual(decoded.emoji, "✳️")
        XCTAssertEqual(decoded.displayNameOverride, "Daniel")
        XCTAssertNil(decoded.isDisabled)
        XCTAssertFalse(decoded.isEmpty)
    }

    // MARK: - What The Rest Of The App Sees

    /// The composer starts on the standard handle, so a disabled *default* is the case that
    /// matters: without this the login the user just switched off is still what a fresh session
    /// launches on, while the chip names it as though it were chosen.
    func testTheOfferedAccountSkipsASwitchedOffDefault() {
        let standard = account(handle: .standard, isEnabled: false)
        let alternate = account(handle: .named("claude-work"))

        XCTAssertEqual(
            AgentAccountDiscovery.preferred(among: [standard, alternate])?.handle,
            alternate.handle
        )
    }

    func testTheDefaultIsStillPreferredWhenItIsOn() {
        let standard = account(handle: .standard)
        let alternate = account(handle: .named("claude-work"))

        XCTAssertEqual(
            AgentAccountDiscovery.preferred(among: [alternate, standard])?.handle,
            standard.handle
        )
    }

    func testAProviderWithEveryLoginSwitchedOffOffersNone() {
        let discovered = [
            account(handle: .standard, isEnabled: false),
            account(handle: .named("claude-work"), isEnabled: false)
        ]

        XCTAssertNil(AgentAccountDiscovery.preferred(among: discovered))
    }

    // MARK: - Helpers

    private func account(
        handle: AccountHandle,
        isEnabled: Bool = true
    ) -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: handle,
            configPath: "/tmp/\(handle.name)",
            isEnabled: isEnabled
        )
    }
}
