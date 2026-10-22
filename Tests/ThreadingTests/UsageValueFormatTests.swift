import XCTest
import ThreadingRemoteKit
@testable import Threading

/// How money and shares are spelled on the Usage page, on both platforms.
///
/// The vocabulary lives in `ThreadingRemoteKit` because the Mac and the phone render the same
/// prepared values, and the bug it was extracted for was a spelling one: `.currency(code: "USD")`
/// is locale-sensitive, so every reader outside `en_US` got `US$531,676.76` — and on the chart's
/// 64-point value axis, `US$100,0…`. These tests hold both halves of the answer: the exact form
/// for figures that are checked, the compact form for slots whose width is fixed by something
/// other than their text, and one spelling of the decimal point across both.
final class UsageValueFormatTests: XCTestCase {

    // MARK: - The exact figure

    func testCurrencyStatesTheAmountInOneCurrencyAndOneSpelling() {
        XCTAssertEqual(UsageValueFormat.currency(531_676.76), "$531,676.76")
        XCTAssertEqual(UsageValueFormat.currency(0), "$0.00")
        XCTAssertEqual(UsageValueFormat.currency(0.004), "$0.00")
        XCTAssertEqual(UsageValueFormat.currency(1), "$1.00")
        XCTAssertEqual(UsageValueFormat.currency(-12.5), "-$12.50")
    }

    /// The point of the fixed locale, stated as the difference it makes.
    ///
    /// A local estimate of what tokens are worth at published US list prices is a US-dollar
    /// figure whichever country reads it. Formatting it in the reader's locale does not convert
    /// it — it only changes the separators, and buys a disambiguated `US$` in return.
    func testCurrencyDoesNotFollowTheReadersLocale() {
        let swedish = 531_676.76.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2))
                .locale(Locale(identifier: "sv_SE"))
        )
        XCTAssertNotEqual(
            swedish,
            UsageValueFormat.currency(531_676.76),
            "the fixture is only meaningful while a locale can still change this spelling"
        )
        XCTAssertFalse(UsageValueFormat.currency(531_676.76).contains("US$"))
        XCTAssertTrue(UsageValueFormat.currency(531_676.76).hasPrefix("$"))
    }

    func testAnUnmeasurableAmountIsNotPrintedAsANumber() {
        XCTAssertEqual(UsageValueFormat.currency(.nan), "$0.00")
        XCTAssertEqual(UsageValueFormat.currency(.infinity), "$0.00")
        XCTAssertEqual(UsageValueFormat.compactCurrency(.nan), "$0.00")
        XCTAssertEqual(UsageValueFormat.compactCurrency(-.infinity), "$0.00")
    }

    // MARK: - The compact figure

    /// Every magnitude boundary, in order, because each one is a decision: where the decimal
    /// stops earning its place, and where the suffix changes.
    func testCompactCurrencyChangesUnitAtEachStatedBoundary() {
        let cases: [(Double, String)] = [
            (0, "$0"),
            (0.5, "$0.50"),
            (9.99, "$9.99"),
            (531.68, "$531.68"),
            (999.99, "$999.99"),
            (1_000, "$1.0k"),
            (1_260, "$1.3k"),
            (9_999, "$10.0k"),
            (10_000, "$10k"),
            (25_400, "$25k"),
            (1_000_000, "$1.0M"),
            (3_503_525.25, "$3.5M"),
            (1_000_000_000, "$1.0B"),
            (3_450_000_000, "$3.5B")
        ]
        for (value, expected) in cases {
            XCTAssertEqual(UsageValueFormat.compactCurrency(value), expected, "\(value)")
        }
    }

    func testCompactCurrencyKeepsTheSignOutsideTheSymbol() {
        XCTAssertEqual(UsageValueFormat.compactCurrency(-25_400), "-$25k")
        XCTAssertEqual(UsageValueFormat.compactCurrency(-0.5), "-$0.50")
    }

    /// Both halves of the vocabulary group and point the same way, so a column mixing them —
    /// the hero's exact total over a band of compact ones — does not read as two conventions.
    func testBothFormsUseOneDecimalPointAndOneThousandsSeparator() {
        XCTAssertEqual(UsageValueFormat.compactCurrency(4_210.5), "$4.2k")
        XCTAssertEqual(UsageValueFormat.currency(4_210.5), "$4,210.50")
        XCTAssertEqual(UsageValueFormat.compactCurrency(120_000), "$120k")
        XCTAssertTrue(UsageValueFormat.compactCurrency(999_999).contains("k"))
    }

    // MARK: - Shares

    func testShareKeepsOneDecimalSoAColumnOfThemStaysAColumn() {
        XCTAssertEqual(UsageValueFormat.share(0.645), "64.5%")
        XCTAssertEqual(UsageValueFormat.share(1), "100.0%")
        XCTAssertEqual(UsageValueFormat.share(0), "0.0%")
    }

    /// A row that rounds to nothing has to read as *nearly nothing* rather than as a row nobody
    /// measured, which is what a whole-percent share printed for every small model.
    func testANearlyZeroShareIsStillPrintedAsAShare() {
        XCTAssertEqual(UsageValueFormat.share(0.0004), "0.0%")
        XCTAssertEqual(UsageValueFormat.share(0.004), "0.4%")
        XCTAssertEqual(UsageValueFormat.share(.nan), "0.0%")
    }

    func testShareCarriesASignRatherThanDroppingIt() {
        XCTAssertEqual(UsageValueFormat.share(-0.123), "-12.3%")
    }

    // MARK: - The app's own seam

    func testTheAppSpellsMoneyThroughTheSharedVocabulary() {
        XCTAssertEqual(UsageFormat.currency(531_676.76), UsageValueFormat.currency(531_676.76))
        XCTAssertEqual(UsageFormat.compactCurrency(25_400), UsageValueFormat.compactCurrency(25_400))
        XCTAssertEqual(UsageFormat.share(0.645), UsageValueFormat.share(0.645))
    }

    // MARK: - Countdowns

    /// The phone's identity picker writes the same countdown the Mac's account menu does, so
    /// one reset reads as one spelling on both.
    func testACountdownUsesTheLargestReadableUnitsAndNeverReadsZero() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(UsageValueFormat.remaining(until: now.addingTimeInterval(20), from: now), "1m")
        XCTAssertEqual(UsageValueFormat.remaining(until: now.addingTimeInterval(47 * 60), from: now), "47m")
        XCTAssertEqual(
            UsageValueFormat.remaining(until: now.addingTimeInterval(2 * 3600 + 14 * 60), from: now),
            "2h 14m"
        )
        XCTAssertEqual(
            UsageValueFormat.remaining(until: now.addingTimeInterval(3 * 86400 + 4 * 3600), from: now),
            "3d 4h"
        )
        XCTAssertEqual(UsageValueFormat.remaining(until: now.addingTimeInterval(-60), from: now), "1m")
        XCTAssertEqual(UsageValueFormat.duration(12), "12s")
        XCTAssertEqual(UsageValueFormat.duration(5 * 3600), "5h")
    }

    func testTheAppSpellsCountdownsThroughTheSharedVocabulary() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(19 * 3600 + 36 * 60)
        XCTAssertEqual(
            UsageFormat.remaining(until: reset, from: now),
            UsageValueFormat.remaining(until: reset, from: now)
        )
        XCTAssertEqual(UsageFormat.duration(42), UsageValueFormat.duration(42))
    }
}
