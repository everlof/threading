import Foundation

// MARK: - Usage Window Burn

/// How long this account takes to spend one short window *while actually working*.
///
/// The number the whole poke is derived from, and the one nobody can be asked for. "How many
/// hours of Claude does it take you to hit the five-hour limit" is answerable only by someone who
/// has already watched their own usage bar for a week, which is exactly what
/// `UsageHistoryStore` has been doing.
///
/// It is deliberately not "time from window start to exhaustion". A window anchored at 07:00 and
/// exhausted at 15:00 did not take eight hours of work if lunch was two of them; it took six, and
/// six is the number the lead has to be derived from. So idle stretches are dropped and what is
/// measured is the rate *during* movement, inverted.
enum UsageWindowBurn {

    // MARK: - Estimate

    /// A measured burn beside the evidence behind it, so a surface can say how much to trust it.
    struct Estimate: Equatable {
        /// Working time needed to spend one full window.
        let burn: TimeInterval
        /// How much of a window was actually watched being spent, 0…1. Below
        /// `minimumObservedFraction` there is no estimate at all, so this is never small.
        let observedFraction: Double
        /// How long the account was observed moving.
        let activeTime: TimeInterval
    }

    /// Estimates from a window's sample history, or nil when the history cannot support one.
    ///
    /// Nil is a real answer and the page prints it as one. An account watched for twenty minutes
    /// has no burn, and inventing one would put a confident wrong lead on the screen — which is
    /// worse than an assumed lead labelled as assumed, because nobody checks a number that looks
    /// measured.
    static func estimate(
        from samples: [UsageSample],
        windowLength: TimeInterval
    ) -> Estimate? {
        guard windowLength > 0 else { return nil }

        var activeTime: TimeInterval = 0
        var burned: Double = 0

        for (previous, sample) in zip(samples, samples.dropFirst()) {
            let elapsed = sample.at.timeIntervalSince(previous.at)
            guard elapsed > 0, elapsed <= UsageWindowBurnDefaults.maximumGap else { continue }

            // A reset separates two windows, and the pair straddling it describes neither: the
            // fraction falls, or the reported reset moves on. Either is a boundary, not a rate.
            if let old = previous.resetsAt, let new = sample.resetsAt, new > old { continue }

            let growth = sample.fraction - previous.fraction
            guard growth >= UsageHistoryDefaults.minimumChange else { continue }

            activeTime += elapsed
            burned += growth
        }

        guard burned >= UsageWindowBurnDefaults.minimumObservedFraction,
              activeTime >= UsageWindowBurnDefaults.minimumActiveTime
        else { return nil }

        // Rate while moving, inverted: seconds of work per whole window.
        let burn = activeTime / burned

        return Estimate(
            burn: min(burn, windowLength * UsageWindowBurnDefaults.maximumBurnMultiple),
            observedFraction: min(burned, 1),
            activeTime: activeTime
        )
    }
}

// MARK: - Usage Window Burn Defaults

enum UsageWindowBurnDefaults {
    /// A gap longer than this is the app having been closed, not a slow hour. Counting it as
    /// active time would inflate the burn and make the lead too short — the failure that ends a
    /// morning capped at 11am, which is the thing this feature exists to prevent.
    static let maximumGap: TimeInterval = 30 * 60

    /// How much of a window must have been watched being spent before a rate means anything. A
    /// fifth: enough that a single burst does not set the estimate, small enough that a first
    /// morning produces one.
    static let minimumObservedFraction = 0.2

    /// And for how long, so a burst of ten minutes cannot claim a day's rate.
    static let minimumActiveTime: TimeInterval = 20 * 60

    /// A burn beyond this is reported as "does not exhaust" rather than as a very long number:
    /// past one window's length the planner refuses anyway, and the cap keeps a near-zero rate
    /// from producing a nonsense interval.
    static let maximumBurnMultiple = 2.0
}
