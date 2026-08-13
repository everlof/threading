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
        XCTAssertEqual(RowConductStrings.mute(true), "Notifications muted")
    }
}
