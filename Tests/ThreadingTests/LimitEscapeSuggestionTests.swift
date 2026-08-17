import XCTest
@testable import Threading

/// Which login a refused conversation is offered, and what happens to the offer afterwards.
///
/// The ranking half is pure and is asserted as such — no home directory to scan, no network to
/// answer, `preferred(among:)`'s reason. The store half is asserted against an instance of its
/// own rather than the singleton, so the dismissal and clearing rules are pinned without a
/// coordinator, a poll timer or a live agent anywhere in the fixture.
@MainActor
final class LimitEscapeSuggestionTests: XCTestCase {

    // MARK: - Fixture

    private enum Fixture {
        static let now = Date(timeIntervalSince1970: 1_770_000_000)

        static func account(_ name: String) -> AccountID {
            AccountID(provider: .claude, handle: AccountHandle(storedName: name))
        }

        /// A window stated the way a provider states one: how full it is, when it turns over,
        /// and how long it runs — which together are what a pace deficit is computed from.
        static func window(
            id: String,
            fraction: Double?,
            resetsIn: TimeInterval,
            length: TimeInterval = UsageDefaults.fiveHourSeconds,
            scopeName: String? = nil
        ) -> AccountUsage.Window {
            AccountUsage.Window(
                id: id,
                label: id,
                fraction: fraction,
                resetsAt: now.addingTimeInterval(resetsIn),
                windowDuration: length,
                scopeName: scopeName
            )
        }

        static func usage(
            _ windows: [AccountUsage.Window],
            modelWindows: [AccountUsage.Window] = []
        ) -> AccountUsage {
            var usage = AccountUsage(
                windows: windows,
                planLabel: "Max",
                observedAt: now,
                source: .api
            )
            usage.modelWindows = modelWindows
            return usage
        }

        static func candidate(
            _ name: String,
            _ usage: AccountUsage?
        ) -> LimitEscapeRanking.Candidate {
            LimitEscapeRanking.Candidate(accountID: account(name), usage: usage)
        }

        static func suggestion(
            for sessionID: SessionID,
            account name: String = "block",
            reading: String? = "5h 12% · 7d 40%"
        ) -> LimitEscapeSuggestion {
            LimitEscapeSuggestion(
                sessionID: sessionID,
                accountID: account(name),
                accountName: "Daniel Block",
                reading: reading,
                resetHint: "9:40pm (Europe/Rome)",
                model: "claude-opus-5",
                decidingWindowName: "7d"
            )
        }
    }

    // MARK: - The Ranking

    /// The whole ordering rule in one case: the emptier account is *not* the answer when it is
    /// further ahead of its own burn. `two` is 40% spent four hours into a five-hour window
    /// (deficit +0.4); `one` is 30% spent one hour in (deficit −0.1) and is running hot.
    func testTheAccountFurthestBehindItsBurnWinsRatherThanTheEmptiestOne() {
        let ranked = LimitEscapeRanking.rank(
            [
                Fixture.candidate("one", Fixture.usage([
                    Fixture.window(id: "5h", fraction: 0.3, resetsIn: 4 * 3600)
                ])),
                Fixture.candidate("two", Fixture.usage([
                    Fixture.window(id: "5h", fraction: 0.4, resetsIn: 3600)
                ]))
            ],
            metering: nil,
            at: Fixture.now
        )

        XCTAssertEqual(ranked.map(\.accountID), [Fixture.account("two"), Fixture.account("one")])
        XCTAssertEqual(ranked[0].paceDeficit, 0.4, accuracy: 0.0001)
        XCTAssertEqual(ranked[1].paceDeficit, -0.1, accuracy: 0.0001)
    }

    /// An account is judged on the window that would stop it *first*, not on its best one.
    func testAnAccountIsRankedOnItsWorstMeteringWindow() throws {
        let ranked = try XCTUnwrap(LimitEscapeRanking.best(
            among: [
                Fixture.candidate("one", Fixture.usage([
                    // Comfortable weekly, and a five-hour window already ahead of the clock.
                    Fixture.window(id: "5h", fraction: 0.5, resetsIn: 4 * 3600),
                    Fixture.window(
                        id: "7d",
                        fraction: 0.1,
                        resetsIn: 6 * 86_400,
                        length: UsageDefaults.sevenDaySeconds
                    )
                ]))
            ],
            metering: nil,
            at: Fixture.now
        ))

        XCTAssertEqual(ranked.decidingWindowName, "5h")
        XCTAssertEqual(ranked.paceDeficit, -0.3, accuracy: 0.0001)
    }

    /// The scoped window is the whole reason `bindingWindow` exists: an account comfortable in
    /// its own windows is useless to a session running the model whose window is spent.
    func testAModelScopedWindowMakesAnOtherwiseComfortableAccountIneligible() {
        let usage = Fixture.usage(
            [Fixture.window(id: "5h", fraction: 0.1, resetsIn: 4 * 3600)],
            modelWindows: [
                Fixture.window(
                    id: "Fable",
                    fraction: 0.95,
                    resetsIn: 6 * 86_400,
                    length: UsageDefaults.sevenDaySeconds,
                    scopeName: "Fable"
                )
            ]
        )

        XCTAssertNil(LimitEscapeRanking.best(
            among: [Fixture.candidate("one", usage)],
            metering: "claude-fable-5[1m]",
            at: Fixture.now
        ))

        // The same login is fine for a session that is not running that model, which is the
        // half that proves the exclusion is the scope's doing rather than the fraction's.
        XCTAssertNotNil(LimitEscapeRanking.best(
            among: [Fixture.candidate("one", usage)],
            metering: "claude-opus-5",
            at: Fixture.now
        ))
    }

    /// A reset that has passed makes the percentage a leftover from the *previous* window. It is
    /// very likely generous, which is exactly why it must not be believed.
    func testAWindowWhoseResetHasPassedIsNotBelieved() {
        XCTAssertNil(LimitEscapeRanking.best(
            among: [
                Fixture.candidate("one", Fixture.usage([
                    Fixture.window(id: "5h", fraction: 0.05, resetsIn: -60)
                ]))
            ],
            metering: nil,
            at: Fixture.now
        ))
    }

    func testALoginWithNoReadingIsNotOffered() {
        XCTAssertNil(LimitEscapeRanking.best(
            among: [Fixture.candidate("one", nil)],
            metering: nil,
            at: Fixture.now
        ))
    }

    /// A reading with no windows at all is indistinguishable here from one that failed to parse.
    func testALoginReportingNoWindowsIsNotOffered() {
        XCTAssertNil(LimitEscapeRanking.best(
            among: [Fixture.candidate("one", Fixture.usage([]))],
            metering: nil,
            at: Fixture.now
        ))
    }

    func testALoginAlreadyUnderPressureIsNotSomewhereToEscapeTo() {
        XCTAssertNil(LimitEscapeRanking.best(
            among: [
                Fixture.candidate("one", Fixture.usage([
                    Fixture.window(
                        id: "5h",
                        fraction: LimitEscapeDefaults.headroomFraction,
                        resetsIn: 4 * 3600
                    )
                ]))
            ],
            metering: nil,
            at: Fixture.now
        ))
    }

    func testNoCandidatesRanksToNothingRatherThanFailing() {
        XCTAssertEqual(LimitEscapeRanking.rank([], metering: nil, at: Fixture.now).count, 0)
    }

    /// Two readings that say exactly the same thing keep the order they arrived in, so a
    /// discovery order that has not changed cannot make the offer flicker between two logins.
    func testIdenticalReadingsKeepTheOrderTheyWereOfferedIn() {
        let usage = Fixture.usage([Fixture.window(id: "5h", fraction: 0.2, resetsIn: 4 * 3600)])
        let ranked = LimitEscapeRanking.rank(
            [Fixture.candidate("one", usage), Fixture.candidate("two", usage)],
            metering: nil,
            at: Fixture.now
        )

        XCTAssertEqual(ranked.map(\.accountID), [Fixture.account("one"), Fixture.account("two")])
    }

    /// The guard a press runs again against a forced reading: the same eligibility, asked about
    /// one login rather than a list.
    func testHeadroomIsTheSameQuestionAskedAboutOneLogin() {
        let roomy = Fixture.candidate("one", Fixture.usage([
            Fixture.window(id: "5h", fraction: 0.2, resetsIn: 4 * 3600)
        ]))
        let spent = Fixture.candidate("one", Fixture.usage([
            Fixture.window(id: "5h", fraction: 0.99, resetsIn: 4 * 3600)
        ]))

        XCTAssertTrue(LimitEscapeRanking.hasHeadroom(roomy, metering: nil, at: Fixture.now))
        XCTAssertFalse(LimitEscapeRanking.hasHeadroom(spent, metering: nil, at: Fixture.now))
    }

    // MARK: - The Store

    /// A policy that pins a login moves the conversation there, not to the one the ranking put on
    /// the strip — so the record is pointed at the login being moved to before the busy line is
    /// drawn from it. Otherwise the strip reports a login change that is not happening, which is
    /// the whole reason `busy` names its action instead of counting a Boolean.
    func testAPolicysOwnLoginBecomesTheOneTheStripNames() throws {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()
        store.record(Fixture.suggestion(for: sessionID))

        let pinned = Fixture.account("pinned")
        store.retarget(to: pinned, name: "Vera Lund", reading: "5h 3%", for: sessionID)

        let offer = try XCTUnwrap(store.offer(for: sessionID))
        XCTAssertEqual(offer.accountID, pinned)
        XCTAssertEqual(offer.accountName, "Vera Lund")
        XCTAssertEqual(offer.reading, "5h 3%")
        XCTAssertEqual(
            offer.resetHint,
            "9:40pm (Europe/Rome)",
            "the refusal itself is unchanged — only the login being moved to is"
        )
        XCTAssertNil(
            offer.decidingWindowName,
            "the window that placed the *other* login was carried over"
        )
    }

    /// A dismissal survives it: this is still the same refusal, and pointing it at another login
    /// is not the user being asked again.
    func testRetargetingKeepsADismissalAndIgnoresTheLoginItAlreadyNames() {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()
        store.record(Fixture.suggestion(for: sessionID))
        store.dismiss(sessionID)

        store.retarget(to: Fixture.account("pinned"), name: "Vera Lund", reading: nil, for: sessionID)
        XCTAssertNil(store.offer(for: sessionID))

        // Naming the login already on the record changes nothing, so an escape that agrees with
        // the standing offer does not file a fresh one over it.
        store.retarget(to: Fixture.account("pinned"), name: "Someone Else", reading: nil, for: sessionID)
        XCTAssertEqual(store.suggestion(for: sessionID)?.accountName, "Vera Lund")
    }

    func testAnOfferIsDrawnUntilItIsDismissed() {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()

        store.record(Fixture.suggestion(for: sessionID))
        XCTAssertNotNil(store.offer(for: sessionID))

        store.dismiss(sessionID)
        XCTAssertNil(store.offer(for: sessionID), "a dismissed offer is still drawn")
        XCTAssertNotNil(
            store.suggestion(for: sessionID),
            "the record itself is kept, or a new reading could not re-rank it"
        )
    }

    /// The dismissal is per refusal, not per session: waving one away must not silence the next.
    func testANewRefusalOffersItselfAgainAfterADismissal() {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()

        store.record(Fixture.suggestion(for: sessionID))
        store.dismiss(sessionID)
        store.record(Fixture.suggestion(for: sessionID))

        XCTAssertNotNil(store.offer(for: sessionID))
    }

    /// The same refusal re-ranked against a reading that has since landed keeps the dismissal.
    func testANewReadingForTheSameRefusalDoesNotUndoTheDismissal() throws {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()

        store.record(Fixture.suggestion(for: sessionID, reading: "5h 12% · 7d 40%"))
        store.dismiss(sessionID)
        store.update(Fixture.suggestion(for: sessionID, reading: "5h 18% · 7d 41%"))

        XCTAssertNil(store.offer(for: sessionID))
        XCTAssertEqual(try XCTUnwrap(store.suggestion(for: sessionID)).reading, "5h 18% · 7d 41%")
    }

    /// Nothing is filed for a session that was never refused, so a reading arriving for an
    /// ordinary account cannot conjure a strip over an ordinary conversation.
    func testAReadingForASessionThatWasNeverRefusedFilesNothing() {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()

        store.update(Fixture.suggestion(for: sessionID))

        XCTAssertNil(store.suggestion(for: sessionID))
    }

    func testTheRefusalClearingTakesTheOfferWithIt() {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()

        store.record(Fixture.suggestion(for: sessionID))
        store.refusalCleared(for: sessionID)

        XCTAssertNil(store.suggestion(for: sessionID))
        XCTAssertFalse(store.hasStandingRefusal(for: sessionID))
    }

    /// A session whose agent exited has nothing left to migrate into.
    func testAnAgentExitingTakesTheOfferWithIt() {
        let center = NotificationCenter()
        let store = LimitEscapeSuggestionStore(center: center)
        let sessionID = SessionID()

        store.record(Fixture.suggestion(for: sessionID))
        center.post(TerminalSessionDidEnd(sessionID: sessionID))

        XCTAssertNil(store.suggestion(for: sessionID))
    }

    func testTheBusyFlagClearsAStandingProblemAndTheProblemClearsTheBusyFlag() throws {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()

        store.record(Fixture.suggestion(for: sessionID))
        store.note(problem: "Nope.", reading: "5h 96% · 7d 40%", for: sessionID)

        var offer = try XCTUnwrap(store.offer(for: sessionID))
        XCTAssertEqual(offer.problem, "Nope.")
        XCTAssertEqual(offer.reading, "5h 96% · 7d 40%", "the forced reading replaces the cached one")
        XCTAssertFalse(offer.isBusy)

        store.setBusy(.moveAccount, for: sessionID)
        offer = try XCTUnwrap(store.offer(for: sessionID))
        XCTAssertTrue(offer.isBusy)
        XCTAssertNil(offer.problem, "a press that started again still shows the last refusal")
    }

    /// Every mutation says so, because the strip is drawn from the store and nothing else pokes
    /// it — a change nobody announced is a strip left showing the offer before it.
    func testEveryChangeIsAnnouncedForItsOwnSession() {
        let center = NotificationCenter()
        let store = LimitEscapeSuggestionStore(center: center)
        let sessionID = SessionID()

        var announced: [SessionID] = []
        let token = center.addObserver(
            forName: LimitEscapeSuggestionDidChange.name,
            object: nil,
            queue: nil
        ) { note in
            guard let event = note.object as? LimitEscapeSuggestionDidChange else { return }
            announced.append(event.sessionID)
        }
        defer { center.removeObserver(token) }

        store.record(Fixture.suggestion(for: sessionID))
        store.setBusy(.moveAccount, for: sessionID)
        store.note(problem: "Nope.", for: sessionID)
        store.dismiss(sessionID)
        store.clear(sessionID)

        XCTAssertEqual(announced, Array(repeating: sessionID, count: 5))
    }

    // MARK: - A Refusal With Nothing To Escape To

    /// The record's shape, stated: a refusal with no login worth moving to is still a record.
    ///
    /// It used to be nothing at all, which is what left somebody with one login staring at a
    /// sidebar triangle and no way to act on it. Waiting for the reset needs no second account,
    /// so the refusal — not the escape — is what the entry is about.
    func testARefusalWithNoLoginIsStillARecord() throws {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()

        store.record(LimitEscapeSuggestion(
            sessionID: sessionID,
            resetHint: "9:40pm (Europe/Rome)",
            model: "claude-opus-5"
        ))

        let offer = try XCTUnwrap(store.offer(for: sessionID))
        XCTAssertFalse(offer.offersAccountEscape)
        XCTAssertNil(offer.accountName)
        XCTAssertEqual(offer.resetHint, "9:40pm (Europe/Rome)")
    }

    /// Dismissal, busy and the problem sentence all live on the entry, so they keep working for a
    /// refusal that names no login — which they could not when there was no entry to hold them.
    func testARefusalWithNoLoginCanStillBeDismissedAndExplained() throws {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()
        store.record(LimitEscapeSuggestion(
            sessionID: sessionID,
            resetHint: "9:40pm (Europe/Rome)",
            model: nil
        ))

        store.note(problem: "There is no usage reading yet to schedule against.", for: sessionID)
        XCTAssertEqual(
            try XCTUnwrap(store.offer(for: sessionID)).problem,
            "There is no usage reading yet to schedule against."
        )

        store.dismiss(sessionID)
        XCTAssertNil(store.offer(for: sessionID))
        XCTAssertNotNil(store.suggestion(for: sessionID))
    }

    /// The upgrade the old shape could not express: a login frees up while somebody is parked,
    /// and the standing refusal grows the button it never had. `update` bailed before, because
    /// there was no entry to update.
    func testALoginGainingHeadroomUpgradesAStandingRefusal() throws {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()
        store.record(LimitEscapeSuggestion(
            sessionID: sessionID,
            resetHint: "9:40pm (Europe/Rome)",
            model: nil
        ))
        XCTAssertFalse(try XCTUnwrap(store.offer(for: sessionID)).offersAccountEscape)

        store.update(Fixture.suggestion(for: sessionID))

        let upgraded = try XCTUnwrap(store.offer(for: sessionID))
        XCTAssertTrue(upgraded.offersAccountEscape)
        XCTAssertEqual(upgraded.accountName, "Daniel Block")
    }

    /// And the upgrade is still the *same* refusal, so a dismissal survives it. Waving away one
    /// refusal is not waving away the state of being refused, but it is also not undone by a
    /// number arriving.
    func testAnUpgradeKeepsTheDismissal() {
        let store = LimitEscapeSuggestionStore(center: NotificationCenter())
        let sessionID = SessionID()
        store.record(LimitEscapeSuggestion(sessionID: sessionID, resetHint: nil, model: nil))
        store.dismiss(sessionID)

        store.update(Fixture.suggestion(for: sessionID))

        XCTAssertNil(store.offer(for: sessionID))
    }

    /// A repeated call that changes nothing announces nothing, so a reading arriving twice does
    /// not rebuild a strip somebody is reading.
    func testAnUnchangedUpdateIsNotAnnounced() {
        let center = NotificationCenter()
        let store = LimitEscapeSuggestionStore(center: center)
        let sessionID = SessionID()
        store.record(Fixture.suggestion(for: sessionID))

        var announcements = 0
        let token = center.addObserver(
            forName: LimitEscapeSuggestionDidChange.name,
            object: nil,
            queue: nil
        ) { _ in announcements += 1 }
        defer { center.removeObserver(token) }

        store.update(Fixture.suggestion(for: sessionID))
        store.setBusy(nil, for: sessionID)

        XCTAssertEqual(announcements, 0)
    }
}
