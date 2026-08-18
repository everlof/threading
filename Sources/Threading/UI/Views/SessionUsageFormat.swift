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
