import XCTest
@testable import Threading

/// Where a user-authored limit is stored, and which of the two scopes answers.
///
/// A limit is an **account** fact, so this feature uses two of the app's three scopes — app-wide
/// and the account's own answer — and deliberately offers neither project nor session, because a
/// per-session budget is an *authority* rather than a limit.
@MainActor
final class CustomLimitSettingsTests: XCTestCase {

    /// One scratch suite for the whole class, cleared at both ends.
    ///
    /// A fresh `UUID` suite per *test method* is the obvious shape and the wrong one: each is a
    /// real preferences domain the daemon then holds, a run of this target left a hundred of them
    /// behind, and `scripts/test.sh` sweeps them afterwards precisely because they accumulate.
    /// Clearing in `setUp` as well as `tearDown` buys the same isolation — a crashed test's
    /// leftovers are gone before the next one reads anything — at four domains instead of forty.
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: CustomLimitSettings!
    private var accounts: AccountPreferencesStore!

    private let account = AccountID(provider: .claude, handle: .named("claude-work"))

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "CustomLimitSettingsTests"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        settings = CustomLimitSettings(defaults: defaults)
        accounts = AccountPreferencesStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - The Two Scopes

    /// Absent means inherit. An account nobody has touched runs on whatever the app-wide default
    /// says.
    func testAnUntouchedAccountInheritsTheAppWideRules() {
        settings.defaultLimits = [.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)]

        XCTAssertTrue(settings.inheritsDefaults(for: account, store: accounts))
        XCTAssertEqual(settings.rules(for: account, store: accounts).count, 1)
    }

    /// Empty means none — a distinct instruction from absent, and the only way to say "this
    /// account has no limits, whatever the app-wide default says". A plain array could not
    /// express it, and the account whose owner cleared its rules would silently pick the app
    /// default back up.
    func testAnAccountWithNoRulesOfItsOwnIsNotTheSameAsOneThatHasNotAnswered() {
        settings.defaultLimits = [.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)]

        accounts.setCustomLimits([], for: account)

        XCTAssertFalse(settings.inheritsDefaults(for: account, store: accounts))
        XCTAssertTrue(
            settings.rules(for: account, store: accounts).isEmpty,
            "clearing an account's rules quietly handed it the app-wide ones back"
        )
    }

    /// Adding the first rule takes the account off the defaults and **brings what it had**.
    ///
    /// The other reading — a new rule replacing the inherited ones — is surprising in the
    /// direction that silently stops telling somebody about their quota.
    func testAddingARuleTakesTheAccountOffTheDefaultsAndKeepsWhatItHad() {
        let inherited = CustomLimit.everyStep(windowID: UsageDefaults.weeklyWindowID, step: 0.1)
        settings.defaultLimits = [inherited]

        settings.add(
            .alert(windowID: UsageDefaults.fiveHourWindowID, at: 0.9),
            for: account,
            store: accounts
        )

        let rules = settings.rules(for: account, store: accounts)
        XCTAssertEqual(rules.map(\.windowID), [UsageDefaults.weeklyWindowID, UsageDefaults.fiveHourWindowID])
        XCTAssertFalse(settings.inheritsDefaults(for: account, store: accounts))
        XCTAssertEqual(
            settings.defaultLimits.map(\.id),
            [inherited.id],
            "editing one account rewrote the app-wide list"
        )
    }

    /// Removing an inherited rule has to *work*. A Remove button that does nothing because the
    /// list it was drawn from belongs to another scope is the quietest kind of broken.
    func testAnInheritedRuleCanBeRemovedFromOneAccount() {
        let first = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        let second = CustomLimit.alert(windowID: UsageDefaults.fiveHourWindowID, at: 0.9)
        settings.defaultLimits = [first, second]

        settings.remove(ruleID: first.id, for: account, store: accounts)

        XCTAssertEqual(settings.rules(for: account, store: accounts).map(\.id), [second.id])
        XCTAssertEqual(
            settings.defaultLimits.map(\.id),
            [first.id, second.id],
            "removing a rule from one account removed it everywhere"
        )
    }

    /// The app-wide list is edited on its own terms, and its backstop is the same one.
    func testTheAppWideListIsEditedAndBounded() throws {
        for index in 0..<(CustomLimitDefaults.maximumRulesPerAccount + 3) {
            settings.addDefault(.alert(windowID: "window-\(index)", at: 0.5))
        }
        XCTAssertEqual(settings.defaultLimits.count, CustomLimitDefaults.maximumRulesPerAccount)

        let first = try XCTUnwrap(settings.defaultLimits.first)
        settings.removeDefault(ruleID: first.id)
        XCTAssertEqual(
            settings.defaultLimits.count,
            CustomLimitDefaults.maximumRulesPerAccount - 1
        )
    }

    /// Handing an account back to the defaults is a real instruction, and nil is how it is given.
    func testAnAccountCanBeHandedBackToTheDefaults() {
        settings.defaultLimits = [.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)]
        accounts.setCustomLimits([], for: account)

        accounts.setCustomLimits(nil, for: account)

        XCTAssertTrue(settings.inheritsDefaults(for: account, store: accounts))
        XCTAssertEqual(settings.rules(for: account, store: accounts).count, 1)
    }

    // MARK: - Persistence

    func testRulesSurviveARelaunch() throws {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.75)
        settings.add(rule, for: account, store: accounts)
        settings.defaultLimits = [.everyStep(windowID: UsageDefaults.weeklyWindowID, step: 0.25)]
        settings.alertsEnabled = false

        let reopenedAccounts = AccountPreferencesStore(defaults: defaults)
        let reopenedSettings = CustomLimitSettings(defaults: defaults)

        XCTAssertEqual(try XCTUnwrap(reopenedAccounts.customLimits(for: account)).first?.id, rule.id)
        XCTAssertEqual(reopenedSettings.defaultLimits.count, 1)
        XCTAssertFalse(reopenedSettings.alertsEnabled)
    }

    /// A limit is one of several things stored per account, and adding one must not disturb the
    /// icon, the name or the switch beside it.
    func testALimitDoesNotDisturbTheRestOfTheAccountRecord() {
        accounts.setEmoji("✳️", for: account)
        accounts.setDisplayNameOverride("Night Shift", for: account)
        accounts.setEnabled(false, for: account)

        settings.add(.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5), for: account, store: accounts)

        XCTAssertEqual(accounts.emoji(for: account), "✳️")
        XCTAssertEqual(accounts.displayNameOverride(for: account), "Night Shift")
        XCTAssertFalse(accounts.isEnabled(account))
    }

    /// Preferences written before limits existed carry no such key, and a decoder that treated
    /// the absence as a failure would drop every icon and name the user had set.
    func testPreferencesWrittenBeforeLimitsStillDecode() throws {
        let legacy = Data(#"{"emoji":"✳️","isDisabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AccountPreference.self, from: legacy)

        XCTAssertEqual(decoded.emoji, "✳️")
        XCTAssertNil(decoded.customLimits)
        XCTAssertFalse(decoded.isEmpty)
    }

    /// The account record is dropped entirely when nothing is left in it, limits included —
    /// otherwise removing the last rule would leave a placeholder behind that reads as "this
    /// account answered".
    func testRemovingEverythingLeavesNoPlaceholder() {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        settings.add(rule, for: account, store: accounts)
        settings.remove(ruleID: rule.id, for: account, store: accounts)

        XCTAssertEqual(accounts.customLimits(for: account), [])
        accounts.setCustomLimits(nil, for: account)
        XCTAssertEqual(accounts.preference(for: account), AccountPreference())
    }

    /// The count backstop keeps a stuck Add from manufacturing a preference blob the next launch
    /// would refuse to read.
    func testAnAccountStopsTakingRulesAtTheBackstop() {
        for index in 0..<(CustomLimitDefaults.maximumRulesPerAccount + 3) {
            settings.add(
                .alert(windowID: "window-\(index)", at: 0.5),
                for: account,
                store: accounts
            )
        }

        XCTAssertEqual(
            accounts.customLimits(for: account)?.count,
            CustomLimitDefaults.maximumRulesPerAccount
        )
    }

    // MARK: - Validation

    /// A bound of zero is permanently crossed, so a blob carrying one is refused rather than
    /// loaded into a rule that notifies on every reading forever.
    func testAStoredRuleWithAnImpossibleBoundIsRefused() throws {
        var broken = CustomLimit(windowID: UsageDefaults.weeklyWindowID, bound: 0.5)
        broken.bound = 0

        XCTAssertFalse(CustomLimitSettings.isWellFormed(broken))
        XCTAssertTrue(
            CustomLimitSettings.isWellFormed(
                CustomLimit(windowID: UsageDefaults.weeklyWindowID, bound: 0.5)
            )
        )
    }
}
