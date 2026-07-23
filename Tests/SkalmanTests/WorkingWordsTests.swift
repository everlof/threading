import XCTest
@testable import Skalman

/// The rules that make the status line readable rather than merely varied: every word says
/// "busy", no word repeats until the rest have been used, and none repeats back to back.
final class WorkingWordsTests: XCTestCase {

    // MARK: - Vocabulary

    func testVocabularyIsDistinctAndNonEmpty() {
        XCTAssertEqual(Set(WorkingWords.all).count, WorkingWords.all.count, "duplicate word")
        XCTAssertFalse(WorkingWords.all.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// A word without its ellipsis reads as a finished state rather than an ongoing one, which
    /// is the opposite of what the status line is for.
    func testEveryWordTrailsOff() {
        for word in WorkingWords.all {
            XCTAssertTrue(word.hasSuffix("…"), "\(word) does not read as ongoing")
        }
    }

    /// The familiar word is kept: the point is variety around it, not replacing it.
    func testVocabularyKeepsThinking() {
        XCTAssertTrue(WorkingWords.all.contains("Thinking…"))
    }

    // MARK: - Cycle

    func testDealsEveryWordBeforeRepeatingAny() {
        var cycle = WorkingWordCycle()
        let dealt = (0..<WorkingWords.all.count).map { _ in cycle.next() }

        XCTAssertEqual(Set(dealt), Set(WorkingWords.all), "a word repeated before the bag emptied")
    }

    func testRefillsRatherThanRunningOut() {
        var cycle = WorkingWordCycle()
        let dealt = (0..<(WorkingWords.all.count * 3)).map { _ in cycle.next() }

        XCTAssertEqual(dealt.count, WorkingWords.all.count * 3)
        XCTAssertFalse(dealt.contains(""))
    }

    /// The seam between two bags is the one place the shuffle alone does not prevent a repeat.
    /// Two words make it deterministic: any correct cycle can only alternate.
    func testNeverRepeatsAcrossTheSeam() {
        var cycle = WorkingWordCycle(words: ["one…", "two…"])
        let dealt = (0..<20).map { _ in cycle.next() }

        for (previous, next) in zip(dealt, dealt.dropFirst()) {
            XCTAssertNotEqual(previous, next, "the same word twice running")
        }
    }

    func testSingleWordCycleStillAnswers() {
        var cycle = WorkingWordCycle(words: ["only…"])

        XCTAssertEqual(cycle.next(), "only…")
        XCTAssertEqual(cycle.next(), "only…")
    }

    /// `next()` returns a word rather than an optional, so an empty vocabulary has to resolve
    /// to something at construction rather than at the call that needs a label.
    func testEmptyVocabularyFallsBackToTheRealOne() {
        var cycle = WorkingWordCycle(words: [])

        XCTAssertTrue(WorkingWords.all.contains(cycle.next()))
    }

    // MARK: - Turn Receipt

    func testWorkingStatusTicksWithEffort() {
        XCTAssertEqual(
            TurnStatusText.working(word: "Pondering…", elapsed: 89.9, effort: "xhigh"),
            "Pondering…  (1m 29s · xhigh effort)"
        )
    }

    func testFinishedStatusKeepsTheLastRoundTripVisible() {
        let metrics = TurnMetrics(duration: 89.9, outputTokens: 3_149, effort: "xhigh")

        XCTAssertEqual(
            TurnStatusText.ready(model: nil, lastTurn: metrics),
            "Ready · last turn 1m 29s · ↓ 3.1k tokens · xhigh effort"
        )
    }

    func testReceiptFormattingScalesWithoutFalsePrecision() {
        XCTAssertEqual(TurnStatusText.duration(7_445), "2h 4m 5s")
        XCTAssertEqual(TurnStatusText.tokenCount(999), "999")
        XCTAssertEqual(TurnStatusText.tokenCount(12_000), "12k")
        XCTAssertEqual(TurnStatusText.tokenCount(1_250_000), "1.3m")
    }
}
