import Foundation

/// How a measured usage value is spelled, shared by every renderer of the Usage dashboard.
///
/// This is here — beside the wire contract rather than inside either app — for the reason the
/// contract itself is: the Mac and the phone present the *same prepared values*, so they must
/// not disagree about how those values read. They did. Three call sites each wrote
/// `.currency(code: "USD")` with a different precision, and that spelling is locale-sensitive:
/// outside `en_US`, Foundation disambiguates the dollar and prints `US$531,676.76`. On the
/// chart's 64-point value axis that becomes `US$100,0…`, which is not a number.
///
/// So the money on this page is stated in one locale on purpose. A local estimate of what an
/// agent's tokens are worth at published US list prices is a US-dollar figure whichever country
/// reads it; formatting it in the reader's locale does not convert it, it only changes the
/// separators — and buys an ambiguous currency symbol in return.
public enum UsageValueFormat {

    /// The exact figure, where the exact figure is the point: `$531,676.76`.
    ///
    /// Used for the hero total and for each breakdown row, because those are the numbers a
    /// reader checks against an invoice.
    public static func currency(_ value: Double) -> String {
        guard value.isFinite else { return abbreviated(0, decimals: 2) }
        return value.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(2))
                .locale(formattingLocale)
        )
    }

    /// The same amount at a glance: `$0`, `$531.68`, `$25k`, `$1.2M`, `$3.5B`.
    ///
    /// For a slot whose width is fixed by something other than the text in it — a chart's value
    /// axis, a stat in a five-column band. Precision there is not the point; fitting is, and a
    /// truncated number is worse than a rounded one.
    public static func compactCurrency(_ value: Double) -> String {
        guard value.isFinite else { return abbreviated(0, decimals: 2) }
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        if magnitude >= 1_000_000_000 {
            return sign + abbreviated(magnitude / 1_000_000_000, decimals: 1, suffix: "B")
        }
        if magnitude >= 1_000_000 {
            return sign + abbreviated(magnitude / 1_000_000, decimals: 1, suffix: "M")
        }
        // Ten thousand is where a decimal stops earning its place: `$25k` is exact enough to
        // read a chart against, while `$1.2k` still says something `$1k` does not.
        if magnitude >= 10_000 {
            return sign + abbreviated(magnitude / 1_000, decimals: 0, suffix: "k")
        }
        if magnitude >= 1_000 {
            return sign + abbreviated(magnitude / 1_000, decimals: 1, suffix: "k")
        }
        // Under a thousand there is nothing to abbreviate, and a bare `$0` beats `$0.00` on an
        // axis whose whole job is to be read past.
        return sign + abbreviated(magnitude, decimals: magnitude == magnitude.rounded() ? 0 : 2)
    }

    /// A share of a total: `64.5%`, `0.0%`.
    ///
    /// One decimal, always, so a column of shares stays a column — and so a row that rounds to
    /// nothing reads as *nearly nothing* rather than as an unmeasured zero.
    public static func share(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0.0%" }
        return String(format: "%.1f%%", fraction * 100)
    }

    private static let currencyCode = "USD"

    /// Fixed rather than the reader's: see the type's note.
    private static let formattingLocale = Locale(identifier: "en_US")

    /// `String(format:)` with no locale argument formats POSIX-style — `.` for the decimal
    /// point — which is the same spelling `formattingLocale` gives the exact form, so the two
    /// halves of this vocabulary cannot drift apart at the abbreviation boundary.
    private static func abbreviated(
        _ value: Double,
        decimals: Int,
        suffix: String = ""
    ) -> String {
        let digits = String(format: "%.\(decimals)f", value)
        return "$\(grouped(digits))\(suffix)"
    }

    /// Thousands separators for the un-abbreviated branch, so `$531.68` and `$4,210.00` come
    /// out of the same code path as `$25k`.
    private static func grouped(_ digits: String) -> String {
        let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, whole.count > 3 else { return digits }
        var grouped: [Character] = []
        for (offset, character) in whole.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) { grouped.append(",") }
            grouped.append(character)
        }
        let head = String(grouped.reversed())
        return parts.count > 1 ? "\(head).\(parts[1])" : head
    }
}
