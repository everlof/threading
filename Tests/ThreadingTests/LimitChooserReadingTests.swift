import XCTest
@testable import Threading

/// The chooser is answered by label and never by position, and everything unrecognised reads as
/// absent — the fail-closed contract `limit-recovery.md` states, pinned screen by screen.
final class LimitChooserReadingTests: XCTestCase {

    // MARK: - Reading the chooser

    /// The specimen screen: stop-and-wait first, preselected. Return alone answers it.
    func testReadsTheSpecimenChooserWithTheMarkerOnStopAndWait() {
        let outcome = LimitChooserReading.read(screenLines: [
            "What do you want to do?",
            "❯ 1. Stop and wait for limit to reset",
            "  2. Upgrade your plan",
            "Enter to confirm · Esc to cancel"
        ])

        XCTAssertEqual(
            outcome,
            .chooser(.init(optionDigit: "1", markerOnOption: true))
        )
    }

    /// The user remembers the options in the other order — the disagreement that is the whole
    /// specification. The digit follows the label, wherever the label sits.
    func testReadsAChooserWhoseOptionsAreReordered() {
        let outcome = LimitChooserReading.read(screenLines: [
            "  1. Upgrade your plan",
            "❯ 2. Stop and wait for limit to reset"
        ])

        XCTAssertEqual(
            outcome,
            .chooser(.init(optionDigit: "2", markerOnOption: true))
        )
    }

    /// A marker on the wrong row means the digit must move it first — Return is not yet safe,
    /// and the reading says so.
    func testReportsTheMarkerElsewhereSoTheCallerVerifiesBeforeReturn() {
        let outcome = LimitChooserReading.read(screenLines: [
            "❯ 1. Upgrade your plan",
            "  2. Stop and wait for limit to reset"
        ])

        XCTAssertEqual(
            outcome,
            .chooser(.init(optionDigit: "2", markerOnOption: false))
        )
    }

    func testAcceptsTheAsciiMarkerAndAnyCasing() {
        let outcome = LimitChooserReading.read(screenLines: [
            "> 2. STOP AND WAIT FOR LIMIT TO RESET",
            "  1. Upgrade your plan"
        ])

        XCTAssertEqual(
            outcome,
            .chooser(.init(optionDigit: "2", markerOnOption: true))
        )
    }

    // MARK: - The chooser-less notice

    /// The refusal's other shape, from the second specimen: the sentence printed inline under
    /// a finished background workflow, the CLI back at its prompt, nothing to answer.
    func testReadsTheChooserlessNoticeForm() {
        let outcome = LimitChooserReading.read(screenLines: [
            "└ You've hit your session limit · resets 1:10pm (Europe/Rome)",
            "  /upgrade to increase your usage limit.",
            "new task? /clear to save 707.1k tokens"
        ])

        XCTAssertEqual(outcome, .notice)
    }

    /// Either mark alone carries it: the reset clause with its limit, or the slash-command
    /// hint the chooser never shows.
    func testEitherNoticeMarkAloneIsEnough() {
        XCTAssertEqual(
            LimitChooserReading.read(screenLines: [
                "You've hit your session limit · resets 1:10pm (Europe/Rome)"
            ]),
            .notice
        )
        XCTAssertEqual(
            LimitChooserReading.read(screenLines: [
                "/upgrade to increase your usage limit."
            ]),
            .notice
        )
    }

    /// A screen holding both shapes is the chooser: something is standing that a keystroke
    /// answers, and the notice is just the sentence it stands beside.
    func testAChooserOutranksTheNotice() {
        let outcome = LimitChooserReading.read(screenLines: [
            "You've hit your session limit · resets 1:10pm (Europe/Rome)",
            "❯ 1. Stop and wait for limit to reset",
            "  2. Upgrade your plan"
        ])

        XCTAssertEqual(
            outcome,
            .chooser(.init(optionDigit: "1", markerOnOption: true))
        )
    }

    /// A chooser wrapped mid-label must never pass for the notice — the outcome that would
    /// schedule around a standing chooser. Wrapped after the identifying words it is still
    /// the chooser, answered as one; wrapped *inside* them it is nothing, and stands down.
    /// Neither is `.notice`, because the stop row says "…for limit to reset" — `reset`,
    /// never the notice's `resets `.
    func testAWrappedChooserNeverReadsAsTheNotice() {
        XCTAssertEqual(
            LimitChooserReading.read(screenLines: [
                "❯ 1. Stop and wait for limit to",
                "reset",
                "  2. Upgrade your plan"
            ]),
            .chooser(.init(optionDigit: "1", markerOnOption: true))
        )

        let brokenLabel = LimitChooserReading.read(screenLines: [
            "❯ 1. Stop and",
            "wait for limit to reset",
            "  2. Upgrade your plan"
        ])
        guard case .absent = brokenLabel else {
            return XCTFail("A chooser broken inside its label must stand down: \(brokenLabel)")
        }
    }

    /// Prose about resets needs the limit in the same breath before it reads as the notice.
    func testProseAboutResetsAloneIsNotTheNotice() {
        let outcome = LimitChooserReading.read(screenLines: [
            "The window resets at nine, so run it in the morning."
        ])

        guard case .absent = outcome else {
            return XCTFail("A reset clause without its limit is not the refusal: \(outcome)")
        }
    }

    // MARK: - Failing closed

    func testRefusesAScreenWithoutTheStopRow() {
        let outcome = LimitChooserReading.read(screenLines: [
            "❯ 1. Yes, continue",
            "  2. No, cancel"
        ])

        guard case .absent = outcome else {
            return XCTFail("A different chooser must never be answered: \(outcome)")
        }
    }

    /// An agent's own output can contain the sentence — the conversation that designed this
    /// feature did. Prose has no leading digit, so it is not an option row.
    func testRefusesProseThatMerelyQuotesThePhrase() {
        let outcome = LimitChooserReading.read(screenLines: [
            "I will stop and wait for limit to reset, as you asked.",
            "Upgrade your plan whenever you like."
        ])

        guard case .absent = outcome else {
            return XCTFail("Prose must not read as a chooser: \(outcome)")
        }
    }

    /// The chooser always offers the paid way out beside the wait; a lone stop row is some
    /// other screen quoting it.
    func testRefusesWhenTheCompanionUpgradeRowIsMissing() {
        let outcome = LimitChooserReading.read(screenLines: [
            "❯ 1. Stop and wait for limit to reset"
        ])

        guard case .absent = outcome else {
            return XCTFail("A chooser needs both options to be believed: \(outcome)")
        }
    }

    func testRefusesWhenTwoRowsClaimTheOption() {
        let outcome = LimitChooserReading.read(screenLines: [
            "❯ 1. Stop and wait for limit to reset",
            "  2. Stop and wait for limit to reset",
            "  3. Upgrade your plan"
        ])

        guard case .absent = outcome else {
            return XCTFail("An ambiguous chooser must not be answered: \(outcome)")
        }
    }

    func testRefusesAStopRowThatAlsoMentionsUpgrading() {
        let outcome = LimitChooserReading.read(screenLines: [
            "❯ 1. Stop and wait for limit to reset, or upgrade your plan",
            "  2. Upgrade your plan"
        ])

        guard case .absent = outcome else {
            return XCTFail("A row naming both choices is not a parse to act on: \(outcome)")
        }
    }

    func testRefusesAnEmptyScreen() {
        guard case .absent = LimitChooserReading.read(screenLines: []) else {
            return XCTFail("An empty screen is not a chooser")
        }
    }

    /// The absence carries its reason — "it did nothing" and "it read the wrong screen" are
    /// different bugs, and the journal is where they are told apart.
    func testAnAbsenceNamesItsReason() {
        let outcome = LimitChooserReading.read(screenLines: ["nothing relevant"])

        guard case .absent(let reason) = outcome else {
            return XCTFail("Expected an absence: \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
    }
}
