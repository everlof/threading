import Foundation

// MARK: - Usage Sample

/// One reading of one window, at a moment.
struct UsageSample: Codable, Equatable {
    let at: Date
    /// Fraction of the window consumed, 0…1.
    let fraction: Double
    /// The window's own reset, which is what makes a sample belong to a *particular* window
    /// rather than to a name that repeats every period.
    let resetsAt: Date?
}

// MARK: - Usage Forecast

/// Projects when a rate-limit window will be spent, from readings taken as it fills.
///
/// The pill answers "how much is left"; this answers "will it last". Those differ whenever the
/// burn is uneven, which is always: an afternoon of heavy agent work can spend a week's window
/// that looked comfortable at lunchtime, and the number that says so is a *rate*, not a level.
enum UsageForecast {

    // MARK: - Outcome

    enum Outcome: Equatable {
        /// Not enough readings, or not enough time between them, to claim a rate.
        case unknown

        /// The window is filling, but slowly enough to outlast its own reset.
        case withinBudget(spare: TimeInterval)

        /// At this rate the window is spent before it resets.
        case exhausting(at: Date, early: TimeInterval)
    }

    // MARK: - Public Methods

    /// Projects from `samples`, which need not be sorted or confined to one window.
    ///
    /// Everything before the most recent reset is discarded first. A window that resets drops
    /// from nearly full to nearly empty, and a rate fitted across that boundary is not slow —
    /// it is negative, which would read as "never" for a window that is in fact filling fast.
    static func project(
        samples: [UsageSample],
        resetsAt: Date?,
        now: Date = Date()
    ) -> Outcome {
        let current = withinCurrentWindow(samples.sorted { $0.at < $1.at })

        guard let first = current.first, let last = current.last,
              last.at.timeIntervalSince(first.at) >= ForecastDefaults.minimumSpan
        else { return .unknown }

        let elapsed = last.at.timeIntervalSince(first.at)
        let burned = last.fraction - first.fraction

        // Flat or falling means nothing is being spent, so there is nothing to project. Not
        // "never" — the honest answer is that no rate is visible.
        guard burned > ForecastDefaults.minimumBurn else { return .unknown }

        let ratePerSecond = burned / elapsed
        let remaining = max(0, 1 - last.fraction)
        let secondsLeft = remaining / ratePerSecond
        let crossing = last.at.addingTimeInterval(secondsLeft)

        guard let resetsAt else {
            return .exhausting(at: crossing, early: 0)
        }

        // Crossing after the reset means the window refills before it runs out, which is the
        // ordinary, comfortable case and deserves a different sentence.
        guard crossing < resetsAt else {
            return .withinBudget(spare: crossing.timeIntervalSince(resetsAt))
        }

        return .exhausting(at: crossing, early: resetsAt.timeIntervalSince(crossing))
    }

    // MARK: - Private Methods

    /// The tail of the series belonging to the window in progress.
    ///
    /// A reset shows up two ways and both are handled: the reported `resetsAt` moving on, and —
    /// for readings that carry no reset — the fraction simply dropping, which nothing but a
    /// reset can cause within one window.
    private static func withinCurrentWindow(_ sorted: [UsageSample]) -> [UsageSample] {
        var start = sorted.startIndex

        for index in sorted.indices.dropFirst() {
            let previous = sorted[index - 1]
            let sample = sorted[index]

            let resetMoved = zip([previous.resetsAt], [sample.resetsAt])
                .allSatisfy { old, new in
                    guard let old, let new else { return false }
                    return new > old
                }

            if resetMoved || sample.fraction < previous.fraction - ForecastDefaults.dropTolerance {
                start = index
            }
        }

        return Array(sorted[start...])
    }
}

// MARK: - Forecast Defaults

enum ForecastDefaults {
    /// Below this span, two readings say more about jitter than about a rate.
    static let minimumSpan: TimeInterval = 10 * 60

    /// Growth smaller than this is noise — the reported percentage is an integer for Claude,
    /// so a single point of movement is the smallest real signal there is.
    static let minimumBurn = 0.005

    /// A fall larger than this is a reset rather than a correction.
    static let dropTolerance = 0.02
}
