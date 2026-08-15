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

        switch rule.metric {
        case .syntheticWindow:
            guard let span = rule.trailingSpan else {
                return L10n.format("Watch %@", windowName)
            }
            // Named after what it *is* — a window the user recreated — rather than after the
            // provider window it is funded from, which is a denominator rather than a subject.
            return L10n.format(
                "No more than %1$@ of %2$@ in any %3$@",
                percent(rule.bound),
                windowName,
                UsageFormat.duration(span)
            )
        case .paceShare:
            return L10n.format(
                "Leave %1$@ of %2$@ for its owner",
                percent(1 - rule.bound),
                windowName
            )
        case .fixedCap:
            guard rule.bound < CustomLimitDefaults.boundThreshold else {
                return L10n.format("Watch %@", windowName)
            }
            return L10n.format("Keep %1$@ under %2$@", windowName, percent(rule.bound))
        }
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
            // A synthetic rule's status is about the *span*, not about where the provider window
            // stands: "62% of the weekly" would be a number this rule is not measuring.
            if evaluation.rule.metric == .syntheticWindow, let span = evaluation.rule.trailingSpan {
                return L10n.format(
                    "%1$@ spent in the last %2$@, of your %3$@ budget.",
                    percent(evaluation.windowFraction ?? 0),
                    UsageFormat.duration(span),
                    percent(evaluation.rule.bound)
                )
            }
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

    // MARK: - Holds

    /// The one sentence a hold's receipt prints.
    ///
    /// The two cases are worded to keep their remedies apart, which is the whole reason the hold
    /// type has two cases: "over your line" is answered by raising the line or waiting for the
    /// reset, "cannot see" by looking again. A receipt that said the first when it meant the
    /// second would send the reader hunting for spend that never happened.
    static func holdReason(_ hold: CustomLimitHold) -> String {
        switch hold {
        case .clear:
            return L10n.string("No limit of yours is holding this account.")
        case .overLine(let rule, let windowName):
            return L10n.format(
                "%1$@ is at your %2$@ limit, so Threading is not spending this account on its own.",
                windowName,
                percent(rule.bound)
            )
        case .cannotSee(_, let windowName):
            return L10n.format(
                "Threading cannot read %@ right now, so it is not spending this account on its own.",
                windowName
            )
        }
    }

    /// The short form, for a place with one line and no room for a sentence — a menu receipt, a
    /// ranking's exclusion note.
    static func holdSummary(_ hold: CustomLimitHold) -> String? {
        switch hold {
        case .clear: return nil
        case .overLine: return L10n.string("Excluded by your limit")
        case .cannotSee: return L10n.string("No reading for your limit")
        }
    }

    /// The compact form a row's mark carries — the window and the line, nothing else. A row has
    /// no space for a sentence, and a mark that only said "held" would leave the reader guessing
    /// which of their limits did it.
    static func holdSummaryLine(_ hold: CustomLimitHold, rule: CustomLimit) -> String {
        switch hold {
        case .clear:
            return ""
        case .overLine(_, let windowName):
            return L10n.format("%1$@ at %2$@", windowName, percent(rule.bound))
        case .cannotSee(_, let windowName):
            return L10n.format("no %@ reading", windowName)
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
