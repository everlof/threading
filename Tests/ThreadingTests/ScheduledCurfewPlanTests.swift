import XCTest

@testable import Threading

/// The two persisted decisions a curfew adds to the schedule store: the end a session start is
/// already carrying, and the purpose its wrap-up rides under.
///
/// Pure Codable cases, because both additions land in files somebody has already written. What
/// matters is therefore not that the new values work — it is what a record from before them
/// decodes into, and what a record written after them says on the wire.
final class ScheduledCurfewPlanTests: XCTestCase {

    // MARK: - Fixture

    private let deadline = Date(timeIntervalSince1970: 1_775_014_800)
    private let createdAt = Date(timeIntervalSince1970: 1_775_000_000)

    private func plan(curfew: ScheduledCurfewPlan? = nil) -> ScheduledSessionPlan {
        ScheduledSessionPlan(
            reservedSessionID: SessionID(),
            projectID: ProjectID(),
            kind: .claude,
            accountHandle: .standard,
            model: nil,
            reasoningEffort: nil,
            branch: nil,
            usesNativeUI: true,
            permissionMode: nil,
            curfew: curfew
        )
    }

    // MARK: - Session Plan

    /// The whole reason the field is optional. A schedule written before curfews existed carries
    /// no `curfew` key at all, and it has to go on decoding as the endless session it was rather
    /// than quarantining a start somebody is still waiting for.
    func testAPlanWrittenBeforeCurfewsExistedDecodesWithNoEnd() throws {
        let written = plan(curfew: .at(deadline))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(written))
                as? [String: Any]
        )
        // The fixture has to carry the key before the test can prove anything by dropping it.
        XCTAssertNotNil(object["curfew"])
        object.removeValue(forKey: "curfew")

        let older = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ScheduledSessionPlan.self, from: older)

        XCTAssertNil(decoded.curfew)
        XCTAssertEqual(decoded.projectID, written.projectID)
        XCTAssertEqual(decoded.reservedSessionID, written.reservedSessionID)
    }

    func testEachCurfewChoiceSurvivesTheWait() throws {
        for choice in [
            ScheduledCurfewPlan.at(deadline),
            .atQuietHours,
            .untilUsageReset(
                expectedAt: deadline,
                windowID: UsageDefaults.weeklyWindowID
            ),
        ] {
            let written = plan(curfew: choice)
            let decoded = try JSONDecoder().decode(
                ScheduledSessionPlan.self,
                from: try JSONEncoder().encode(written)
            )

            XCTAssertEqual(decoded.curfew, choice)
            XCTAssertEqual(decoded, written)
        }
    }

    /// `atQuietHours` is a decision, not a moment, and the difference is the point of the case:
    /// a plan that froze Tuesday's 04:00 and fired on Thursday would name a deadline two days
    /// before its own session started. So nothing dated may appear in what is written down.
    func testQuietHoursIsStoredAsAChoiceRatherThanAFrozenMoment() throws {
        let encoded = try JSONEncoder().encode(ScheduledCurfewPlan.atQuietHours)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertNotNil(object["atQuietHours"])
        XCTAssertNil(object["at"])
        XCTAssertEqual(
            try XCTUnwrap(object["atQuietHours"] as? [String: Any]).count,
            0,
            "the quiet-hours choice carries a payload it should not have"
        )
    }

    // MARK: - Purpose

    /// The wrap-up rides the ordinary schedule store, so its provenance has to survive the file
    /// the same way limit recovery's does — otherwise a reopened store would hand the curfew's
    /// own message back as something the user wrote, and the hold it is exempt from would stop it.
    func testTheWrapUpPurposeSurvivesTheRecordItRidesIn() throws {
        let windDown = ScheduledMessage(
            createdAt: createdAt,
            dueAt: deadline.addingTimeInterval(-CurfewDefaults.windDownMargin),
            target: .session(SessionID()),
            text: "Your curfew is at 04:00. End any loop or goal you are running…",
            purpose: .curfewWindDown
        )

        let encoded = try JSONEncoder().encode(windDown)
        let decoded = try JSONDecoder().decode(ScheduledMessage.self, from: encoded)

        XCTAssertEqual(decoded.purpose, .curfewWindDown)
        XCTAssertEqual(decoded, windDown)
        // Not a recovery continuation: the two share a store and nothing else.
        XCTAssertFalse(decoded.isOwedLimitRecoveryContinuation)

        // The spelling on disk is the compatibility contract; pinning it here is what makes a
        // rename show up as a failing test rather than as a quarantined file.
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"curfewWindDown\""))
    }

    /// A record with no `purpose` key is one written before purposes existed, and it is the
    /// user's. The fallback covers an absent key only — an unknown *value* throws, which is why
    /// adding a case is a downgrade cost rather than a free extension.
    func testARecordWithNoPurposeIsStillTheUsers() throws {
        let message = ScheduledMessage(
            createdAt: createdAt,
            dueAt: deadline,
            target: .session(SessionID()),
            text: "Pick this up",
            purpose: .curfewWindDown
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(message))
                as? [String: Any]
        )
        object.removeValue(forKey: "purpose")

        let older = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ScheduledMessage.self, from: older)

        XCTAssertEqual(decoded.purpose, .userAuthored)
    }
}
