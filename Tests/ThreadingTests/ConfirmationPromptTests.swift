import AppKit
import XCTest
@testable import Threading

/// The register of every question the app stops to ask.
///
/// The forcing function itself — `policy`'s exhaustive `switch` — is enforced by the compiler
/// and needs no test. What needs one is everything the compiler cannot see: that raw values on
/// disk are stable, that a prompt reclassified as non-negotiable stops honouring a suppression
/// somebody wrote before the reclassification, and that the one switch this replaced hands its
/// value over rather than being dropped.
@MainActor
final class ConfirmationPromptTests: XCTestCase {

    private func settings(
        _ body: (AppSettings, UserDefaults, String) throws -> Void
    ) rethrows {
        let suite = "Confirmations.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not make a defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults), defaults, suite)
    }

    // MARK: - The register

    /// Raw values are the stored suppressed set. A rename un-suppresses a prompt somebody
    /// switched off, which reads as the setting having been ignored — so the list is written
    /// down here rather than asked for nicely in a doc comment. Adding a case is meant to fail
    /// this test once, deliberately; renaming one is meant to fail it forever.
    func testTheRegistersRawValuesAreTheOnesOnDisk() {
        XCTAssertEqual(ConfirmationPrompt.allCases.map(\.rawValue), [
            "closeRunningSession",
            "archiveRunningSession",
            "moveRunningSessionToAccount",
            "continueRunningSessionWithAnotherProvider",
            "switchRunningSessionSurface",
            "quitWithRunningAgents",
            "removeExtension",
            "revokeAllWebsiteAccess",
            "removeProject",
            "deleteSession",
            "deleteArchivedSession",
            "deleteAppTheme",
            "deleteTerminalTheme",
            "removeReclaimableDirectories",
            "approveAgentStorageCleanup",
            "resetAppData",
            "clearBrowserWebsiteData",
            "runDestructiveExtensionCommand",
            "grantBrowserOriginAccess",
            "approveSensitiveBrowserAction",
            "approveToolPermission",
            "installUnsignedExtension",
            "updateExtensionCapabilities",
            "approveAgentExtensionInstall",
            "shareChatLink"
        ])
    }

    /// A suppressible prompt with no settings row is a switch the user cannot find, and a row
    /// sharing another's wording is a switch they cannot tell apart. The payload makes the
    /// first unwritable; this covers the second.
    func testEverySuppressiblePromptCarriesDistinctSettingsCopy() {
        let suppressions = ConfirmationPrompt.suppressible.compactMap(\.suppression)
        XCTAssertEqual(suppressions.count, ConfirmationPrompt.suppressible.count)

        let titles = suppressions.map(\.settingsTitle)
        let subtitles = suppressions.map(\.settingsSubtitle)
        XCTAssertFalse(titles.contains(where: \.isEmpty))
        XCTAssertFalse(subtitles.contains(where: \.isEmpty))
        XCTAssertEqual(Set(titles).count, titles.count, "two rows worded the same are one switch")
        XCTAssertEqual(Set(subtitles).count, subtitles.count)
    }

    /// The register's one presentational consequence. An irreversible action does not answer to
    /// the chord that dismisses a dialog; a grant deliberately still does, because the agent is
    /// blocked while the sheet is up and approving is the common answer.
    func testOnlyIrreversiblePromptsMoveTheReturnKeyOffTheAction() {
        for prompt in ConfirmationPrompt.allCases {
            switch prompt.policy {
            case .alwaysAsks(.irreversible):
                XCTAssertTrue(prompt.defaultsToCancel, "\(prompt.rawValue)")
            case .alwaysAsks(.securityGrant), .suppressible:
                XCTAssertFalse(prompt.defaultsToCancel, "\(prompt.rawValue)")
            }
        }
    }

    func testOnlySuppressiblePromptsOfferASwitch() {
        for prompt in ConfirmationPrompt.allCases {
            switch prompt.policy {
            case .suppressible: XCTAssertNotNil(prompt.suppression, "\(prompt.rawValue)")
            case .alwaysAsks: XCTAssertNil(prompt.suppression, "\(prompt.rawValue)")
            }
        }
    }

    // MARK: - Storage

    func testSuppressionRoundTripsPerPrompt() throws {
        let suite = "Confirmations.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(ConfirmationPrompt.allCases.allSatisfy(settings.asks(before:)))

        settings.setAsks(false, before: .archiveRunningSession)

        // Stored as the suppressed set, so switching one off leaves the rest — and a prompt
        // added later — asking, with no defaults migration.
        let reread = AppSettings(defaults: defaults)
        XCTAssertFalse(reread.asks(before: .archiveRunningSession))
        XCTAssertTrue(reread.asks(before: .closeRunningSession))
        XCTAssertTrue(reread.asks(before: .moveRunningSessionToAccount))
        XCTAssertTrue(reread.asks(before: .removeExtension))
    }

    /// The reclassification guard. The suppressed set is raw strings on disk, so a prompt that
    /// was suppressible in one release and became `.alwaysAsks` in the next would stay silent
    /// for exactly the users who had switched it off — the ones least able to notice that a
    /// destructive action stopped asking. `asks(before:)` consults the policy first, which is
    /// what this holds it to.
    func testAnAlwaysAsksPromptStaysAskingEvenWhenTheDefaultsSayOtherwise() {
        settings { settings, defaults, _ in
            defaults.set(
                [ConfirmationPrompt.removeProject.rawValue,
                 ConfirmationPrompt.approveToolPermission.rawValue],
                forKey: "suppressedConfirmations"
            )

            XCTAssertTrue(settings.asks(before: .removeProject))
            XCTAssertTrue(settings.asks(before: .approveToolPermission))
        }
    }

    // MARK: - Migration

    func testTheClosingSwitchCarriesOverToTheFourLifecyclePrompts() {
        settings { _, defaults, suite in
            defaults.set(false, forKey: "confirmsBeforeClosingRunningSession")
            defaults.removeObject(forKey: "didMigrateClosingConfirmation")

            let migrated = AppSettings(defaults: defaults)
            for prompt in ConfirmationPrompt.closingConfirmationSuccessors {
                XCTAssertFalse(migrated.asks(before: prompt), "\(prompt.rawValue)")
            }
            XCTAssertTrue(
                migrated.asks(before: .removeExtension),
                "the switch covered four prompts; it must not carry into a fifth"
            )
            // The persistent domain, not `object(forKey:)` — the seed the migration depends on
            // lives in the registration domain and answers there whatever the user wrote.
            XCTAssertNil(
                defaults.persistentDomain(forName: suite)?["confirmsBeforeClosingRunningSession"],
                "the old key is read once and retired"
            )
        }
    }

    /// The common case: the switch was left alone, so nothing is suppressed. Seeded `true`, so
    /// this is also what proves the seed has to stay — an unregistered key reads `false`, which
    /// would silence all four prompts for every user alive.
    func testAnUntouchedClosingSwitchSuppressesNothing() {
        settings { settings, _, _ in
            XCTAssertTrue(ConfirmationPrompt.allCases.allSatisfy(settings.asks(before:)))
        }
    }

    /// The marker is written last and never seeded, so an interrupted migration re-runs. That
    /// is only safe if a second run cannot undo a choice made after the first.
    func testMigrationDoesNotUndoAPromptSwitchedBackOnAfterwards() {
        settings { _, defaults, _ in
            defaults.set(false, forKey: "confirmsBeforeClosingRunningSession")
            defaults.removeObject(forKey: "didMigrateClosingConfirmation")

            let migrated = AppSettings(defaults: defaults)
            migrated.setAsks(true, before: .archiveRunningSession)

            let relaunched = AppSettings(defaults: defaults)
            XCTAssertTrue(relaunched.asks(before: .archiveRunningSession))
            XCTAssertFalse(relaunched.asks(before: .closeRunningSession))
        }
    }
}
