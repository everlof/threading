import Foundation

/// One observed reading of a metered window, as the chart form needs it: when, and how full.
public struct UsageLimitChartObservation: Equatable, Sendable {
    public let at: Double
    public let fraction: Double

    public init(at: Double, fraction: Double) {
        self.at = at
        self.fraction = fraction
    }
}

/// How one window's history is drawn, decided by how many of that window fit in the range.
///
/// A weekly window over ninety days is a dozen slow climbs and a line shows every one. A
/// five-hour window over thirty days is a hundred and forty-four, and the same line became a
/// picket fence: forty-eight dashed reset rules through a block of near-vertical strokes, two
/// points to a cycle, with nothing a reader could take from it. Past `maximumLineCycles` the
/// chart draws one column per bucket instead — the highest reading observed in it, which is the
/// question a dense window is actually asked: how close to the limit did each stretch get. The
/// bucket is the window itself while that stays under `maximumBuckets` columns, then whole days,
/// then three-day spans; a day-sized bucket starts on the calendar day so the axis label under a
/// column names the day the column measures.
///
/// Shared by the Mac's chart and the phone's, which receive the same downsampled observations
/// and must answer the same way about them; it lives here, beside `UsageValueFormat`, for the
/// same reason that does.
public enum UsageLimitChartForm: Equatable, Sendable {
    case line
    case peaks(bucket: TimeInterval)

    public struct Peak: Equatable, Sendable, Identifiable {
        public let start: Double
        public let end: Double
        public let fraction: Double
        public let observations: Int

        public var id: Double { start }
        public var reachedLimit: Bool { fraction >= UsageLimitChartForm.limitReachedFraction }

        public init(start: Double, end: Double, fraction: Double, observations: Int) {
            self.start = start
            self.end = end
            self.fraction = fraction
            self.observations = observations
        }
    }

    public static let maximumLineCycles = 16.0
    public static let maximumBuckets = 48
    /// A reading this close to the ceiling is the limit: providers report a refused window as
    /// a rounded 100%, and a sample taken just before it is the same event.
    public static let limitReachedFraction = 0.995
    public static let dayBucket: TimeInterval = 86_400
    public static let bucketLadder: [TimeInterval] = [dayBucket, 3 * dayBucket, 7 * dayBucket]

    /// The form for a range `span` seconds long, given the window's stated length or, when the
    /// provider stated none, the number of cycles the observations themselves showed.
    public static func resolve(
        span: TimeInterval,
        windowDuration: TimeInterval?,
        observedCycles: Int
    ) -> UsageLimitChartForm {
        guard span > 0, span.isFinite else { return .line }
        let windowDuration = windowDuration.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        let cycles = windowDuration.map { span / $0 } ?? Double(max(1, observedCycles))
        guard cycles > maximumLineCycles else { return .line }
        let candidates = [windowDuration].compactMap { $0 } + bucketLadder
        let bucket = candidates.first { span / $0 <= Double(maximumBuckets) }
            ?? bucketLadder[bucketLadder.count - 1]
        return .peaks(bucket: bucket)
    }

    /// The days a bucket spans, for the words that name a column; nil for a bucket shorter than
    /// a day, which is the window itself.
    public static func bucketDays(_ bucket: TimeInterval) -> Int? {
        guard bucket >= dayBucket else { return nil }
        return Int((bucket / dayBucket).rounded())
    }

    /// The highest reading in each bucket between `start` and `end`. Observations outside the
    /// range are not counted; buckets no observation fell in are not returned.
    public static func peaks(
        _ observations: [UsageLimitChartObservation],
        start: Double,
        end: Double,
        bucket: TimeInterval,
        calendar: Calendar = .current
    ) -> [Peak] {
        guard bucket > 0, bucket.isFinite, end >= start else { return [] }
        let origin = bucket >= dayBucket
            ? calendar.startOfDay(for: Date(timeIntervalSince1970: start)).timeIntervalSince1970
            : start
        var highest: [Int: Double] = [:]
        var counts: [Int: Int] = [:]
        for observation in observations where observation.at >= start && observation.at <= end {
            let index = Int(((observation.at - origin) / bucket).rounded(.down))
            highest[index] = max(highest[index] ?? 0, observation.fraction)
            counts[index, default: 0] += 1
        }
        return highest.keys.sorted().map { index in
            let bucketStart = origin + Double(index) * bucket
            return Peak(
                start: bucketStart,
                end: bucketStart + bucket,
                fraction: min(max(highest[index] ?? 0, 0), 1),
                observations: counts[index] ?? 0
            )
        }
    }
}
