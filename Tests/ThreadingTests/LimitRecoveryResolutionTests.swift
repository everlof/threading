import XCTest
@testable import Threading

/// Which scope decides what a conversation does when its account's usage limit refuses it.
///
/// The rule is asserted on values rather than through the store, which is the whole reason
/// `LimitRecoveryResolution`'s chain is pure: this decides whether the app types into somebody's
/// session unattended, and that should be provable with no database, no home directory and no
/// live agent.
///
/// Both halves matter and they are tested together on purpose — `resolve` says what happens, and
/// `inherited` says what a writer compares against before storing anything. A drift between the
/// two is exactly how a chat stops following its project without anybody asking it to.
final class LimitRecoveryResolutionTests: XCTestCase {

    // MARK: - The Chain

    func testTheSessionAnswersFirst() {
        let answer = LimitRecoveryResolution.resolve(
            session: .waitForReset,
            project: .flagOnly,
            app: .flagOnly
        )

        XCTAssertEqual(answer.policy, .waitForReset)
        XCTAssertEqual(answer.scope, .session)
    }

    func testTheProjectAnswersForASessionThatDidNot() {
        let answer = LimitRecoveryResolution.resolve(
            session: nil,
            project: .waitForReset,
            app: .flagOnly
        )

        XCTAssertEqual(answer.policy, .waitForReset)
        XCTAssertEqual(answer.scope, .project)
    }

    func testTheAppAnswersWhenNeitherDid() {
        let answer = LimitRecoveryResolution.resolve(
            session: nil,
            project: nil,
            app: .waitForReset
        )

        XCTAssertEqual(answer.policy, .waitForReset)
        XCTAssertEqual(answer.scope, .app)
    }

    /// The point of the field being optional: a chat that never chose keeps *following*, so a
    /// later change one scope out still reaches it. Recording the current answer at creation
    /// would have frozen every chat against the setting most likely to move.
    func testASessionWithNoAnswerFollowsALaterChange() {
        let before = LimitRecoveryResolution.resolve(session: nil, project: nil, app: .flagOnly)
        let after = LimitRecoveryResolution.resolve(session: nil, project: nil, app: .waitForReset)

        XCTAssertEqual(before.policy, .flagOnly)
        XCTAssertEqual(after.policy, .waitForReset)
    }

    /// A chat inside an armed checkout can still say no, which is the reason the session scope
    /// exists at all rather than the project one being enough.
    func testASessionOverridesItsProjectInBothDirections() {
        XCTAssertEqual(
            LimitRecoveryResolution.resolve(
                session: .flagOnly, project: .waitForReset, app: .waitForReset
            ).policy,
            .flagOnly
        )
        XCTAssertEqual(
            LimitRecoveryResolution.resolve(
                session: .waitForReset, project: .flagOnly, app: .flagOnly
            ).policy,
            .waitForReset
        )
    }

    // MARK: - What A Writer Compares Against

    func testWhatASessionWouldInheritSkipsItsOwnAnswer() {
        XCTAssertEqual(
            LimitRecoveryResolution.inherited(
                beyond: .session, project: .waitForReset, app: .flagOnly
            ),
            .waitForReset
        )
        XCTAssertEqual(
            LimitRecoveryResolution.inherited(beyond: .session, project: nil, app: .waitForReset),
            .waitForReset
        )
    }

    /// A project's own next scope out is the app, and its project field is not consulted for it —
    /// otherwise a checkout would be asked what it inherits from itself.
    func testWhatAProjectWouldInheritIsTheAppAnswer() {
        XCTAssertEqual(
            LimitRecoveryResolution.inherited(
                beyond: .project, project: .waitForReset, app: .flagOnly
            ),
            .flagOnly
        )
    }

    /// The writer's rule, stated as the arithmetic it actually performs: store nil where the
    /// wanted value already matches what would arrive anyway, and an explicit value only where
    /// it genuinely differs. Asserted here because the menu handlers on both rows depend on it
    /// and neither is reachable without a sidebar.
    func testAWantedValueMatchingTheInheritedOneIsStoredAsNil() {
        let inherited = LimitRecoveryResolution.inherited(
            beyond: .session, project: nil, app: .waitForReset
        )

        let storedWhenAgreeing: LimitRecoveryPolicy? =
            LimitRecoveryPolicy.waitForReset == inherited ? nil : .waitForReset
        let storedWhenDiffering: LimitRecoveryPolicy? =
            LimitRecoveryPolicy.flagOnly == inherited ? nil : .flagOnly

        XCTAssertNil(storedWhenAgreeing)
        XCTAssertEqual(storedWhenDiffering, .flagOnly)

        // And the stored nil still resolves to the answer the user asked for.
        XCTAssertEqual(
            LimitRecoveryResolution.resolve(
                session: storedWhenAgreeing, project: nil, app: .waitForReset
            ).policy,
            .waitForReset
        )
    }

    // MARK: - Storage

    /// The raw values are persisted names on two records, so renaming a case would leave every
    /// stored answer unreadable. Pinned here rather than left to review.
    func testThePersistedNamesAreStable() {
        XCTAssertEqual(LimitRecoveryPolicy.flagOnly.rawValue, "flagOnly")
        XCTAssertEqual(LimitRecoveryPolicy.waitForReset.rawValue, "waitForReset")
    }

    /// An answer this build does not recognise reads as "never chose" rather than costing the
    /// record — the conservative direction, since the chain then falls through to a scope that
    /// does answer instead of the session losing its other fields.
    func testASessionDecodesWithoutAPolicyAndWithAnUnknownOne() throws {
        var session = AgentSession(kind: .claude, title: "Chat")
        session.limitRecoveryPolicy = .waitForReset

        let encoded = try JSONEncoder().encode(session)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(json["limitRecoveryPolicy"] as? String, "waitForReset")

        json["limitRecoveryPolicy"] = "somethingALaterBuildInvented"
        let mangled = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: mangled)
        XCTAssertNil(decoded.limitRecoveryPolicy)
        XCTAssertEqual(decoded.title, "Chat")

        json.removeValue(forKey: "limitRecoveryPolicy")
        let absent = try JSONDecoder().decode(
            AgentSession.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(absent.limitRecoveryPolicy)
    }

    /// A record carrying no answer writes no key, so an install that never touched this setting
    /// is byte-for-byte what it was.
    func testASessionWithNoAnswerEncodesNoKey() throws {
        let session = AgentSession(kind: .claude, title: "Chat")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(session)
            ) as? [String: Any]
        )

        XCTAssertNil(json["limitRecoveryPolicy"])
    }
}
