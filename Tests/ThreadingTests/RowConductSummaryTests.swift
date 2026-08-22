import XCTest
@testable import Threading

/// What a sidebar row says about itself when it behaves differently from the rows around it.
///
/// The rule is asserted on values, not through the store, for `LimitRecoveryResolution`'s reason:
/// this decides whether a mark appears, and a mark that appears on every row is worse than no
/// mark at all.
final class RowConductSummaryTests: XCTestCase {

    // MARK: - Absence

    /// The common case, and the one that has to stay free: a chat that answered nothing carries
    /// no mark, so the row materializes no image view, no constraints and no stack slot.
    func testAChatThatChoseNothingSummarisesToNothing() {
        XCTAssertNil(
            RowConductSummary.session(
                muted: nil,
                inheritedMuted: false,
                limitRecovery: nil,
                inheritedLimitRecovery: .flagOnly
            )
        )
    }

    /// **A stored value that matches what would have been inherited is not a difference.** This
    /// is why the rule compares rather than testing for non-nil: a record can hold the inherited
    /// answer — an older writer, or a setting toggled twice — and a mark for it would be a row
    /// claiming to be different while behaving identically to its neighbours.
    func testAStoredAnswerMatchingTheInheritedOneIsNotADifference() {
        XCTAssertNil(
            RowConductSummary.session(
                muted: false,
                inheritedMuted: false,
                limitRecovery: .flagOnly,
                inheritedLimitRecovery: .flagOnly
            )
        )
    }

    /// The inverse, and the reason a chat inside an armed checkout is worth marking: it is the
    /// one that will *not* continue, which is the surprising half.
    func testAChatDecliningWhatItsCheckoutArmedIsADifference() throws {
        let summary = try XCTUnwrap(
            RowConductSummary.session(
                muted: nil,
                inheritedMuted: false,
                limitRecovery: .flagOnly,
                inheritedLimitRecovery: .waitForReset
            )
        )

        XCTAssertEqual(summary.statements, [RowConductStrings.limitRecovery(.flagOnly)])
    }

    // MARK: - What It Says

    func testAnArmedChatSaysSo() throws {
        let summary = try XCTUnwrap(
            RowConductSummary.session(
                muted: nil,
                inheritedMuted: false,
                limitRecovery: .waitForReset,
                inheritedLimitRecovery: .flagOnly
            )
        )

        XCTAssertEqual(summary.statements.count, 1)
        XCTAssertEqual(summary.sentence, RowConductStrings.limitRecovery(.waitForReset))
    }

    func testAMutedChatSaysSo() throws {
        let summary = try XCTUnwrap(
            RowConductSummary.session(
                muted: true,
                inheritedMuted: false,
                limitRecovery: nil,
                inheritedLimitRecovery: .flagOnly
            )
        )

        XCTAssertEqual(summary.sentence, RowConductStrings.mute(true))
    }

    /// A chat speaking inside a muted checkout is as much a difference as the reverse, and reads
    /// as one — "Notifications on" is only worth saying where silence was expected.
    func testAChatSpeakingInsideAMutedCheckoutIsADifference() throws {
        let summary = try XCTUnwrap(
            RowConductSummary.session(
                muted: false,
                inheritedMuted: true,
                limitRecovery: nil,
                inheritedLimitRecovery: .flagOnly
            )
        )

        XCTAssertEqual(summary.sentence, RowConductStrings.mute(false))
    }

    /// The louder consequence leads: what the chat *does* on its own before what it does not say.
    func testBothDifferencesReadWithTheRecoveryFirst() throws {
        let summary = try XCTUnwrap(
            RowConductSummary.session(
                muted: true,
                inheritedMuted: false,
                limitRecovery: .waitForReset,
                inheritedLimitRecovery: .flagOnly
            )
        )

        XCTAssertEqual(summary.statements, [
            RowConductStrings.limitRecovery(.waitForReset),
            RowConductStrings.mute(true)
        ])
        XCTAssertTrue(summary.sentence.contains(RowConductDefaults.separator))
    }

    // MARK: - A Checkout

    /// A project's inherited mute is "not muted" — the base every checkout starts from — so a
    /// stored `false` there says nothing and must not draw a mark.
    func testACheckoutStoringNotMutedSaysNothing() {
        XCTAssertNil(
            RowConductSummary.project(
                muted: false,
                limitRecovery: nil,
                inheritedLimitRecovery: .flagOnly
            )
        )
    }

    func testAnArmedCheckoutSaysSo() throws {
        let summary = try XCTUnwrap(
            RowConductSummary.project(
                muted: nil,
                limitRecovery: .waitForReset,
                inheritedLimitRecovery: .flagOnly
            )
        )

        XCTAssertEqual(summary.sentence, RowConductStrings.limitRecovery(.waitForReset))
    }

    /// A checkout that armed nothing while Settings already did carries no mark: it is doing
    /// exactly what every other checkout does.
    func testACheckoutFollowingAnArmedSettingSaysNothing() {
        XCTAssertNil(
            RowConductSummary.project(
                muted: nil,
                limitRecovery: nil,
                inheritedLimitRecovery: .waitForReset
            )
        )
    }

    // MARK: - The Words

    /// Each statement names the behaviour rather than the setting, because a hover card is read
    /// by somebody asking what will happen, not by somebody looking for a preference.
    func testTheStatementsNameBehaviourRatherThanSettings() {
        XCTAssertEqual(RowConductStrings.limitRecovery(.waitForReset), "Continues at reset")
        XCTAssertEqual(RowConductStrings.limitRecovery(.flagOnly), "Stops at its limit")
        XCTAssertEqual(
            RowConductStrings.limitRecovery(.resumeOnBestAccount),
            "Moves to a login with room"
        )
        XCTAssertEqual(RowConductStrings.mute(true), "Notifications muted")
    }

    /// A pinned login is named by its handle, and that is a scaling decision: the person's name
    /// needs `AgentAccountDiscovery`, which is a cache in front of a home-directory scan, and this
    /// string is built once per visible row on the configure path.
    func testAPinnedLoginIsNamedFromTheStoredIdentifierAlone() {
        XCTAssertEqual(
            RowConductStrings.limitRecovery(.resumeVia(
                AccountID(provider: .claude, handle: AccountHandle(storedName: "work"))
            )),
            "Moves to work"
        )
    }

    /// The mark exists for a row that will behave differently, and a chat that moves logins by
    /// itself is the loudest example there is — it acts precisely when nobody is watching.
    func testAChatThatMovesLoginsByItselfIsMarked() throws {
        let summary = try XCTUnwrap(
            RowConductSummary.session(
                muted: nil,
                inheritedMuted: false,
                limitRecovery: .resumeOnBestAccount,
                inheritedLimitRecovery: .flagOnly
            )
        )

        XCTAssertEqual(
            summary.statements,
            [RowConductStrings.limitRecovery(.resumeOnBestAccount)]
        )
    }

    // MARK: - Curfew Fixture

    /// 04:00 UTC, the moment the feature was written for. Never asserted against a literal clock
    /// reading: `QuietHours` is defined in local minutes, so a test that spelled "04:00" would
    /// pass in one timezone and fail in the next.
    private let deadline = Date(timeIntervalSince1970: 1_775_016_000)

    private func curfew(
        at deadline: Date? = nil,
        origin: CurfewOrigin = .session
    ) -> ResolvedCurfew {
        ResolvedCurfew(
            deadline: deadline ?? self.deadline,
            origin: origin,
            windDownMargin: CurfewDefaults.windDownMargin,
            grace: CurfewDefaults.grace,
            windDownText: CurfewDefaults.windDownText
        )
    }

    private func answer(
        _ curfew: ResolvedCurfew?,
        scope: CurfewScope = .session
    ) -> CurfewResolution.Answer {
        CurfewResolution.Answer(scope: scope, curfew: curfew)
    }

    /// A standing window every night from 04:00 to 08:00 **local**, which is what the setting
    /// actually stores. The window instances are then read back out of `QuietHours` itself rather
    /// than constructed here, so the test asks the same question the app does.
    private let quietHours = QuietHours(isEnabled: true, startMinute: 4 * 60, endMinute: 8 * 60)

    private func curfewPreferences(quietHours: QuietHours = .default) -> CurfewPreferences {
        CurfewPreferences(quietHours: quietHours)
    }

    /// Local noon on the fixture's day: outside a 04:00–08:00 window in every timezone, and far
    /// from any transition that would move it.
    private func noon(calendar: Calendar = .current) throws -> Date {
        try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: deadline))
    }

    // MARK: - A Curfew, Held

    /// The louder half, and the reason it leads: a held session looks exactly like an idle one.
    /// Nothing is being sent to it, and a reader glancing at the row is owed that before they go
    /// looking for a reason it stopped.
    func testAHeldChatSaysSoAndLeads() throws {
        let statement = try XCTUnwrap(
            RowConductSummary.curfewStatement(
                hold: .held(since: deadline, curfew: curfew(), state: nil),
                answer: answer(curfew()),
                inherited: nil,
                ownScope: .session,
                now: deadline.addingTimeInterval(1_800)
            )
        )

        XCTAssertTrue(statement.leads)
        XCTAssertTrue(
            statement.text.hasPrefix("Held by curfew since "),
            "the row led with \(statement.text)"
        )
        XCTAssertTrue(statement.text.contains(ScheduledTimePresets.time(deadline)))
    }

    /// **A hold speaks whichever scope set it**, unlike everything else here. The standing window
    /// is inherited, so marking every row for being *armed* by it would say nothing — but a row it
    /// is actually holding is a row that stopped, and that is news about this conversation rather
    /// than about the setting.
    func testAQuietHoursHoldStillSpeaksEvenThoughTheWindowIsInherited() throws {
        let window = curfew(origin: .quietHours(endsAt: deadline.addingTimeInterval(4 * 3_600)))
        let statement = try XCTUnwrap(
            RowConductSummary.curfewStatement(
                hold: .held(since: deadline, curfew: window, state: nil),
                answer: answer(window, scope: .app),
                inherited: window,
                ownScope: .session,
                now: deadline.addingTimeInterval(60)
            )
        )

        XCTAssertTrue(statement.leads)
        XCTAssertTrue(statement.text.hasPrefix("Held by curfew since "))
    }

    /// The order the row reads in, and the one part of it that is a judgement: the curfew names
    /// **this conversation's** clock while a park names the account behind it, so the fence that
    /// belongs to the row the reader is looking at comes first.
    func testAHeldChatReadsAheadOfAParkAndOfItsOwnSettings() throws {
        let held = RowCurfewStatement(text: "Held by curfew since 04:00", leads: true)
        let park = RowConductStrings.parkedByOwnLimit("Weekly · resets Monday")

        let summary = try XCTUnwrap(
            RowConductSummary.session(
                muted: true,
                inheritedMuted: false,
                limitRecovery: .waitForReset,
                inheritedLimitRecovery: .flagOnly,
                curfew: held,
                parkedByOwnLimit: park
            )
        )

        XCTAssertEqual(summary.statements, [
            held.text,
            park,
            RowConductStrings.limitRecovery(.waitForReset),
            RowConductStrings.mute(true)
        ])
    }

    // MARK: - A Curfew, Armed

    /// A chat that ends itself tonight is a chat that will behave differently from its
    /// neighbours, which is the whole test for a mark.
    func testAnArmedOneShotSaysWhenItEnds() throws {
        let statement = try XCTUnwrap(
            RowConductSummary.curfewStatement(
                hold: .clear,
                answer: answer(curfew()),
                inherited: nil,
                ownScope: .session,
                now: deadline.addingTimeInterval(-2 * 3_600)
            )
        )

        XCTAssertFalse(statement.leads)
        XCTAssertTrue(statement.text.hasPrefix("Curfew at "), "the row said \(statement.text)")
    }

    /// Appended rather than prepended: nothing has happened to this session yet, so it reads
    /// after the facts that describe what it is doing now.
    func testAnArmedChatSpeaksLast() throws {
        let armed = RowCurfewStatement(text: "Curfew at 04:00", leads: false)

        let summary = try XCTUnwrap(
            RowConductSummary.session(
                muted: true,
                inheritedMuted: false,
                limitRecovery: nil,
                inheritedLimitRecovery: .flagOnly,
                curfew: armed
            )
        )

        XCTAssertEqual(summary.statements, [RowConductStrings.mute(true), armed.text])
    }

    /// **The standing window marks nothing.** Every conversation on the machine inherits it, so
    /// a mark for it would appear on every row in the sidebar and distinguish none of them — the
    /// failure mode this whole rule exists to avoid.
    func testAnInheritedQuietHoursWindowMarksNoRow() throws {
        let now = try noon()
        let preferences = curfewPreferences(quietHours: quietHours)
        let answer = CurfewResolution.resolve(
            session: nil,
            project: nil,
            preferences: preferences,
            state: nil,
            now: now
        )

        XCTAssertEqual(answer.scope, .app)
        XCTAssertNotNil(answer.curfew, "the fixture stopped resolving a standing window")
        XCTAssertNil(
            RowConductSummary.curfewStatement(
                hold: .clear,
                answer: answer,
                inherited: CurfewResolution.inherited(
                    beyond: .session,
                    project: nil,
                    preferences: preferences,
                    now: now
                ),
                ownScope: .session,
                now: now
            )
        )
    }

    /// A chat that named the moment it would have inherited anyway behaves identically to the
    /// rows around it, and a mark would be it claiming otherwise — the rule the mute and recovery
    /// statements already follow, asked of a deadline.
    func testAStoredCurfewMatchingTheInheritedOneIsNotADifference() throws {
        let now = try noon()
        let preferences = curfewPreferences(quietHours: quietHours)
        let window = try XCTUnwrap(quietHours.nextWindow(after: now))

        XCTAssertNil(
            RowConductSummary.curfewStatement(
                hold: .clear,
                answer: CurfewResolution.resolve(
                    session: .until(window.start),
                    project: nil,
                    preferences: preferences,
                    state: nil,
                    now: now
                ),
                inherited: CurfewResolution.inherited(
                    beyond: .session,
                    project: nil,
                    preferences: preferences,
                    now: now
                ),
                ownScope: .session,
                now: now
            )
        )
    }

    /// The inverse, so the comparison above is not passing by refusing everything: an hour
    /// earlier than the standing window is a real difference and says so.
    func testAStoredCurfewAheadOfTheInheritedOneIsADifference() throws {
        let now = try noon()
        let preferences = curfewPreferences(quietHours: quietHours)
        let window = try XCTUnwrap(quietHours.nextWindow(after: now))
        let earlier = window.start.addingTimeInterval(-3_600)

        let statement = try XCTUnwrap(
            RowConductSummary.curfewStatement(
                hold: .clear,
                answer: CurfewResolution.resolve(
                    session: .until(earlier),
                    project: nil,
                    preferences: preferences,
                    state: nil,
                    now: now
                ),
                inherited: CurfewResolution.inherited(
                    beyond: .session,
                    project: nil,
                    preferences: preferences,
                    now: now
                ),
                ownScope: .session,
                now: now
            )
        )

        XCTAssertFalse(statement.leads)
        XCTAssertTrue(statement.text.hasPrefix("Curfew at "), "the row said \(statement.text)")
        XCTAssertTrue(statement.text.contains(ScheduledTimePresets.time(earlier)))
    }

    // MARK: - An Exemption

    /// An exemption is only worth a line where a window would otherwise have held this chat.
    /// "Exempt from quiet hours" on a machine with no quiet hours names a rule nobody set.
    func testAnExemptionSpeaksOnlyWhereAWindowWouldHaveApplied() throws {
        let now = try noon()
        let exempt = CurfewResolution.resolve(
            session: .exempt,
            project: nil,
            preferences: curfewPreferences(quietHours: quietHours),
            state: nil,
            now: now
        )

        XCTAssertEqual(exempt.scope, .session)
        XCTAssertNil(exempt.curfew)

        XCTAssertNil(
            RowConductSummary.curfewStatement(
                hold: .clear,
                answer: exempt,
                inherited: nil,
                ownScope: .session,
                now: now
            ),
            "a machine with no quiet hours marked a row for being exempt from them"
        )

        let statement = try XCTUnwrap(
            RowConductSummary.curfewStatement(
                hold: .clear,
                answer: exempt,
                inherited: CurfewResolution.inherited(
                    beyond: .session,
                    project: nil,
                    preferences: curfewPreferences(quietHours: quietHours),
                    now: now
                ),
                ownScope: .session,
                now: now
            )
        )

        XCTAssertFalse(statement.leads)
        XCTAssertEqual(statement.text, "Exempt from quiet hours")
    }

    /// A chat inheriting its checkout's exemption is doing exactly what every other chat in that
    /// checkout does, so the checkout's row carries the sentence and the chats stay quiet.
    func testAChatInheritingItsCheckoutsExemptionStaysQuiet() throws {
        let now = try noon()

        XCTAssertNil(
            RowConductSummary.curfewStatement(
                hold: .clear,
                answer: CurfewResolution.resolve(
                    session: nil,
                    project: .exempt,
                    preferences: curfewPreferences(quietHours: quietHours),
                    state: nil,
                    now: now
                ),
                inherited: nil,
                ownScope: .session,
                now: now
            )
        )
    }

    // MARK: - A Checkout's Curfew

    /// The one curfew answer `ProjectStore` lets a checkout store, and the same condition on it:
    /// it says something only where the standing window would otherwise have reached its chats.
    func testACheckoutExemptingItsChatsSaysSoUnderQuietHours() throws {
        let now = try noon()
        let preferences = curfewPreferences(quietHours: quietHours)
        let exempt = CurfewResolution.resolve(
            session: nil,
            project: .exempt,
            preferences: preferences,
            state: nil,
            now: now
        )

        XCTAssertEqual(exempt.scope, .project)

        let statement = try XCTUnwrap(
            RowConductSummary.curfewStatement(
                hold: .clear,
                answer: exempt,
                inherited: CurfewResolution.inherited(
                    beyond: .project,
                    project: nil,
                    preferences: preferences,
                    now: now
                ),
                ownScope: .project,
                now: now
            )
        )

        let summary = try XCTUnwrap(
            RowConductSummary.project(
                muted: nil,
                limitRecovery: nil,
                inheritedLimitRecovery: .flagOnly,
                curfew: statement
            )
        )

        XCTAssertEqual(summary.statements, ["Exempt from quiet hours"])
    }

    func testACheckoutExemptingItsChatsWithNoQuietHoursSaysNothing() throws {
        let now = try noon()

        XCTAssertNil(
            RowConductSummary.curfewStatement(
                hold: .clear,
                answer: CurfewResolution.resolve(
                    session: nil,
                    project: .exempt,
                    preferences: curfewPreferences(),
                    state: nil,
                    now: now
                ),
                inherited: CurfewResolution.inherited(
                    beyond: .project,
                    project: nil,
                    preferences: curfewPreferences(),
                    now: now
                ),
                ownScope: .project,
                now: now
            )
        )
    }
}
