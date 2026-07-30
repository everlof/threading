import XCTest
@testable import Threading

/// The judgement half of macOS attention notifications, kept apart from
/// `UNUserNotificationCenter` so the matrix is checkable without delivering anything.
///
/// The judgement is two questions, and both are here: whether the *edge* is worth an alert
/// (`AttentionAlertPolicy`), and whether the user still wants that kind of alert for that
/// session (`AppSettings` and `AttentionAlertScope`). Only delivery needs the center.
@MainActor
final class AttentionAlertPolicyTests: XCTestCase {

    // MARK: - Posting

    func testBlockedAndUnreadPostRegardlessOfAppState() {
        // The banner is suppressed at presentation while the app is frontmost; the judgement
        // does not depend on it, so an app-switch right after the edge still finds the
        // notification waiting.
        for appIsActive in [true, false] {
            XCTAssertEqual(
                AttentionAlertPolicy.action(
                    from: .working, to: .awaitingUser,
                    appIsActive: appIsActive, reportsOwnTurns: true
                ),
                .post(.blocked)
            )
            XCTAssertEqual(
                AttentionAlertPolicy.action(
                    from: .working, to: .needsAttention,
                    appIsActive: appIsActive, reportsOwnTurns: false
                ),
                .post(.unread)
            )
        }
    }

    func testAWatchedTurnFinishingInTheBackgroundPosts() {
        // The visible session settles to idle rather than needsAttention — in-app it needs no
        // flag. With the app behind another, a notification is the only cue left.
        XCTAssertEqual(
            AttentionAlertPolicy.action(
                from: .working, to: .idle,
                appIsActive: false, reportsOwnTurns: true
            ),
            .post(.finished)
        )
    }

    func testAWatchedTurnFinishingInTheForegroundDoesNot() {
        // The user watched it happen.
        XCTAssertEqual(
            AttentionAlertPolicy.action(
                from: .working, to: .idle,
                appIsActive: true, reportsOwnTurns: true
            ),
            .none
        )
    }

    func testAShellGoingQuietNeverPostsFinished() {
        // A shell's working→idle is a quiet timer expiring after every burst of output.
        // Notifying on each `ls` would bury the alerts that matter.
        XCTAssertEqual(
            AttentionAlertPolicy.action(
                from: .working, to: .idle,
                appIsActive: false, reportsOwnTurns: false
            ),
            .none
        )
    }

    // MARK: - Withdrawing

    func testLeavingAnAttentionStateWithdraws() {
        // A notification for an answered question is litter in Notification Center.
        for old in [SessionActivity.awaitingUser, .needsAttention] {
            for new in [SessionActivity.working, .dormant] {
                XCTAssertEqual(
                    AttentionAlertPolicy.action(
                        from: old, to: new,
                        appIsActive: true, reportsOwnTurns: true
                    ),
                    .clear,
                    "\(old) → \(new) left its notification behind"
                )
            }
        }
    }

    func testAFinishedAlertIsWithdrawnWhenTheSessionWorksAgain() {
        // The `.finished` alert leaves the session idle, so idle→working is its stale edge.
        XCTAssertEqual(
            AttentionAlertPolicy.action(
                from: .idle, to: .working,
                appIsActive: false, reportsOwnTurns: true
            ),
            .clear
        )
    }

    func testNoEdgeMeansNoAction() {
        XCTAssertEqual(
            AttentionAlertPolicy.action(
                from: .needsAttention, to: .needsAttention,
                appIsActive: false, reportsOwnTurns: true
            ),
            .none
        )
    }

    // MARK: - Which Alerts Are Wanted

    /// The three kinds are separately switchable, and the raw values are stored preferences —
    /// renaming one would silently re-enable a kind the user had switched off.
    func testEveryAlertKeepsItsStoredName() {
        XCTAssertEqual(
            AttentionAlert.allCases.map(\.rawValue),
            ["blocked", "unread", "finished"]
        )
    }

    /// Only the alert that is holding a turn up sounds. The settings row that switches the
    /// sound off exists because the *banner* is still wanted; the two are separate questions.
    func testOnlyTheBlockedAlertSounds() {
        XCTAssertEqual(AttentionAlert.allCases.filter(\.sounds), [.blocked])
    }

    /// Every kind reads differently in both places it is named, so a settings row can be
    /// matched to the banner it silences.
    func testEachAlertNamesItselfDistinctly() {
        XCTAssertEqual(Set(AttentionAlert.allCases.map(\.body)).count, AttentionAlert.allCases.count)
        XCTAssertEqual(
            Set(AttentionAlert.allCases.map(\.settingsTitle)).count,
            AttentionAlert.allCases.count
        )
    }

    func testKindsStartOnAndPersistAnOptOut() throws {
        let suite = "AttentionAlertKinds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(AttentionAlert.allCases.allSatisfy(settings.notifies(on:)))

        settings.setNotifies(false, on: .finished)

        // Stored as the disabled set, so switching one off leaves the rest — and a kind added
        // later — on, with no defaults migration.
        let reread = AppSettings(defaults: defaults)
        XCTAssertFalse(reread.notifies(on: .finished))
        XCTAssertTrue(reread.notifies(on: .blocked))
        XCTAssertTrue(reread.notifies(on: .unread))
    }

    func testTheSoundDefaultsOnAndPersistsAnOptOut() throws {
        let suite = "AttentionAlertSound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.playsAttentionAlertSound)

        settings.playsAttentionAlertSound = false
        XCTAssertFalse(AppSettings(defaults: defaults).playsAttentionAlertSound)
    }

    // MARK: - Muting Scopes

    /// Nothing is muted until something says so.
    func testNothingIsMutedByDefault() {
        XCTAssertFalse(AttentionAlertScope.resolve(session: nil, project: nil))
    }

    func testAMutedProjectSilencesItsSessions() {
        XCTAssertTrue(AttentionAlertScope.resolve(session: nil, project: true))
    }

    /// The reason both fields are optional: a session inside a muted project can still say no,
    /// which a plain flag on each level could not express — the row's Unmute would do nothing.
    func testASessionOverridesItsProjectInBothDirections() {
        XCTAssertFalse(AttentionAlertScope.resolve(session: false, project: true))
        XCTAssertTrue(AttentionAlertScope.resolve(session: true, project: false))
    }
}
