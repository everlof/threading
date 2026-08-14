import Foundation

// MARK: - Custom Limit Receipt

/// The one sentence a rule prints — in a notification, in a settings row, and later in a hold's
/// receipt and a park's strip.
///
/// Separate from `CustomLimitEvaluator` so the judgement stays free of `L10n` and testable on its
/// answer rather than on this month's wording. Separate from the alert center so the wording can
/// be asserted without a notification center.
///
/// **A rule never masquerades as the provider.** Every sentence here says *your* line, in the
/// user's own percentage, and never borrows the vocabulary a real refusal uses. Conflating the two
/// would teach the reader that the provider's triangle is sometimes negotiable.
enum CustomLimitReceipt {

    // MARK: - Naming

    /// What the rule is called: the user's own words when they gave any, else a sentence derived
    /// from the window and the bound. A rule always has something to be called.
    static func name(for rule: CustomLimit, windowName: String) -> String {
        if let name = rule.name { return name }
        guard rule.bound < CustomLimitDefaults.boundThreshold else {
            return L10n.format("Watch %@", windowName)
        }
        return L10n.format("Keep %1$@ under %2$@", windowName, percent(rule.bound))
    }

    // MARK: - Sentences

    /// The line a crossing announces.
    ///
    /// The percentage named is always the one the **window** reads, because that is the number
    /// printed everywhere else — a notification quoting a fraction of a bound would be the only
    /// place in the app where "60%" meant something other than 60% of the window. Where the
    /// user's own line is tighter than the provider's, the sentence says so, since the reason
    /// this alert exists at all is that the line is theirs.
    static func announcement(
        for evaluation: CustomLimitEvaluation,
        windowName: String
    ) -> String {
        let rule = evaluation.rule
        let threshold = evaluation.announcedThreshold ?? CustomLimitDefaults.boundThreshold
        let atWindow = percent(threshold * rule.bound)

        guard rule.bound < CustomLimitDefaults.boundThreshold else {
            return L10n.format("%1$@ has reached %2$@.", windowName, atWindow)
        }
        guard threshold < CustomLimitDefaults.boundThreshold else {
            return L10n.format(
                "%1$@ has reached %2$@, the limit you set for this account.",
                windowName,
                atWindow
            )
        }
        return L10n.format(
            "%1$@ has reached %2$@, on the way to your %3$@ limit.",
            windowName,
            atWindow,
            percent(rule.bound)
        )
    }

    /// Where the rule stands right now, for a settings row or a tooltip.
    static func status(
        for evaluation: CustomLimitEvaluation,
        windowName: String
    ) -> String {
        switch evaluation.reason {
        case .noReading:
            // Named as a missing *reading*, never as consumption. The two have opposite
            // remedies, and a rule that reports "cannot see" as "over your line" would send the
            // user looking for spend that never happened.
            return L10n.format("No %@ reading yet.", windowName)
        case .notEvaluated:
            return L10n.string("This limit was made in a newer version of Threading.")
        case .underBound(let consumed), .atBound(let consumed):
            let atWindow = percent(consumed * evaluation.rule.bound)
            guard evaluation.rule.bound < CustomLimitDefaults.boundThreshold else {
                return L10n.format("%1$@ is at %2$@.", windowName, atWindow)
            }
            return L10n.format(
                "%1$@ is at %2$@ of your %3$@ limit.",
                windowName,
                atWindow,
                percent(evaluation.rule.bound)
            )
        }
    }

    // MARK: - Formatting

    /// A fraction as whole percent — the vocabulary every usage surface already prints in.
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * CustomLimitReceiptDefaults.percentScale).rounded()))%"
    }
}

// MARK: - Custom Limit Receipt Defaults

enum CustomLimitReceiptDefaults {
    static let percentScale = 100.0
}
