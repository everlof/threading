import XCTest
import ThreadingRemoteKit
@testable import Threading

/// Which of a project's listed logins a new chat starts on.
///
/// Pure throughout: each candidate states its presence, reading and limits, so the rule is pinned
/// without a home directory, a usage service or a store. The asymmetry with `LimitEscapeRanking`
/// is the point of several cases here — a stale reading proves exhaustion but never headroom, and
/// an unknown reading keeps its place in the user's order.
final class ProjectAccountOrderTests: XCTestCase {

    // MARK: - Fixture

    private enum Fixture {
        static let now = Date(timeIntervalSince1970: 1_770_000_000)

        static func id(_ name: String, _ provider: AgentKind = .claude) -> AccountID {
            AccountID(provider: provider, handle: AccountHandle(storedName: name))
        }

        static func window(
            _ id: String,
            _ fraction: Double?,
            resetsIn: TimeInterval = 3_600,
            scopeName: String? = nil
        ) -> AccountUsage.Window {
            AccountUsage.Window(
                id: id,
                label: id,
                fraction: fraction,
                resetsAt: now.addingTimeInterval(resetsIn),
                windowDuration: UsageDefaults.fiveHourSeconds,
                scopeName: scopeName
            )
        }

        static func usage(
            _ windows: [AccountUsage.Window],
            modelWindows: [AccountUsage.Window] = []
        ) -> AccountUsage {
            var usage = AccountUsage(windows: windows, planLabel: nil, observedAt: now, source: .api)
            usage.modelWindows = modelWindows
            return usage
        }

        static func candidate(
            _ name: String,
            _ reading: AccountUsageReading,
            provider: AgentKind = .claude,
            presence: ProjectAccountOrder.Presence = .enabled,
            limits: [CustomLimit] = [],
            model: String? = nil
        ) -> ProjectAccountOrder.Candidate {
            ProjectAccountOrder.Candidate(
                accountID: id(name, provider),
                presence: presence,
                reading: reading,
                limits: limits,
                model: model
            )
        }

        static func current(_ windows: AccountUsage.Window...) -> AccountUsageReading {
            .current(usage(windows))
        }

        static func stale(_ windows: AccountUsage.Window...) -> AccountUsageReading {
            .stale(usage(windows), error: .network("offline"))
        }
    }

    private func state(_ candidate: ProjectAccountOrder.Candidate) -> ProjectAccountOrder.State {
        ProjectAccountOrder.state(of: candidate, at: Fixture.now)
    }

    // MARK: - States

    func testACurrentReadingBelowTheLineIsUsable() {
        let candidate = Fixture.candidate("work", Fixture.current(Fixture.window("5h", 0.4)))
        XCTAssertEqual(state(candidate), .usable)
    }

    func testAWindowAtTheLineIsSpentUntilItResets() {
        let window = Fixture.window("7d", 0.95, resetsIn: 7_200)
        let candidate = Fixture.candidate("work", Fixture.current(window))
        XCTAssertEqual(state(candidate), .spent(until: window.resetsAt, cause: .provider))
    }

    func testAStaleReadingProvesExhaustionButNeverHeadroom() {
        let high = Fixture.candidate("work", Fixture.stale(Fixture.window("5h", 0.97)))
        let low = Fixture.candidate("spare", Fixture.stale(Fixture.window("5h", 0.10)))

        guard case .spent = state(high) else {
            return XCTFail("usage only grows inside a window, so an old 97% is still at least 97%")
        }
        XCTAssertEqual(state(low), .unverified, "an old 10% may be anything now")
    }

    func testNoReadingAFailedReadingAndAnExpiredWindowAreUnverified() {
        XCTAssertEqual(state(Fixture.candidate("a", .notFetched)), .unverified)
        XCTAssertEqual(state(Fixture.candidate("b", .failed(.tokenExpired))), .unverified)
        let expired = Fixture.window("5h", 0.99, resetsIn: -60)
        XCTAssertEqual(
            state(Fixture.candidate("c", Fixture.current(expired))),
            .unverified,
            "a window whose reset has passed describes the previous window"
        )
    }

    func testDisabledAndMissingLoginsAreUnavailable() {
        let reading = Fixture.current(Fixture.window("5h", 0.1))
        XCTAssertEqual(
            state(Fixture.candidate("off", reading, presence: .disabled)),
            .unavailable(.disabled)
        )
        XCTAssertEqual(
            state(Fixture.candidate("gone", reading, presence: .missing)),
            .unavailable(.missing)
        )
        XCTAssertEqual(
            state(Fixture.candidate("default", reading, provider: .grok)),
            .unavailable(.missing),
            "a runtime that routes no logins cannot be listed"
        )
    }

    func testTheUsersOwnLineIsTheLineAndSaysSo() {
        let limits = [CustomLimit(windowID: "5h", bound: 0.5)]
        let window = Fixture.window("5h", 0.48)
        let candidate = Fixture.candidate("work", Fixture.current(window), limits: limits)
        XCTAssertEqual(state(candidate), .spent(until: window.resetsAt, cause: .ownLimit))
    }

    func testAModelScopedWindowCountsOnlyForTheModelItMeters() {
        let reading = AccountUsageReading.current(Fixture.usage(
            [Fixture.window("7d", 0.2)],
            modelWindows: [Fixture.window("Fable", 0.96, scopeName: "Fable")]
        ))
        guard case .spent = state(Fixture.candidate("work", reading, model: "claude-fable-5-1")) else {
            return XCTFail("a chat on Fable runs out of the Fable window first")
        }
        XCTAssertEqual(state(Fixture.candidate("work", reading, model: "claude-opus-5-5")), .usable)
    }

    // MARK: - The Pick

    func testTheFirstPickableLoginWinsInTheUsersOrder() {
        let resolution = ProjectAccountOrder.resolve([
            Fixture.candidate("work", Fixture.current(Fixture.window("5h", 0.99))),
            Fixture.candidate("spare", .notFetched),
            Fixture.candidate("roomy", Fixture.current(Fixture.window("5h", 0.01)))
        ], at: Fixture.now)

        XCTAssertEqual(resolution.chosen, Fixture.id("spare"), "order outranks how much is known")
        XCTAssertEqual(resolution.skipped.map(\.accountID), [Fixture.id("work")])
        XCTAssertFalse(resolution.isEverythingSpent)
    }

    func testTheListMayCrossRuntimes() {
        let resolution = ProjectAccountOrder.resolve([
            Fixture.candidate("work", Fixture.current(Fixture.window("5h", 0.99))),
            Fixture.candidate("default", .notFetched, provider: .codex)
        ], at: Fixture.now)
        XCTAssertEqual(resolution.chosen, Fixture.id("default", .codex))
    }

    func testWhenEverythingIsSpentTheOneBackSoonestWinsWithTiesToTheList() {
        let resolution = ProjectAccountOrder.resolve([
            Fixture.candidate("late", Fixture.current(Fixture.window("7d", 0.99, resetsIn: 9_000))),
            Fixture.candidate("soon", Fixture.current(Fixture.window("5h", 0.99, resetsIn: 600))),
            Fixture.candidate("tie", Fixture.current(Fixture.window("5h", 0.99, resetsIn: 600)))
        ], at: Fixture.now)
        XCTAssertEqual(resolution.chosen, Fixture.id("soon"))
        XCTAssertTrue(resolution.isEverythingSpent)
    }

    func testNothingIsChosenWhenNothingListedIsAvailable() {
        let resolution = ProjectAccountOrder.resolve([
            Fixture.candidate("off", .notFetched, presence: .disabled),
            Fixture.candidate("gone", .notFetched, presence: .missing)
        ], at: Fixture.now)
        XCTAssertNil(resolution.chosen)
    }

    // MARK: - The Send

    func testASendMovesOnlyOffAProvenSpentLoginOntoTheNextPickableOfItsRuntime() {
        let spent = Fixture.candidate("work", Fixture.current(Fixture.window("5h", 0.99)))
        let codex = Fixture.candidate("default", .notFetched, provider: .codex)
        let spare = Fixture.candidate("spare", .notFetched)

        let moved = ProjectAccountOrder.substitute(
            for: spent,
            among: [spent, codex, spare],
            at: Fixture.now
        )
        XCTAssertEqual(moved?.accountID, Fixture.id("spare"), "never across runtimes at the send")

        let unknown = Fixture.candidate("work", .notFetched)
        XCTAssertNil(
            ProjectAccountOrder.substitute(for: unknown, among: [unknown, spare], at: Fixture.now),
            "an unknown reading is not evidence"
        )
    }

    func testASendWithNowhereToGoKeepsItsLogin() {
        let spent = Fixture.candidate("work", Fixture.current(Fixture.window("5h", 0.99)))
        let alsoSpent = Fixture.candidate("spare", Fixture.current(Fixture.window("5h", 0.99)))
        XCTAssertNil(ProjectAccountOrder.substitute(
            for: spent,
            among: [spent, alsoSpent],
            at: Fixture.now
        ))
    }

    // MARK: - The Stored Form

    func testTheStoredListIsDeduplicatedCappedAndNeverEmpty() {
        let work = Fixture.id("work")
        XCTAssertNil(ProjectAccountOrder.normalized(nil))
        XCTAssertNil(ProjectAccountOrder.normalized([]))
        XCTAssertEqual(ProjectAccountOrder.normalized([work, work, Fixture.id("spare")]), [
            work, Fixture.id("spare")
        ])
        let many = (0..<40).map { Fixture.id("login-\($0)") }
        XCTAssertEqual(
            ProjectAccountOrder.normalized(many)?.count,
            ProjectAccountDefaults.maximumEntries
        )
    }

    func testAProjectKeepsItsListAcrossEncodingAndDropsOnlyEntriesItCannotRead() throws {
        var project = Project(name: "Fixture", folderURL: URL(fileURLWithPath: "/tmp/fixture"))
        project.defaultAccounts = [Fixture.id("work"), Fixture.id("default", .codex)]

        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.defaultAccounts, project.defaultAccounts)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        )
        object["defaultAccounts"] = ["future:login", "claude:work"]
        let lenient = try JSONDecoder().decode(
            Project.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(lenient.defaultAccounts, [Fixture.id("work")])

        object.removeValue(forKey: "defaultAccounts")
        let older = try JSONDecoder().decode(
            Project.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(older.defaultAccounts)
    }

    // MARK: - Agreement With The Phone

    func testThePhonePredictsWithTheMacsOwnNumbers() {
        XCTAssertEqual(ProjectAccountDefaults.spentFraction, RemoteProjectDefaultAccounts.spentFraction)
        XCTAssertEqual(ProjectAccountDefaults.maximumEntries, RemoteProjectDefaultAccounts.maximumEntries)
    }

    // MARK: - Limit Recovery Follows The Order

    func testFirstWithHeadroomKeepsTheGivenOrderRatherThanPace() {
        let behind = LimitEscapeRanking.Candidate(
            accountID: Fixture.id("first"),
            usage: Fixture.usage([Fixture.window("5h", 0.30)])
        )
        let roomier = LimitEscapeRanking.Candidate(
            accountID: Fixture.id("second"),
            usage: Fixture.usage([Fixture.window("5h", 0.01)])
        )
        let spent = LimitEscapeRanking.Candidate(
            accountID: Fixture.id("spent"),
            usage: Fixture.usage([Fixture.window("5h", 0.90)])
        )
        XCTAssertEqual(
            LimitEscapeRanking.firstWithHeadroom(
                in: [spent, behind, roomier],
                metering: nil,
                at: Fixture.now
            )?.accountID,
            Fixture.id("first")
        )
    }
}
