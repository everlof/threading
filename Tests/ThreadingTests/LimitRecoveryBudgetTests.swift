import XCTest
@testable import Threading

/// The floor under the two policies that move a conversation between logins.
///
/// Asserted on values with an injected clock, for `LimitEscapeRanking`'s reason: this is the rule
/// that decides whether an unattended app goes on spending somebody's quota, and it should be
/// provable with no coordinator, no agent and no waiting.
final class LimitRecoveryBudgetTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The Allowance

    func testItAdmitsUpToTheAllowanceAndThenStops() {
        var budget = LimitRecoveryBudget(allowance: 3, window: 3600)
        let sessionID = SessionID()

        XCTAssertTrue(budget.admitMigration(for: sessionID, at: start))
        XCTAssertTrue(budget.admitMigration(for: sessionID, at: start.addingTimeInterval(60)))
        XCTAssertTrue(budget.admitMigration(for: sessionID, at: start.addingTimeInterval(120)))
        XCTAssertFalse(
            budget.admitMigration(for: sessionID, at: start.addingTimeInterval(180)),
            "a fourth hop inside the window is the loop this exists to stop"
        )
        XCTAssertEqual(budget.spent(for: sessionID, at: start.addingTimeInterval(180)), 3)
    }

    /// A refusal spends nothing. Otherwise a session that ran out of budget could never get it
    /// back: every later attempt would push the window forward by refusing.
    func testARefusedAttemptIsNotItselfCharged() {
        var budget = LimitRecoveryBudget(allowance: 1, window: 3600)
        let sessionID = SessionID()

        XCTAssertTrue(budget.admitMigration(for: sessionID, at: start))
        XCTAssertFalse(budget.admitMigration(for: sessionID, at: start.addingTimeInterval(10)))
        XCTAssertEqual(budget.spent(for: sessionID, at: start.addingTimeInterval(10)), 1)

        // The one charged attempt ages out on its own schedule, undelayed by the refusals.
        XCTAssertTrue(budget.admitMigration(for: sessionID, at: start.addingTimeInterval(3601)))
    }

    // MARK: - The Window

    /// A rolling window rather than a lifetime count: a defect loops in seconds and trips this,
    /// while a chat that legitimately outlives several windows over a week must not find the
    /// feature quietly switched off.
    func testSpendingAgesOutSoALongLivedChatIsNeverPermanentlyBarred() {
        var budget = LimitRecoveryBudget(allowance: 2, window: 3600)
        let sessionID = SessionID()

        XCTAssertTrue(budget.admitMigration(for: sessionID, at: start))
        XCTAssertTrue(budget.admitMigration(for: sessionID, at: start.addingTimeInterval(30)))
        XCTAssertFalse(budget.admitMigration(for: sessionID, at: start.addingTimeInterval(60)))

        let later = start.addingTimeInterval(3600 + 31)
        XCTAssertEqual(budget.spent(for: sessionID, at: later), 0)
        XCTAssertTrue(budget.admitMigration(for: sessionID, at: later))
    }

    // MARK: - Per Session

    /// The budget is a fact about one conversation. A chat that hopped its way through the
    /// allowance says nothing about the one beside it, which may be on its first refusal.
    func testOneChatsSpendingDoesNotChargeAnother() {
        var budget = LimitRecoveryBudget(allowance: 1, window: 3600)
        let spent = SessionID()
        let fresh = SessionID()

        XCTAssertTrue(budget.admitMigration(for: spent, at: start))
        XCTAssertFalse(budget.admitMigration(for: spent, at: start))
        XCTAssertTrue(budget.admitMigration(for: fresh, at: start))
    }

    // MARK: - The Shipped Numbers

    /// The backstop has to be loose enough that reality never meets it and tight enough that a
    /// loop does, immediately. Pinned so a later tightening is a decision rather than a typo.
    func testTheShippedAllowanceIsABackstopRatherThanAQuota() {
        XCTAssertEqual(LimitRecoveryDefaults.automaticMigrationAllowance, 3)
        XCTAssertEqual(LimitRecoveryDefaults.automaticMigrationWindow, 3600)

        var budget = LimitRecoveryBudget()
        let sessionID = SessionID()
        for _ in 0..<LimitRecoveryDefaults.automaticMigrationAllowance {
            XCTAssertTrue(budget.admitMigration(for: sessionID, at: start))
        }
        XCTAssertFalse(budget.admitMigration(for: sessionID, at: start))
    }
}
