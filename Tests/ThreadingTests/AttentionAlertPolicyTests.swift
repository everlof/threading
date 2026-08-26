import UserNotifications
import XCTest
@testable import Threading

/// The judgement half of macOS attention notifications, kept apart from
/// `UNUserNotificationCenter` so the matrix is checkable without delivering anything.
///
/// The judgement is two questions, and both are here: whether the *edge* is worth an alert
/// (`AttentionAlertPolicy`), and whether the user still wants that kind of alert for that
/// session (`AppSettings` and `AttentionAlertScope`). Only delivery needs the center. The
/// icon attachment — the banner carrying the project's face — is pure for the same reason,
/// and checked here too.
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

    func testSnoozedSessionClearsInsteadOfPostingOrdinaryAttention() {
        XCTAssertEqual(
            AttentionAlertPolicy.action(
                from: .working,
                to: .awaitingUser,
                appIsActive: false,
                reportsOwnTurns: true,
                isSnoozed: true
            ),
            .clear
        )
    }

    // MARK: - Which Alerts Are Wanted

    /// The kinds are separately switchable, and the raw values are stored preferences —
    /// renaming one would silently re-enable a kind the user had switched off. The order is the
    /// settings page's own: loudest first, with the curfew's give-up last because it is the
    /// rarest and the only one that reports something Threading *tried*.
    func testEveryAlertKeepsItsStoredName() {
        XCTAssertEqual(
            AttentionAlert.allCases.map(\.rawValue),
            ["blocked", "unread", "finished", "curfew"]
        )
    }

    /// Only the alerts a session is *stuck* behind sound — but that is no longer a property of
    /// the alert. It is the bottom of the resolution chain, where the ones that stay silent can
    /// be given a sound by name and the loud ones can be quieted without costing the banner that
    /// carries them. A curfew that gave up shares `blocked`'s routing deliberately: it is the
    /// same kind of event, a session standing still until the user decides something.
    func testOnlyTheAlertsHoldingASessionUpSoundByDefault() {
        let sounding = AttentionAlert.allCases.filter {
            SoundResolution.resolve(SoundEvent($0), through: []) != .silent
        }

        XCTAssertEqual(sounding, [.blocked, .curfew])
        XCTAssertEqual(SoundEvent(.curfew), SoundEvent(.blocked))
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

    /// Alerts sound until someone says otherwise, and the answer for "not at all" is a value of
    /// the sound itself rather than a switch beside it — the checkbox that used to say so is
    /// retired, and `silent` is what it became.
    func testTheSoundDefaultsOnAndPersistsAnOptOut() throws {
        let suite = "AttentionAlertSound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.attentionAlertSound, .system)

        settings.attentionAlertSound = .silent
        XCTAssertEqual(AppSettings(defaults: defaults).attentionAlertSound, .silent)
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

    // MARK: - The Project Icon on the Banner

    /// The attachment must be a *copy* carrying the icon's own bytes: scheduling an
    /// attachment moves its file into the system's store, so handing over the original
    /// would drain `ProjectIconStore` one banner at a time.
    func testTheIconAttachmentIsACopyCarryingTheIconBytes() throws {
        let png = try samplePNG()

        let attachment = try XCTUnwrap(AttentionAlertIcon.attachment(iconPNGData: png))
        defer { try? FileManager.default.removeItem(at: attachment.url) }

        XCTAssertTrue(attachment.url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: attachment.url), png)
    }

    // MARK: - Once Per Episode, Not Once Per Edge

    /// The bug this rule exists for, replayed as the states it arrived as.
    ///
    /// A terminal session with no lifecycle hooks flip-flops `working` / `needsAttention` on
    /// every burst of output, because the quiet timer *is* its turn boundary. Recorded live on
    /// 25 August 2026: four `needsAttention` edges inside six seconds, each of which posted a
    /// full banner. Only the first is news.
    func testARepeatedAlertIsQuietAndOnlyTheFirstInterrupts() {
        var lastAnnounced: AttentionAlert?
        var presentations: [AttentionAlertPolicy.Presentation] = []

        for _ in 0..<4 {
            let presentation = AttentionAlertPolicy.presentation(
                of: .unread,
                lastAnnounced: lastAnnounced
            )
            presentations.append(presentation)
            lastAnnounced = .unread
        }

        XCTAssertEqual(presentations, [.interrupt, .quiet, .quiet, .quiet])
    }

    /// Looking at the session ends the episode, so the next one is news again. This is the
    /// half that keeps the rule from being a mute: the center clears its announcement on a
    /// `viewed` withdrawal and on that alone.
    func testViewingTheSessionMakesTheNextAlertInterruptAgain() {
        XCTAssertEqual(
            AttentionAlertPolicy.presentation(of: .unread, lastAnnounced: .unread),
            .quiet
        )
        // `viewed` is what clears the announcement, which arrives here as nil.
        XCTAssertEqual(
            AttentionAlertPolicy.presentation(of: .unread, lastAnnounced: nil),
            .interrupt
        )
    }

    /// An escalation is a different alert and interrupts. A session that was merely unread and
    /// is now holding a turn up on a question has said something new, and quieting that would
    /// be the failure this rule must not introduce.
    func testAnEscalationToADifferentAlertStillInterrupts() {
        XCTAssertEqual(
            AttentionAlertPolicy.presentation(of: .blocked, lastAnnounced: .unread),
            .interrupt
        )
        XCTAssertEqual(
            AttentionAlertPolicy.presentation(of: .unread, lastAnnounced: .blocked),
            .interrupt
        )
        XCTAssertEqual(
            AttentionAlertPolicy.presentation(of: .finished, lastAnnounced: .unread),
            .interrupt
        )
    }

    /// The curfew give-up is exempt. It is not derived from a state edge — a ladder that ran
    /// out posts it once per episode — and it is the only alert that reports Threading trying
    /// something and failing, so a second one is news however recently the first arrived.
    func testTheCurfewGiveUpIsNeverQuietedAsARepeat() {
        XCTAssertEqual(
            AttentionAlertPolicy.presentation(of: .curfew, lastAnnounced: .curfew),
            .interrupt
        )
    }

    /// Every alert kind is covered by the rule, so a case added later cannot quietly inherit
    /// whichever branch happens to be first.
    func testEveryAlertKindHasAnAnswerForBothFirstAndRepeat() {
        for alert in AttentionAlert.allCases {
            XCTAssertEqual(
                AttentionAlertPolicy.presentation(of: alert, lastAnnounced: nil),
                .interrupt,
                "\(alert.rawValue) should interrupt when it is the first of its episode"
            )
            let repeated = AttentionAlertPolicy.presentation(of: alert, lastAnnounced: alert)
            XCTAssertEqual(
                repeated,
                alert == .curfew ? .interrupt : .quiet,
                "\(alert.rawValue) repeated"
            )
        }
    }

    private func samplePNG() throws -> Data {
        let side = 8
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            NSColor.systemRed.setFill()
            bounds.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(
            NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        )
    }
}
