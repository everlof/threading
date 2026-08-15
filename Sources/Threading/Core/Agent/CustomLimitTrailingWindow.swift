import Foundation

// MARK: - Custom Limit Trailing Window

/// The arithmetic behind a **synthetic window**: how much of a provider window was consumed inside
/// the last *L* hours.
///
/// This is what lets a user recreate pacing discipline a provider took away — "no more than 15% of
/// the weekly in any 5 hours" — on a plan that meters only a week. It is funded by **fraction
/// delta**: the consumption in the last L is `fraction(now) − fraction(now − L)` of a window the
/// provider still reports, read from the history the app already keeps. The unit stays the
/// provider's own normalized metric, so nothing here is estimated and nothing needs labelling as
/// an estimate.
///
/// **Trailing rather than anchored.** An anchored recreation — first message opens the window, the
/// old Claude shape — is the nostalgic fit, but trailing is simpler, strictly stronger (it admits
/// no burst that an anchor's boundary would have let through) and needs no phase state at all. The
/// draft asked whether anchoring is worth adding once this ships; it is not, and the reason is
/// that "strictly stronger" leaves nothing for the phase state to buy.
enum CustomLimitTrailingWindow {

    /// Consumption inside the trailing span, as a fraction of the provider window.
    ///
    /// Nil when the history cannot answer — which is a **hold** and not an alert, per the
    /// asymmetry the whole feature turns on. Two ways it cannot answer:
    ///
    /// - nothing has been sampled at all; or
    /// - the oldest sample is younger than `now − span`, so the span reaches back further than
    ///   anything observed. Reading the oldest sample as the start anyway would answer a
    ///   five-hour question with two hours of evidence and call the missing three hours zero.
    static func consumption(
        in samples: [UsageSample],
        span: TimeInterval,
        at now: Date
    ) -> Double? {
        guard span > 0 else { return nil }

        let ordered = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
        guard let latest = ordered.last else { return nil }

        let start = now.addingTimeInterval(-span)

        // A reset inside the span ends the subtraction at the reset evidence. Before it, the
        // window was a *different instance*, and subtracting across the boundary would read a
        // clear as negative consumption — which would then read as headroom, on the one metric
        // whose whole purpose is to notice a burst.
        if let reset = lastReset(in: ordered, after: start) {
            return max(0, latest.fraction - reset.fraction)
        }

        // The last sample **at or before** the boundary, not the first one inside it. History is
        // sparse, so the true value at the boundary is unknown and the two candidates bracket it;
        // starting earlier can only over-count, which holds sooner, while starting later
        // under-counts and lets a burst through. A rule that exists to notice a burst errs toward
        // noticing.
        guard let earliest = ordered.last(where: { $0.at <= start }) else { return nil }
        return max(0, latest.fraction - earliest.fraction)
    }

    /// The first sample *after* the most recent turn-over inside the span, or nil when none is
    /// recorded there.
    ///
    /// A reset is recognised two ways, because the history records both and neither is always
    /// present: the sample's own `resetsAt` moving forward, and — for a provider that reports no
    /// reset at all — the fraction dropping by more than a reading's worth of noise. A drop that
    /// large has exactly one cause.
    private static func lastReset(in ordered: [UsageSample], after start: Date) -> UsageSample? {
        var found: UsageSample?
        for (index, sample) in ordered.enumerated() where sample.at > start {
            guard index > 0 else { continue }
            let previous = ordered[index - 1]

            let resetMoved: Bool
            if let was = previous.resetsAt, let now = sample.resetsAt {
                resetMoved = now > was
            } else {
                resetMoved = false
            }
            let fractionFell = sample.fraction
                < previous.fraction - CustomLimitTrailingWindowDefaults.resetDrop

            if resetMoved || fractionFell { found = sample }
        }
        return found
    }
}

// MARK: - Custom Limit Trailing Window Defaults

enum CustomLimitTrailingWindowDefaults {

    /// How far a fraction must fall between two samples to be a reset rather than noise.
    ///
    /// `UsageHistoryStore` only records a sample when the fraction moves by half a percentage
    /// point or fifteen minutes pass, so consumption never *falls* at all in the ordinary case —
    /// any drop is a turn-over. Five points of slack is for a provider that recomputes its own
    /// number slightly downward, which has been observed and is not a reset.
    static let resetDrop = 0.05
}
