import Foundation

/// Shared wording for the Status Card, Overview › Info, and Subagents navigator.
enum SessionUsageFormat {
    static func compact(_ reading: SessionUsageSnapshot.Reading) -> String {
        var parts = [tokenCount(reading.processedTokens)]
        if let cost = compactCost(reading) { parts.append(cost) }
        return parts.joined(separator: " · ")
    }

    static func childDetail(
        _ reading: SessionUsageSnapshot.Reading,
        liveTokenAlreadyShown: Bool
    ) -> String? {
        var parts: [String] = []
        if !liveTokenAlreadyShown, reading.processedTokens > 0 {
            parts.append(tokenCount(reading.processedTokens))
        }
        if let cost = compactCost(reading) { parts.append(cost) }
        if reading.records > 0 {
            parts.append(responseCount(reading.records))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func tokenCount(_ count: Int64) -> String {
        L10n.format("%@ tokens", UsageFormat.tokens(max(0, count)))
    }

    static func responseCount(_ count: Int) -> String {
        L10n.format("%lld requests", Int64(count))
    }

    static func detailedCost(_ reading: SessionUsageSnapshot.Reading) -> String {
        let value = reading.cost.totalUSD
        let indexedUnpriced = reading.cost.unpricedTokens

        var answer: String
        switch (reading.cost.providerReportedUSD > 0, reading.cost.catalogPricedUSD > 0) {
        case (true, false):
            answer = L10n.format("%@ provider reported", UsageFormat.currency(value))
        case (false, true):
            answer = L10n.format("%@ list-price estimate", UsageFormat.currency(value))
        case (true, true):
            answer = L10n.format("%@ reported + estimated", UsageFormat.currency(value))
        case (false, false):
            answer = L10n.string("None available")
        }

        if indexedUnpriced > 0 {
            answer += " · " + L10n.format(
                "%@ unpriced",
                UsageFormat.tokens(indexedUnpriced)
            )
        }
        return answer
    }

    /// The amount a Cost row states, or a dash when nothing priced it.
    static func costAmount(_ reading: SessionUsageSnapshot.Reading) -> String {
        let value = reading.cost.totalUSD
        return value > 0 ? UsageFormat.currency(value) : "—"
    }

    /// The line under a Cost row: which kind of dollars these are, and what the figure leaves
    /// out. A phrase rather than the sentence that used to sit there — a row's second line is
    /// a qualifier, and the sentence was truncated at every width the panel is shown at.
    static func costProvenance(_ reading: SessionUsageSnapshot.Reading) -> String {
        var answer: String
        switch (reading.cost.providerReportedUSD > 0, reading.cost.catalogPricedUSD > 0) {
        case (true, false):
            answer = L10n.string("Provider reported")
        case (false, true):
            answer = L10n.string("List-price estimate")
        case (true, true):
            answer = L10n.string("Reported + estimated")
        case (false, false):
            answer = L10n.string("None available")
        }

        let indexedUnpriced = reading.cost.unpricedTokens
        if indexedUnpriced > 0 {
            answer += " · " + L10n.format("%@ unpriced", UsageFormat.tokens(indexedUnpriced))
        }
        return answer
    }

    static func compactCost(_ reading: SessionUsageSnapshot.Reading) -> String? {
        let value = reading.cost.totalUSD
        guard value > 0 else { return nil }
        let isPartial = reading.cost.unpricedTokens > 0 || reading.unindexedTokens > 0
        let amount = UsageFormat.currency(value) + (isPartial ? "+" : "")

        switch (reading.cost.providerReportedUSD > 0, reading.cost.catalogPricedUSD > 0) {
        case (true, false): return L10n.format("%@ reported", amount)
        case (false, true): return L10n.format("%@ est.", amount)
        case (true, true): return L10n.format("%@ mixed", amount)
        case (false, false): return nil
        }
    }
}
