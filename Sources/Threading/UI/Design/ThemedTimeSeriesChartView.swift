import AppKit

// MARK: - Model

/// Data-only chart contracts. Colour is semantic rather than an `NSColor`, so a live theme
/// switch can repaint a retained chart and a provider never smuggles fixed chrome into it.
struct ThemedChartPoint: Equatable, Sendable {
    let at: Date
    let value: Double
    let label: String?
    let detail: String?
    let segment: Int

    init(
        at: Date,
        value: Double,
        label: String? = nil,
        detail: String? = nil,
        segment: Int = 0
    ) {
        self.at = at
        self.value = value
        self.label = label
        self.detail = detail
        self.segment = segment
    }
}

enum ThemedChartSeriesStyle: Equatable, Sendable {
    case primary
    case positive
    case warning
    case negative
    case categorical(Int)
    case projection
}

/// The line grammar is explicit data, so a forecast can stay geometrically honest while an
/// observed daily series uses the softer interpolation expected of a modern dashboard.
enum ThemedChartCurve: Equatable, Sendable {
    case smooth
    case linear
}

/// Independent series keep their own height above zero. Stacked bands instead accumulate aligned,
/// non-negative values so each band's thickness is its contribution and the final upper edge is
/// the total. The separate stacked chart view selects the latter; existing callers keep the former.
enum ThemedChartComposition: Equatable, Sendable {
    case independent
    case stackedBands
}

/// The mark a series draws.
///
/// A bar is not a second chart: it occupies the same normalized space a line already does,
/// from `baselineY` to `y`. That is why grouped and stacked bars need no geometry of their
/// own — `.independent` puts every bar's foot on zero, `.stackedBands` puts it on the running
/// total, and both were already computed for the curve grammar.
enum ThemedChartMark: Equatable, Sendable {
    case line
    case bar
}

/// How the x domain is *named*.
///
/// Geometry normalizes a `Date` and nothing else. A categorical axis carries its ordinal in
/// that same slot — category *i* is second *i* — and this enum supplies the words. Encoding
/// the ordinal as a time keeps one downsampler, one stacking rule and one interpolator for
/// both domains; a parallel scale type would have duplicated all three and let them drift.
enum ThemedChartXAxis: Equatable, Sendable {
    case time
    case categories([String])

    var categories: [String]? {
        if case .categories(let names) = self { return names }
        return nil
    }
}

/// Which way the value axis runs. Horizontal is for ranking, where the category names read
/// down the leading edge and have room to be words rather than truncated stubs. It applies to
/// bars only: a line's x is time, and time does not read down a page.
enum ThemedChartOrientation: Equatable, Sendable {
    case vertical
    case horizontal
}

struct ThemedChartSeries: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let points: [ThemedChartPoint]
    let style: ThemedChartSeriesStyle
    let fillsArea: Bool
    let curve: ThemedChartCurve
    let mark: ThemedChartMark

    init(
        id: String,
        title: String,
        points: [ThemedChartPoint],
        style: ThemedChartSeriesStyle = .primary,
        fillsArea: Bool = false,
        curve: ThemedChartCurve = .smooth,
        mark: ThemedChartMark = .line
    ) {
        self.id = id
        self.title = title
        self.points = points
        self.style = style
        self.fillsArea = fillsArea
        self.curve = curve
        self.mark = mark
    }

    /// A bar series over category positions: value *i* belongs to category *i*.
    ///
    /// The category name becomes the point's label, which is what the tooltip and the
    /// accessibility description already read — so a bar announces "Cold start, 42 ms" without
    /// either surface learning that categories exist.
    init(
        id: String,
        title: String,
        values: [Double],
        categories: [String] = [],
        details: [String] = [],
        style: ThemedChartSeriesStyle = .primary
    ) {
        self.init(
            id: id,
            title: title,
            points: values.enumerated().map { index, value in
                ThemedChartPoint(
                    at: ThemedChartModel.categoryPosition(index),
                    value: value,
                    label: index < categories.count ? categories[index] : nil,
                    detail: index < details.count ? details[index] : nil
                )
            },
            style: style,
            mark: .bar
        )
    }
}

enum ThemedChartMarkerKind: Equatable, Sendable {
    case reset
    case expiry
    case projection
    case now
}

struct ThemedChartMarker: Equatable, Sendable, Identifiable {
    let id: String
    let at: Date
    let title: String
    let detail: String?
    let kind: ThemedChartMarkerKind
}

// MARK: - Value Rule

/// A line across the plot at one **value**, rather than at one moment.
///
/// `ThemedChartMarker` is anchored to a `Date` and draws vertically, which is right for the three
/// things it already marks — a reset, an expiry, a projected exhaustion all happen *at a time*. A
/// limit the user drew is not an event: it is a level the series is read against, and it is
/// horizontal for the same reason a pace mark is vertical. Making it a marker kind would have
/// given the enum one case whose geometry contradicted the other four.
struct ThemedChartValueRule: Equatable, Sendable, Identifiable {

    enum Kind: Equatable, Sendable {
        /// A line the reader set themselves — drawn in the warning role, since crossing it is a
        /// thing they asked to be told about rather than a thing the chart is reporting.
        case cap
    }

    let id: String

    /// Where the line sits, in the series' own units.
    let value: Double

    /// What the line is called, drawn at its leading end. Kept short: it shares the plot with the
    /// series it is measuring.
    let title: String

    let kind: Kind
}

enum ThemedChartValueFormat: Equatable, Sendable {
    case percent
    case currency
    case tokens
    case number
    /// A number with the caller's own suffix — `ms`, `MB`, `req/s`. The unit belongs on the
    /// ticks and the bar labels rather than in the title, where it has to be carried by the
    /// reader from one end of the chart to the other.
    case unit(String)
}

struct ThemedChartModel: Equatable, Sendable {
    let title: String
    let accessibilitySummary: String
    let series: [ThemedChartSeries]
    let markers: [ThemedChartMarker]

    /// Horizontal lines at named values — see `ThemedChartValueRule`.
    let valueRules: [ThemedChartValueRule]

    let xRange: ClosedRange<Date>?
    let yRange: ClosedRange<Double>?
    let valueFormat: ThemedChartValueFormat
    let emptyMessage: String
    /// The second line under `emptyMessage`: what would put marks here, or what is being read
    /// right now. A chart that says only "no data" has told the reader nothing they could act on.
    let emptyDetail: String?
    /// Whether the absence is final or still being resolved. See `ThemedChartPlaceholder`.
    let placeholder: ThemedChartPlaceholder
    let xAxis: ThemedChartXAxis
    let orientation: ThemedChartOrientation
    let showsLegend: Bool
    /// How many rules the value axis draws, when this chart wants fewer than the shared default.
    ///
    /// The default (`Design.Chart.gridLineCount`) is right for a chart read for a *value*: five
    /// rules put a labelled step close enough to any point to read it off the axis. A chart read
    /// for its *shape* — the Usage overview's daily bands, where the totals are already stated
    /// beside it in words — wants the opposite, and four rules through a stack of filled bands
    /// is the loudest thing on that page.
    ///
    /// Only the rules and their labels thin. The domain still resolves on the shared interval
    /// count, so the numbers stay the round ones `niceAutomaticY` chose: halving or quartering a
    /// scale that ends on 1/2/2.5/5 × 10ⁿ lands on another of them.
    let valueGridLineCount: Int?

    init(
        title: String,
        accessibilitySummary: String,
        series: [ThemedChartSeries],
        markers: [ThemedChartMarker] = [],
        valueRules: [ThemedChartValueRule] = [],
        xRange: ClosedRange<Date>? = nil,
        yRange: ClosedRange<Double>? = nil,
        valueFormat: ThemedChartValueFormat = .number,
        valueGridLineCount: Int? = nil,
        emptyMessage: String = L10n.string("No data in this range"),
        emptyDetail: String? = nil,
        placeholder: ThemedChartPlaceholder = .empty,
        xAxis: ThemedChartXAxis = .time,
        orientation: ThemedChartOrientation = .vertical,
        showsLegend: Bool = false
    ) {
        self.xAxis = xAxis
        self.orientation = orientation
        self.showsLegend = showsLegend
        self.valueGridLineCount = valueGridLineCount
        self.title = title
        self.accessibilitySummary = accessibilitySummary
        self.series = series
        self.markers = markers
        self.valueRules = valueRules
        self.xRange = xRange
        self.yRange = yRange
        self.valueFormat = valueFormat
        self.emptyMessage = emptyMessage
        self.emptyDetail = emptyDetail
        self.placeholder = placeholder
    }

    static let empty = Self(title: "", accessibilitySummary: "", series: [])

    /// Where category *i* sits in the domain geometry normalizes.
    static func categoryPosition(_ index: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(index))
    }

    /// A comparison over named categories.
    ///
    /// The half-step padding is the whole trick: a bar is drawn *around* its position, so a
    /// domain of exactly `0...n-1` would cut the first and last bar in half against the plot
    /// edges. Widening it to `-0.5...n-0.5` makes every band the same width and centres each
    /// bar in its own — a band scale, expressed entirely as the range the existing geometry
    /// already accepts.
    static func categorical(
        title: String,
        accessibilitySummary: String,
        categories: [String],
        series: [ThemedChartSeries],
        orientation: ThemedChartOrientation = .vertical,
        valueFormat: ThemedChartValueFormat = .number,
        yRange: ClosedRange<Double>? = nil,
        showsLegend: Bool? = nil,
        emptyMessage: String = L10n.string("No data to compare"),
        emptyDetail: String? = nil,
        placeholder: ThemedChartPlaceholder = .empty
    ) -> Self {
        let count = max(categories.count, 1)
        let first = categoryPosition(0).addingTimeInterval(-0.5)
        let last = categoryPosition(count - 1).addingTimeInterval(0.5)
        return Self(
            title: title,
            accessibilitySummary: accessibilitySummary,
            series: series,
            xRange: first...last,
            yRange: yRange,
            valueFormat: valueFormat,
            emptyMessage: emptyMessage,
            emptyDetail: emptyDetail,
            placeholder: placeholder,
            xAxis: .categories(categories),
            orientation: orientation,
            // One series needs no key: the title already says what the bars are, and a legend
            // repeating it is chrome that earns nothing.
            showsLegend: showsLegend ?? (series.count > 1)
        )
    }
}

// MARK: - Geometry and transition

struct ThemedChartRenderedPoint: Equatable, Sendable {
    let x: Double
    /// Upper edge of the rendered series or band, normalized into the resolved Y domain.
    let y: Double
    /// Lower edge. Zero for independent series; the preceding cumulative total for a band.
    let baselineY: Double
    let sourceIndex: Int
    let segment: Int
}

struct ThemedChartRenderedSeries: Equatable, Sendable {
    let id: String
    let points: [ThemedChartRenderedPoint]
}

@MainActor
enum ThemedChartGeometry {
    struct Layout {
        let series: [ThemedChartRenderedSeries]
        let xRange: ClosedRange<Date>?
        let yRange: ClosedRange<Double>
    }

    private struct IndexedPoint {
        let sourceIndex: Int
        let point: ThemedChartPoint
    }

    static func render(
        _ model: ThemedChartModel,
        composition: ThemedChartComposition = .independent,
        maximumPoints: Int = Design.Chart.maximumRenderedPoints
    ) -> [ThemedChartRenderedSeries] {
        layout(model, composition: composition, maximumPoints: maximumPoints).series
    }

    static func layout(
        _ model: ThemedChartModel,
        composition: ThemedChartComposition = .independent,
        maximumPoints: Int = Design.Chart.maximumRenderedPoints
    ) -> Layout {
        var minimumTime = Double.greatestFiniteMagnitude
        var maximumTime = -Double.greatestFiniteMagnitude
        var maximumValue = 0.0
        var hasPoint = false

        // One pass avoids the three full-size temporary arrays that used to be allocated for
        // every animated item switch. Source models can be large even though retained geometry
        // is bounded below.
        for series in model.series {
            for point in series.points where point.value.isFinite {
                let time = point.at.timeIntervalSinceReferenceDate
                guard time.isFinite else { continue }
                minimumTime = min(minimumTime, time)
                maximumTime = max(maximumTime, time)
                maximumValue = max(maximumValue, point.value)
                hasPoint = true
            }
        }

        let xRange: ClosedRange<Date>?
        let x: ClosedRange<Double>
        if let requested = model.xRange {
            let resolved = nonEmpty(requested)
            xRange = resolved
            let lower = resolved.lowerBound.timeIntervalSinceReferenceDate
            let upper = resolved.upperBound.timeIntervalSinceReferenceDate
            x = lower...upper
        } else if hasPoint {
            let resolved = nonEmpty(minimumTime...maximumTime)
            let lower = Date(timeIntervalSinceReferenceDate: resolved.lowerBound)
            let upper = Date(timeIntervalSinceReferenceDate: resolved.upperBound)
            xRange = lower...upper
            x = resolved
        } else {
            xRange = nil
            x = 0...1
        }

        let stacked = composition == .stackedBands ? stackedInput(model.series) : nil
        if let stacked {
            maximumValue = stacked.totals.reduce(0) { max($0, $1.value) }
        }

        let automaticY = niceAutomaticY(maximumValue: maximumValue)
        let y = nonEmpty(model.yRange ?? automaticY)
        guard hasPoint else { return Layout(series: [], xRange: xRange, yRange: y) }

        if let stacked {
            let boundedTotals = downsampleIndexed(
                stacked.totals,
                maximumCount: maximumPoints
            )
            var cumulative = Array(repeating: 0.0, count: boundedTotals.count)
            let rendered = model.series.map { series in
                let points = boundedTotals.enumerated().map { position, total in
                    let point = series.points[total.sourceIndex]
                    let value = point.value.isFinite ? max(0, point.value) : 0
                    let lower = cumulative[position]
                    let upper = lower + value
                    cumulative[position] = upper
                    return ThemedChartRenderedPoint(
                        x: normalized(point.at.timeIntervalSinceReferenceDate, in: x),
                        y: normalized(upper, in: y),
                        baselineY: normalized(lower, in: y),
                        sourceIndex: total.sourceIndex,
                        segment: point.segment
                    )
                }
                return ThemedChartRenderedSeries(id: series.id, points: points)
            }
            return Layout(series: rendered, xRange: xRange, yRange: y)
        }

        let rendered = model.series.map { series in
            let bounded = downsampleIndexed(series.points, maximumCount: maximumPoints)
            let points = bounded.map { value in
                ThemedChartRenderedPoint(
                    x: normalized(value.point.at.timeIntervalSinceReferenceDate, in: x),
                    y: normalized(value.point.value, in: y),
                    baselineY: normalized(0, in: y),
                    sourceIndex: value.sourceIndex,
                    segment: value.point.segment
                )
            }
            return ThemedChartRenderedSeries(id: series.id, points: points)
        }
        return Layout(series: rendered, xRange: xRange, yRange: y)
    }

    static func interpolate(
        from: [ThemedChartRenderedSeries],
        to: [ThemedChartRenderedSeries],
        composition: ThemedChartComposition = .independent,
        progress: Double
    ) -> [ThemedChartRenderedSeries] {
        let phase = min(max(progress, 0), 1)
        return to.enumerated().map { index, target in
            let source = from.first(where: { $0.id == target.id })
                ?? (composition == .independent && from.indices.contains(index) ? from[index] : nil)
            let sourcePoints = source.map {
                resample($0.points, count: target.points.count)
            } ?? target.points.map {
                ThemedChartRenderedPoint(
                    x: $0.x,
                    y: $0.baselineY,
                    baselineY: $0.baselineY,
                    sourceIndex: $0.sourceIndex,
                    segment: $0.segment
                )
            }

            let points = zip(sourcePoints, target.points).map { old, new in
                ThemedChartRenderedPoint(
                    x: old.x + (new.x - old.x) * phase,
                    y: old.y + (new.y - old.y) * phase,
                    baselineY: old.baselineY + (new.baselineY - old.baselineY) * phase,
                    sourceIndex: new.sourceIndex,
                    segment: new.segment
                )
            }
            return ThemedChartRenderedSeries(id: target.id, points: points)
        }
    }

    static func downsample(
        _ points: [ThemedChartPoint],
        maximumCount: Int
    ) -> [ThemedChartPoint] {
        downsampleIndexed(points, maximumCount: maximumCount).map(\.point)
    }

    static func downsample(
        _ markers: [ThemedChartMarker],
        maximumCount: Int = Design.Chart.maximumRenderedMarkers
    ) -> [ThemedChartMarker] {
        guard maximumCount > 0, markers.count > maximumCount else { return markers }
        guard maximumCount > 1 else { return [markers[markers.count / 2]] }

        let ordered = markers.sorted { $0.at < $1.at }
        let last = ordered.count - 1
        return (0..<maximumCount).map { position in
            let index = Int(
                (Double(position) * Double(last) / Double(maximumCount - 1)).rounded()
            )
            return ordered[index]
        }
    }

    private static func downsampleIndexed(
        _ points: [ThemedChartPoint],
        maximumCount: Int
    ) -> [IndexedPoint] {
        var order: [Int] = []
        order.reserveCapacity(points.count)
        var isOrdered = true
        var previousDate: Date?
        for index in points.indices {
            let point = points[index]
            guard point.value.isFinite,
                  point.at.timeIntervalSinceReferenceDate.isFinite else { continue }
            if let previousDate, point.at < previousDate { isOrdered = false }
            previousDate = point.at
            order.append(index)
        }
        if !isOrdered {
            order.sort { points[$0].at < points[$1].at }
        }
        guard maximumCount >= 6, order.count > maximumCount else {
            return order.map { IndexedPoint(sourceIndex: $0, point: points[$0]) }
        }

        var kept = Set([0, order.count - 1])
        var discontinuities: [(before: Int, after: Int)] = []
        for index in 1..<order.count
            where points[order[index]].segment != points[order[index - 1]].segment {
            discontinuities.append((index - 1, index))
        }

        // A hostile or corrupt source can assign a new segment to every point. Preserve complete,
        // evenly-spaced boundary pairs rather than allowing the boundaries alone to violate the
        // chart's hard geometry budget.
        let maximumBoundaryPairs = max(1, (maximumCount - kept.count) / 2)
        for pair in evenlySpaced(discontinuities, maximumCount: maximumBoundaryPairs) {
            kept.insert(pair.before)
            kept.insert(pair.after)
        }

        let room = max(0, maximumCount - kept.count)
        let bucketCount = max(1, room / 4)
        let bucketSize = max(1, Int(ceil(Double(order.count - 2) / Double(bucketCount))))
        var lower = 1
        while lower < order.count - 1, kept.count < maximumCount {
            let upper = min(order.count - 1, lower + bucketSize)
            let range = lower..<upper
            let minimum = range.min {
                points[order[$0]].value < points[order[$1]].value
            } ?? lower
            let maximum = range.max {
                points[order[$0]].value < points[order[$1]].value
            } ?? lower
            for index in [lower, minimum, maximum, upper - 1] where kept.count < maximumCount {
                kept.insert(index)
            }
            lower = upper
        }
        return kept.sorted().map { position in
            let sourceIndex = order[position]
            return IndexedPoint(sourceIndex: sourceIndex, point: points[sourceIndex])
        }
    }

    private static func evenlySpaced<Element>(
        _ values: [Element],
        maximumCount: Int
    ) -> [Element] {
        guard maximumCount > 0, values.count > maximumCount else { return values }
        guard maximumCount > 1 else { return [values[values.count / 2]] }

        let last = values.count - 1
        return (0..<maximumCount).map { position in
            let index = Int(
                (Double(position) * Double(last) / Double(maximumCount - 1)).rounded()
            )
            return values[index]
        }
    }

    private static func resample(
        _ points: [ThemedChartRenderedPoint],
        count: Int
    ) -> [ThemedChartRenderedPoint] {
        guard count > 0 else { return [] }
        guard !points.isEmpty else { return [] }
        guard points.count != count else { return points }
        guard count > 1, points.count > 1 else {
            return Array(repeating: points[0], count: count)
        }

        return (0..<count).map { index in
            let position = Double(index) * Double(points.count - 1) / Double(count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(points.count - 1, lower + 1)
            let phase = position - Double(lower)
            let a = points[lower]
            let b = points[upper]
            return ThemedChartRenderedPoint(
                x: a.x + (b.x - a.x) * phase,
                y: a.y + (b.y - a.y) * phase,
                baselineY: a.baselineY + (b.baselineY - a.baselineY) * phase,
                sourceIndex: b.sourceIndex,
                segment: b.segment
            )
        }
    }

    private static func normalized(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    private struct StackedInput {
        let totals: [ThemedChartPoint]
    }

    /// Stacked geometry deliberately requires aligned timestamps. Missing values are explicit
    /// zeroes, which keeps the band boundary and its tooltip source index describing the same day.
    /// A malformed generic caller degrades to independent rendering rather than inventing a sum.
    private static func stackedInput(_ series: [ThemedChartSeries]) -> StackedInput? {
        guard let reference = series.first, !reference.points.isEmpty else { return nil }
        guard series.allSatisfy({ $0.points.count == reference.points.count }) else { return nil }

        var totals: [ThemedChartPoint] = []
        totals.reserveCapacity(reference.points.count)
        for index in reference.points.indices {
            let anchor = reference.points[index]
            let timestamp = anchor.at.timeIntervalSinceReferenceDate
            guard timestamp.isFinite else { return nil }
            var total = 0.0
            for candidate in series {
                let point = candidate.points[index]
                guard point.at == anchor.at, point.segment == anchor.segment else { return nil }
                if point.value.isFinite { total += max(0, point.value) }
            }
            totals.append(ThemedChartPoint(
                at: anchor.at,
                value: total,
                segment: anchor.segment
            ))
        }
        return StackedInput(totals: totals)
    }

    private static func nonEmpty(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        guard range.upperBound > range.lowerBound else {
            return range.lowerBound...(range.lowerBound + 1)
        }
        return range
    }

    /// Choose an upper bound whose four grid intervals land on readable values. Padding an
    /// arbitrary maximum by a percentage produced labels such as `184,453.3`; a chart scale is
    /// navigation, so it should use the familiar 1/2/2.5/5 progression and keep the raw value
    /// only in the tooltip.
    private static func niceAutomaticY(maximumValue: Double) -> ClosedRange<Double> {
        let padded = max(maximumValue * 1.08, 1)
        let intervalCount = Double(max(Design.Chart.gridLineCount - 1, 1))
        let rawStep = padded / intervalCount
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let multiplier = [1.0, 2.0, 2.5, 5.0, 10.0]
            .first(where: { $0 >= normalized }) ?? 10
        return 0...(multiplier * magnitude * intervalCount)
    }

    private static func nonEmpty(_ range: ClosedRange<Date>) -> ClosedRange<Date> {
        guard range.upperBound > range.lowerBound else {
            return range.lowerBound...range.lowerBound.addingTimeInterval(1)
        }
        return range
    }
}

// MARK: - View

/// A retained, bounded time-series chart shared by every chrome. A model switch morphs from the
/// pixels currently on screen, including when another switch interrupts it; Reduce Motion lands
/// synchronously. Axes, marker glyphs, focus and hover are drawn from semantic design roles.
class ThemedTimeSeriesChartView: ThemedControl {
    private(set) var model: ThemedChartModel = .empty
    private(set) var composition: ThemedChartComposition
    private(set) var animationProgress: Double = 1
    private(set) var renderedPointCount = 0
    private(set) var renderedMarkerCount = 0
    var displayedGeometryForTesting: [ThemedChartRenderedSeries] { displayedGeometry }
    var resolvedYRangeForTesting: ClosedRange<Double> { resolvedYRange }
    /// The marks' own rectangle, so a test can point at a band rather than restate the gutter
    /// widths this view derives from the model's orientation.
    var plotRectForTesting: NSRect { plotRect }

    private var transitionFrom: [ThemedChartRenderedSeries] = []
    private var targetGeometry: [ThemedChartRenderedSeries] = []
    private var displayedGeometry: [ThemedChartRenderedSeries] = []
    private var animationStart: CFTimeInterval = 0
    private var animationDuration: TimeInterval = 0
    private var resolvedXRange: ClosedRange<Date>?
    private var resolvedYRange: ClosedRange<Double> = 0...1
    private var renderedMarkers: [ThemedChartMarker] = []
    private var displayLink: Any?
    private var fallbackTimer: Timer?
    private var movementTrackingArea: NSTrackingArea?
    private var selected: (series: Int, point: Int)?

    /// Built the first time a chart is actually empty. A chart with data never constructs this
    /// subtree, which is most of them and all of the ones inside a conversation timeline.
    private var placeholderView: ThemedChartPlaceholderView?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Design.Chart.preferredHeight)
    }

    override init(frame frameRect: NSRect) {
        composition = .independent
        super.init(frame: frameRect)
        configureAccessibility()
    }

    fileprivate init(frame frameRect: NSRect, composition: ThemedChartComposition) {
        self.composition = composition
        super.init(frame: frameRect)
        configureAccessibility()
    }

    private func configureAccessibility() {
        setAccessibilityLabel(L10n.string("Usage chart"))
        setAccessibilityHelp(L10n.string("Use Left and Right Arrow to inspect points."))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setModel(_ newModel: ThemedChartModel, animated: Bool) {
        let current = displayedGeometry
        let layout = ThemedChartGeometry.layout(newModel, composition: composition)
        let target = layout.series
        model = newModel
        resolvedXRange = layout.xRange
        resolvedYRange = layout.yRange
        let visibleMarkers = layout.xRange.map { range in
            newModel.markers.filter { range.contains($0.at) }
        } ?? newModel.markers
        renderedMarkers = ThemedChartGeometry.downsample(visibleMarkers)
        renderedMarkerCount = renderedMarkers.count
        targetGeometry = target
        renderedPointCount = target.reduce(0) { $0 + $1.points.count }
        selected = nil
        stopDriver()
        updatePlaceholder()

        let duration = Design.Motion.standard
        guard animated, duration > 0, window != nil, !target.isEmpty, current != target else {
            transitionFrom = target
            displayedGeometry = target
            animationProgress = 1
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
            return
        }

        transitionFrom = current
        animationStart = CACurrentMediaTime()
        animationDuration = duration
        animationProgress = 0
        displayedGeometry = ThemedChartGeometry.interpolate(
            from: current,
            to: target,
            composition: composition,
            progress: 0
        )
        startDriver()
        needsDisplay = true
    }

    // MARK: - Placeholder

    /// Whether the chart has anything to plot. A series present but empty is still nothing to
    /// read, which is the state a range change with no records lands in.
    var showsPlaceholder: Bool {
        !model.series.contains(where: { !$0.points.isEmpty })
    }

    /// The status block, once one has been needed. Tests read it; production only ever sees it
    /// through the view tree.
    var placeholderViewForTesting: ThemedChartPlaceholderView? { placeholderView }

    private func updatePlaceholder() {
        guard showsPlaceholder else {
            placeholderView?.isHidden = true
            return
        }
        let view = placeholderView ?? {
            let created = ThemedChartPlaceholderView()
            addSubview(created)
            placeholderView = created
            return created
        }()
        view.isHidden = false
        view.show(model.placeholder, title: model.emptyMessage, detail: model.emptyDetail)
        // Placed now as well as at the next layout pass: a caller that renders a chart without
        // ever laying it out — an offscreen `cacheDisplay`, a fixture — would otherwise draw the
        // status into a zero rectangle and produce the blank picture this replaced.
        view.frame = plotRect
        needsLayout = true
    }

    /// The block sits over the plot rectangle rather than the whole control, so the message lands
    /// where the marks would be and the axes keep their gutters.
    override func layout() {
        super.layout()
        guard let placeholderView, !placeholderView.isHidden else { return }
        placeholderView.frame = plotRect
    }

    /// The plot rectangle is derived from the control's own size, and a frame-positioned subview
    /// is not moved by the constraint system when that size changes. A chart in a split pane is
    /// resized constantly, so the pass is asked for here rather than hoped for.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if placeholderView != nil { needsLayout = true }
    }

    /// Split from the display link so interruption, Reduce Motion, and performance tests can
    /// advance deterministically without sleeping a run loop.
    func advanceAnimation(now: CFTimeInterval) {
        guard animationProgress < 1 else { return }
        let phase = min(max((now - animationStart) / animationDuration, 0), 1)
        let eased = 1 - pow(1 - phase, 3)
        animationProgress = phase
        displayedGeometry = ThemedChartGeometry.interpolate(
            from: transitionFrom,
            to: targetGeometry,
            composition: composition,
            progress: eased
        )
        if phase >= 1 { stopDriver() }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let movementTrackingArea { removeTrackingArea(movementTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        movementTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        // A position under an open dropdown is the menu's, not the chart's — see
        // `NSView.uncoveredPointerLocation(in:)`.
        guard let point = uncoveredPointerLocation(in: event) else { return }
        selectNearest(to: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        selected = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selectNearest(to: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): moveSelection(by: -1)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): moveSelection(by: 1)
        default: super.keyDown(with: event)
        }
    }

    override func performPrimaryAction() -> Bool {
        guard let lastSeries = model.series.indices.last,
              let lastPoint = model.series[lastSeries].points.indices.last else { return false }
        selected = (lastSeries, lastPoint)
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityTitle() -> String? { model.title }
    override func accessibilityValue() -> Any? {
        guard let selected else { return model.accessibilitySummary }
        return accessibilityDescription(for: selected.series, point: selected.point)
    }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, animationProgress < 1 {
            displayedGeometry = targetGeometry
            animationProgress = 1
            stopDriver()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isSystem = AppThemePalette.current.isSystem
        let isSpectrum = Design.Chart.style == .spectrum
        let shape = ThemedSurface.draw(
            bounds,
            fill: isSpectrum
                ? Design.Surface.field
                : (isSystem ? Design.Surface.ground : Design.Surface.panel),
            border: isSystem && !isSpectrum ? .clear : Design.Surface.border,
            radius: Design.Radius.panel,
            borderWidth: isSystem && !isSpectrum ? 0 : Design.Radius.border,
            bevel: isSpectrum ? .sunken : .automatic
        )
        drawKeyboardFocus(around: shape)

        let plot = plotRect
        guard plot.width > 0, plot.height > 0 else { return }

        // Do not flatten provider-sized source arrays on every animation frame. Geometry is
        // bounded, but the retained model deliberately keeps full source indices for tooltips.
        //
        // A chart with nothing to plot draws no scaffolding at all: the rules describe a domain
        // nobody measured anything in, and the middle one runs straight through the sentence
        // saying so. `ThemedChartPlaceholderView` owns that rectangle instead — its ghost is the
        // structure while work is in flight, and a dotted rule along zero is the structure when
        // the answer is that there is nothing.
        if showsPlaceholder { return }
        drawGrid(in: plot)

        if isSpectrum {
            // A bar stays a bar in every material. The spectrum analyzer is a rendering of a
            // *filled band*, and running a comparison through it would answer a question about
            // three categories with a column of cells.
            let spectrumIndices = displayedGeometry.indices.filter { index in
                model.series.indices.contains(index)
                    && model.series[index].style != .projection
                    && model.series[index].mark != .bar
                    && (composition == .stackedBands || model.series[index].fillsArea)
            }
            drawSpectrum(seriesIndices: spectrumIndices, in: plot)
            for index in displayedGeometry.indices where !spectrumIndices.contains(index) {
                guard model.series.indices.contains(index) else { continue }
                draw(
                    series: model.series[index],
                    geometry: displayedGeometry[index],
                    at: index,
                    in: plot
                )
            }
        } else {
            for (index, geometry) in displayedGeometry.enumerated() {
                guard model.series.indices.contains(index) else { continue }
                draw(series: model.series[index], geometry: geometry, at: index, in: plot)
            }
        }
        drawValueRules(in: plot)
        drawMarkers(in: plot)
        drawLegend()
        if let selected { drawSelection(selected, in: plot) }
    }

    private var plotRect: NSRect {
        // A ranking chart spends its leading gutter on category names rather than on values, and
        // a legend takes its band off the top before anything else is positioned against it.
        let leading = model.orientation == .horizontal
            ? Design.Chart.categoryAxisLeading
            : Design.Chart.axisLeading
        let top = Design.Chart.axisTop + (model.showsLegend ? Design.Chart.legendHeight : 0)
        return NSRect(
            x: bounds.minX + leading,
            y: bounds.minY + Design.Chart.axisBottom,
            width: max(0, bounds.width - leading - Design.Chart.axisTrailing),
            height: max(0, bounds.height - Design.Chart.axisBottom - top)
        )
    }

    /// Axis ticks and category names.
    ///
    /// `secondary`, not `tertiary`: measured against a light ground, tertiary label text comes
    /// out at 3.03:1, and an axis is not decoration — it is the only thing that says what the
    /// marks beside it mean. The chart's own numbers are stronger again; see `barValueColor`.
    private var axisTextColor: NSColor {
        Design.Chart.style == .spectrum
            ? Design.Surface.accent.withAlphaComponent(0.62)
            : Design.Text.secondary
    }

    /// A bar's printed value, which is the content of the chart rather than its chrome and is
    /// therefore drawn at full label strength.
    private var barValueColor: NSColor {
        Design.Chart.style == .spectrum ? Design.Surface.accent : Design.Text.label
    }

    /// What the value axis says, which is nothing at all when there is nothing to say it about.
    ///
    /// An empty chart used to print 0/0.2/0.5/0.8/1 beside its rules: that is the automatic domain
    /// describing itself, a scale nobody measured anything in. The rules stay, because they are
    /// the chart's own frame and the ghost stands against them; the numbers go.
    var valueAxisLabels: [String] {
        guard !showsPlaceholder else { return [] }
        return (0..<gridLineCount).map { index in
            valueString(yValue(at: Double(index) / Double(gridLineCount - 1)))
        }
    }

    /// See `ThemedChartModel.valueGridLineCount`. Two is the floor: a value axis has to keep the
    /// rule at each end of the domain, and one rule is a baseline rather than a scale.
    private var gridLineCount: Int {
        max(2, model.valueGridLineCount ?? Design.Chart.gridLineCount)
    }

    private func drawGrid(in plot: NSRect) {
        let grid = NSBezierPath()
        let isRanking = model.orientation == .horizontal
        let labels = valueAxisLabels
        let gridLineCount = gridLineCount
        for index in 0..<gridLineCount {
            let phase = CGFloat(index) / CGFloat(gridLineCount - 1)
            let value = labels.indices.contains(index) ? labels[index] : ""
            if isRanking {
                // The value axis runs along the bottom, so the rules stand up and the numbers
                // sit under them — the same grid, read a quarter turn round.
                let x = plot.minX + phase * plot.width
                grid.move(to: NSPoint(x: x, y: plot.minY))
                grid.line(to: NSPoint(x: x, y: plot.maxY))
                draw(
                    value,
                    at: NSPoint(x: x, y: bounds.minY + Design.Spacing.small),
                    color: axisTextColor,
                    alignment: index == 0
                        ? .left
                        : (index == gridLineCount - 1 ? .right : .center)
                )
            } else {
                let y = plot.minY + phase * plot.height
                grid.move(to: NSPoint(x: plot.minX, y: y))
                grid.line(to: NSPoint(x: plot.maxX, y: y))
                draw(
                    value,
                    at: NSPoint(x: bounds.minX + Design.Spacing.inset, y: y - Design.Spacing.small),
                    color: axisTextColor,
                    alignment: .left
                )
            }
        }
        let gridColor: NSColor
        if Design.Chart.style == .spectrum {
            gridColor = Design.Surface.accent.withAlphaComponent(0.16)
        } else if AppThemePalette.current.isSystem {
            // 0.42 measured 1.88:1 on a light ground — a rule that faint stops being a scale to
            // read a bar against and becomes a smudge behind it.
            gridColor = Design.Surface.divider.withAlphaComponent(0.68)
        } else {
            gridColor = Design.Surface.divider
        }
        gridColor.setStroke()
        grid.lineWidth = Design.Radius.border
        grid.stroke()

        if let categories = model.xAxis.categories {
            drawCategoryLabels(categories, in: plot)
            return
        }

        guard let range = xDomain else { return }
        // As many of the standard labels as the plot can keep apart. A narrow pane squeezed the
        // same four into colliding pairs at each end; two is the floor, because the domain's
        // ends are the axis's whole claim.
        let labelCount = max(2, min(
            Design.Chart.xLabelCount,
            1 + Int(plot.width / Design.Chart.minimumXLabelSpacing)
        ))
        for index in 0..<labelCount {
            let phase = Double(index) / Double(labelCount - 1)
            let date = range.lowerBound.addingTimeInterval(
                range.upperBound.timeIntervalSince(range.lowerBound) * phase
            )
            let x = plot.minX + CGFloat(phase) * plot.width
            draw(
                dateFormatter.string(from: date),
                at: NSPoint(x: x, y: bounds.minY + Design.Spacing.small),
                color: axisTextColor,
                alignment: index == 0 ? .left : (index == labelCount - 1 ? .right : .center)
            )
        }
    }

    /// One label per band, dropped in whole steps when they will not fit.
    ///
    /// Thinning by a stride keeps the labels on the same categories as the chart resizes; picking
    /// "every label that happens to fit" made names appear and disappear under a drag, which reads
    /// as the data changing rather than the window.
    private func drawCategoryLabels(_ categories: [String], in plot: NSRect) {
        guard !categories.isEmpty else { return }
        let band = bandExtent(count: categories.count, in: plot)
        guard band > 0 else { return }

        if model.orientation == .horizontal {
            let stride = max(1, Int(ceil(Design.Chart.minimumCategoryBand / band)))
            for index in Swift.stride(from: 0, to: categories.count, by: stride) {
                let centre = plot.maxY - (CGFloat(index) + 0.5) * band
                draw(
                    categories[index],
                    at: NSPoint(
                        x: bounds.minX + Design.Spacing.inset,
                        y: centre - Design.Spacing.medium
                    ),
                    color: axisTextColor,
                    alignment: .left,
                    width: Design.Chart.categoryAxisLeading - Design.Spacing.inset * 2,
                    font: Design.Typography.detail()
                )
            }
            return
        }

        let stride = max(1, Int(ceil(Design.Chart.minimumCategoryLabelWidth / band)))
        for index in Swift.stride(from: 0, to: categories.count, by: stride) {
            let centre = plot.minX + (CGFloat(index) + 0.5) * band
            draw(
                categories[index],
                at: NSPoint(x: centre, y: bounds.minY + Design.Spacing.small),
                color: axisTextColor,
                alignment: .center,
                width: max(band, Design.Chart.minimumCategoryLabelWidth),
                font: Design.Typography.detail()
            )
        }
    }

    /// The width of one category band along the axis it is laid out on.
    private func bandExtent(count: Int, in plot: NSRect) -> CGFloat {
        guard count > 0 else { return 0 }
        let along = model.orientation == .horizontal ? plot.height : plot.width
        return along / CGFloat(count)
    }

    private func drawLegend() {
        let keys = model.series.filter { !$0.title.isEmpty }
        guard model.showsLegend, !keys.isEmpty else { return }
        let font = Design.Typography.detail()
        let swatch = Design.Chart.legendSwatch
        let titles = keys.map { series in
            NSAttributedString(
                string: series.title,
                attributes: [.font: font, .foregroundColor: Design.Text.secondary]
            )
        }
        let widths = titles.map { swatch + Design.Spacing.small + ceil($0.size().width) }
        let occupied = widths.reduce(0, +)
            + CGFloat(max(0, widths.count - 1)) * Design.Spacing.medium

        // Whole or not at all: half a word beside a colour lies about which series it names,
        // and a legend keeping one key of four lies about how many series there are. Hover and
        // keyboard inspection and the accessibility summary still name every series when the
        // room is not here.
        var x = bounds.minX + Design.Chart.axisLeading
        guard x + occupied <= bounds.maxX - Design.Spacing.inset else { return }

        let y = bounds.maxY - Design.Chart.legendHeight
        for (index, series) in keys.enumerated() {
            let dot = NSRect(
                x: x,
                y: y + (Design.Chart.legendHeight - swatch) / 2,
                width: swatch,
                height: swatch
            )
            color(for: series.style).setFill()
            let radius = Design.Radius.control(fitting: dot.size)
            NSBezierPath(roundedRect: dot, xRadius: radius, yRadius: radius).fill()
            titles[index].draw(at: NSPoint(x: dot.maxX + Design.Spacing.small, y: y))
            x += widths[index] + Design.Spacing.medium
        }
    }

    private func draw(
        series: ThemedChartSeries,
        geometry: ThemedChartRenderedSeries,
        at index: Int,
        in plot: NSRect
    ) {
        if series.mark == .bar {
            drawBars(series: series, geometry: geometry, at: index, in: plot)
        } else if composition == .stackedBands, series.style != .projection {
            drawStackedBand(series: series, geometry: geometry, in: plot)
        } else {
            drawIndependentSeries(series: series, geometry: geometry, in: plot)
        }
    }

    /// Bars over the geometry the curve grammar already produced.
    ///
    /// Each rendered point carries the two edges a bar needs: `baselineY` is zero for an
    /// independent series and the running total for a stacked band, so grouping and stacking are
    /// the *same* drawing code reading a different composition — no second layout pass, and a
    /// stacked total cannot disagree with the band boundary drawn beside it.
    private func drawBars(
        series: ThemedChartSeries,
        geometry: ThemedChartRenderedSeries,
        at index: Int,
        in plot: NSRect
    ) {
        let categories = model.xAxis.categories?.count ?? max(geometry.points.count, 1)
        let band = bandExtent(count: categories, in: plot)
        guard band > 0 else { return }

        let grouped = composition == .independent ? barSeriesIndices : []
        let members = max(1, grouped.count)
        let slot = Design.Chart.barGroupExtent(band: band, members: members) / CGFloat(members)
        let position = grouped.firstIndex(of: index) ?? 0
        let offset = grouped.count > 1
            ? (CGFloat(position) - CGFloat(grouped.count - 1) / 2) * slot
            : 0
        let thickness = max(1, slot - Design.Chart.barGap)
        let fill = color(for: series.style)
        let isRanking = model.orientation == .horizontal

        for value in geometry.points {
            let rect = barRect(for: value, thickness: thickness, offset: offset, in: plot)
            guard rect.width > 0, rect.height > 0 else { continue }
            fill.withAlphaComponent(Design.Chart.barFillOpacity).setFill()
            let path = barPath(rect, stacked: composition == .stackedBands)
            path.fill()
            fill.setStroke()
            path.lineWidth = Design.Radius.border
            path.stroke()

            // A stacked bar's segments carry no printed number. The chart's claim is the total
            // and the split, and a figure at each boundary answers neither — it reads as a
            // running total, sits on the segment's own grid line, and needs a plate that
            // punches a hole in the rule behind it. Hover still names every part.
            guard composition != .stackedBands,
                  thickness >= Design.Chart.barValueLabelThickness,
                  model.series.indices.contains(index),
                  model.series[index].points.indices.contains(value.sourceIndex) else { continue }
            let text = valueString(model.series[index].points[value.sourceIndex].value)
            if isRanking {
                drawBarValue(
                    text,
                    at: NSPoint(
                        x: rect.maxX + Design.Spacing.small,
                        y: rect.midY - Design.Spacing.medium
                    ),
                    alignment: .left,
                    width: Design.Chart.axisLeading
                )
            } else {
                drawBarValue(
                    text,
                    at: NSPoint(x: rect.midX, y: rect.maxY + Design.Spacing.hairline),
                    alignment: .center,
                    width: max(thickness, Design.Chart.minimumCategoryLabelWidth)
                )
            }
        }
    }

    /// A bar rounded at the end it grows towards, and square where it meets its baseline.
    ///
    /// A stacked segment is square at both ends: its top is a boundary with the segment above,
    /// not the end of anything, and rounding it leaves a notch of background inside the total.
    private func barPath(_ rect: NSRect, stacked: Bool) -> NSBezierPath {
        let radius = min(
            Design.Chart.barRadius,
            min(rect.width, rect.height) / 2
        )
        guard radius > 0, !stacked else { return NSBezierPath(rect: rect) }

        let path = NSBezierPath()
        if model.orientation == .horizontal {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                radius: radius,
                startAngle: -90,
                endAngle: 0
            )
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                radius: radius,
                startAngle: 0,
                endAngle: 90
            )
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                radius: radius,
                startAngle: 180,
                endAngle: 90,
                clockwise: true
            )
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                radius: radius,
                startAngle: 90,
                endAngle: 0,
                clockwise: true
            )
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }
        path.close()
        return path
    }

    /// A bar's own number, on a plate of the chart's background.
    ///
    /// Without the plate the grid rule behind it runs straight through the digits — which is
    /// exactly where a tall bar's label lands, since the top of a tall bar is near a gridline
    /// by construction.
    private func drawBarValue(
        _ text: String,
        at point: NSPoint,
        alignment: NSTextAlignment,
        width: CGFloat
    ) {
        let font = Design.Typography.numericDetail()
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let origin: CGFloat
        switch alignment {
        case .right: origin = point.x - measured.width
        case .center: origin = point.x - measured.width / 2
        default: origin = point.x
        }
        // The label is drawn into a slot one `large` tall and lands at the *top* of it, so a
        // plate placed at the slot's origin sits half a line below the glyphs it is meant to
        // clear — which is why the ranking chart still had a rule running through its numbers.
        let plate = NSRect(
            x: origin - Design.Spacing.small,
            y: point.y + Design.Spacing.large - measured.height,
            // A hairline of clearance still reads as a rule touching the digits. The knockout
            // has to be wide enough to look deliberate, or it looks like a rendering fault.
            width: measured.width + Design.Spacing.small * 2,
            height: measured.height
        )
        plotBackground.setFill()
        NSBezierPath(rect: plate).fill()
        draw(text, at: point, color: barValueColor, alignment: alignment, width: width)
    }

    /// The colour the chart paints itself with, which is what a label plate has to match.
    private var plotBackground: NSColor {
        if Design.Chart.style == .spectrum { return Design.Surface.field }
        return AppThemePalette.current.isSystem ? Design.Surface.ground : Design.Surface.panel
    }

    /// The paint order positions of the bar series, which is what decides a grouped bar's slot.
    /// A chart mixing a line with bars must not leave a gap where the line "would" have stood.
    private var barSeriesIndices: [Int] {
        model.series.indices.filter { model.series[$0].mark == .bar }
    }

    private func barRect(
        for value: ThemedChartRenderedPoint,
        thickness: CGFloat,
        offset: CGFloat,
        in plot: NSRect
    ) -> NSRect {
        let lower = CGFloat(min(value.baselineY, value.y))
        let upper = CGFloat(max(value.baselineY, value.y))
        if model.orientation == .horizontal {
            // Category zero reads at the top, because a ranking is read down a page.
            let centre = plot.maxY - CGFloat(value.x) * plot.height + offset
            return NSRect(
                x: plot.minX + lower * plot.width,
                y: centre - thickness / 2,
                width: (upper - lower) * plot.width,
                height: thickness
            )
        }
        let centre = plot.minX + CGFloat(value.x) * plot.width + offset
        return NSRect(
            x: centre - thickness / 2,
            y: plot.minY + lower * plot.height,
            width: thickness,
            height: (upper - lower) * plot.height
        )
    }

    private func drawIndependentSeries(
        series: ThemedChartSeries,
        geometry: ThemedChartRenderedSeries,
        in plot: NSRect
    ) {
        guard !geometry.points.isEmpty else { return }
        let color = color(for: series.style)

        var start = geometry.points.startIndex
        while start < geometry.points.endIndex {
            let segment = geometry.points[start].segment
            var end = geometry.points.index(after: start)
            while end < geometry.points.endIndex, geometry.points[end].segment == segment {
                end = geometry.points.index(after: end)
            }
            let indices = start..<end

            if series.fillsArea, let first = indices.first, let last = indices.last {
                let fill = NSBezierPath()
                fill.move(to: point(geometry.points[first], in: plot, y: 0))
                fill.line(to: point(geometry.points[first], in: plot))
                appendCurve(
                    geometry.points,
                    indices: indices,
                    curve: series.curve,
                    plot: plot,
                    to: fill,
                    moveToFirst: false
                )
                fill.line(to: point(geometry.points[last], in: plot, y: 0))
                fill.close()
                color.withAlphaComponent(
                    AppThemePalette.current.isSystem
                        ? Design.Chart.systemAreaOpacity
                        : Design.Chart.themedAreaOpacity
                ).setFill()
                fill.fill()
            }

            let path = NSBezierPath()
            appendCurve(
                geometry.points,
                indices: indices,
                curve: series.curve,
                plot: plot,
                to: path,
                moveToFirst: true
            )
            color.withAlphaComponent(AppThemePalette.current.isSystem ? 0.90 : 1).setStroke()
            path.lineWidth = series.style == .projection
                ? Design.Chart.projectionLineWidth
                : (AppThemePalette.current.isSystem
                    ? Design.Chart.systemLineWidth
                    : Design.Chart.lineWidth)
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            if series.style == .projection {
                let dash = [Design.Spacing.small, Design.Spacing.tight]
                path.setLineDash(dash, count: dash.count, phase: 0)
            }
            path.stroke()
            start = end
        }
    }

    private func drawStackedBand(
        series: ThemedChartSeries,
        geometry: ThemedChartRenderedSeries,
        in plot: NSRect
    ) {
        guard !geometry.points.isEmpty else { return }
        let color = color(for: series.style)
        var start = geometry.points.startIndex
        while start < geometry.points.endIndex {
            let segment = geometry.points[start].segment
            var end = geometry.points.index(after: start)
            while end < geometry.points.endIndex, geometry.points[end].segment == segment {
                end = geometry.points.index(after: end)
            }
            let indices = start..<end

            let band = NSBezierPath()
            appendCurve(
                geometry.points,
                indices: indices,
                curve: series.curve,
                plot: plot,
                to: band,
                moveToFirst: true,
                ordinate: .upper,
                direction: .forward
            )
            if let last = indices.last {
                band.line(to: point(geometry.points[last], in: plot, y: geometry.points[last].baselineY))
            }
            appendCurve(
                geometry.points,
                indices: indices,
                curve: series.curve,
                plot: plot,
                to: band,
                moveToFirst: false,
                ordinate: .lower,
                direction: .reverse
            )
            band.close()
            color.withAlphaComponent(
                AppThemePalette.current.isSystem
                    ? Design.Chart.systemStackedBandOpacity
                    : Design.Chart.themedStackedBandOpacity
            ).setFill()
            band.fill()

            let edge = NSBezierPath()
            appendCurve(
                geometry.points,
                indices: indices,
                curve: series.curve,
                plot: plot,
                to: edge,
                moveToFirst: true
            )
            color.withAlphaComponent(AppThemePalette.current.isSystem ? 0.90 : 1).setStroke()
            edge.lineWidth = AppThemePalette.current.isSystem
                ? Design.Chart.systemLineWidth
                : Design.Chart.lineWidth
            edge.lineJoinStyle = .round
            edge.lineCapStyle = .round
            edge.stroke()
            start = end
        }
    }

    private struct SpectrumSample {
        let lower: Double
        let upper: Double
    }

    /// Player materials turn filled series into one shared analyzer: discrete columns retain the
    /// exact band boundaries, horizontal field-coloured cuts create the LED cells, and an amber
    /// cap makes the daily total scan like a held peak. Geometry remains the same bounded,
    /// animating presentation geometry used by continuous charts.
    private func drawSpectrum(seriesIndices: [Int], in plot: NSRect) {
        guard !seriesIndices.isEmpty, plot.width > 0, plot.height > 0 else { return }
        let stride = Design.Chart.spectrumColumnWidth + Design.Chart.spectrumColumnGap
        let count = max(1, Int((plot.width + Design.Chart.spectrumColumnGap) / stride))
        var peaks: [NSRect] = []
        peaks.reserveCapacity(count)

        for column in 0..<count {
            let phase = count == 1 ? 0.5 : Double(column) / Double(count - 1)
            let x = plot.minX + CGFloat(column) * stride
            let width = min(Design.Chart.spectrumColumnWidth, plot.maxX - x)
            guard width > 0 else { continue }
            var peak = 0.0

            for index in seriesIndices {
                guard displayedGeometry.indices.contains(index), model.series.indices.contains(index),
                      let sample = spectrumSample(at: phase, in: displayedGeometry[index].points)
                else { continue }
                let lower = plot.minY + CGFloat(sample.lower) * plot.height
                let upper = plot.minY + CGFloat(sample.upper) * plot.height
                guard upper > lower else { continue }
                color(for: model.series[index].style)
                    .withAlphaComponent(Design.Chart.spectrumBandOpacity)
                    .setFill()
                NSRect(x: x, y: lower, width: width, height: upper - lower).fill()
                peak = max(peak, sample.upper)
            }

            if peak > 0 {
                let peakY = min(
                    plot.maxY - Design.Chart.spectrumPeakHeight,
                    plot.minY + CGFloat(peak) * plot.height
                )
                peaks.append(NSRect(
                    x: x,
                    y: peakY,
                    width: width,
                    height: Design.Chart.spectrumPeakHeight
                ))
            }
        }

        // One pass of dark gaps is substantially cheaper than drawing every LED as its own rect.
        Design.Surface.field.setFill()
        var y = plot.minY + Design.Chart.spectrumCellHeight
        while y < plot.maxY {
            NSRect(
                x: plot.minX,
                y: y,
                width: plot.width,
                height: min(Design.Chart.spectrumCellGap, plot.maxY - y)
            ).fill()
            y += Design.Chart.spectrumCellHeight + Design.Chart.spectrumCellGap
        }

        Design.Status.warning.setFill()
        peaks.forEach { $0.fill() }
    }

    private func spectrumSample(
        at x: Double,
        in points: [ThemedChartRenderedPoint]
    ) -> SpectrumSample? {
        guard let first = points.first, let last = points.last,
              x >= first.x, x <= last.x else { return nil }
        guard points.count > 1 else {
            return SpectrumSample(lower: first.baselineY, upper: first.y)
        }

        var lowerIndex = 0
        while lowerIndex + 1 < points.count, points[lowerIndex + 1].x < x {
            lowerIndex += 1
        }
        let upperIndex = min(points.count - 1, lowerIndex + 1)
        let lower = points[lowerIndex]
        let upper = points[upperIndex]
        guard lower.segment == upper.segment else { return nil }
        let width = upper.x - lower.x
        let phase = width > 0 ? min(max((x - lower.x) / width, 0), 1) : 0
        return SpectrumSample(
            lower: lower.baselineY + (upper.baselineY - lower.baselineY) * phase,
            upper: lower.y + (upper.y - lower.y) * phase
        )
    }

    private enum CurveOrdinate {
        case upper
        case lower
    }

    private enum CurveDirection {
        case forward
        case reverse
    }

    /// Fritsch-Carlson-style monotone tangents keep a soft curve inside each pair's vertical
    /// extent. That avoids both the angular daily polyline and the decorative overshoot a plain
    /// Catmull-Rom spline would invent around sharp cost spikes.
    private func appendCurve(
        _ values: [ThemedChartRenderedPoint],
        indices: Range<Int>,
        curve: ThemedChartCurve,
        plot: NSRect,
        to path: NSBezierPath,
        moveToFirst: Bool,
        ordinate: CurveOrdinate = .upper,
        direction: CurveDirection = .forward
    ) {
        guard let first = indices.first else { return }
        let initial = direction == .forward ? first : indices.upperBound - 1
        let firstPoint = point(values[initial], in: plot, ordinate: ordinate)
        if moveToFirst { path.move(to: firstPoint) }
        guard indices.count > 1 else { return }

        switch direction {
        case .forward:
            for index in indices.dropLast() {
                appendCurveSegment(
                    values,
                    from: index,
                    to: index + 1,
                    indices: indices,
                    curve: curve,
                    ordinate: ordinate,
                    plot: plot,
                    path: path
                )
            }
        case .reverse:
            var index = indices.upperBound - 1
            while index > indices.lowerBound {
                appendCurveSegment(
                    values,
                    from: index,
                    to: index - 1,
                    indices: indices,
                    curve: curve,
                    ordinate: ordinate,
                    plot: plot,
                    path: path
                )
                index -= 1
            }
        }
    }

    private func appendCurveSegment(
        _ values: [ThemedChartRenderedPoint],
        from oldIndex: Int,
        to newIndex: Int,
        indices: Range<Int>,
        curve: ThemedChartCurve,
        ordinate: CurveOrdinate,
        plot: NSRect,
        path: NSBezierPath
    ) {
        let old = point(values[oldIndex], in: plot, ordinate: ordinate)
        let new = point(values[newIndex], in: plot, ordinate: ordinate)
        guard curve == .smooth, new.x != old.x else {
            path.line(to: new)
            return
        }

        let lowerIndex = min(oldIndex, newIndex)
        let upperIndex = max(oldIndex, newIndex)
        let delta = secant(
            values,
            from: lowerIndex,
            to: upperIndex,
            ordinate: ordinate,
            in: plot
        )
        guard delta.isFinite else {
            path.line(to: new)
            return
        }
        var oldSlope = tangent(values, at: oldIndex, within: indices, ordinate: ordinate, in: plot)
        var newSlope = tangent(values, at: newIndex, within: indices, ordinate: ordinate, in: plot)
        if delta == 0 {
            oldSlope = 0
            newSlope = 0
        } else {
            let a = oldSlope / delta
            let b = newSlope / delta
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let scale = 3 / sqrt(magnitude)
                oldSlope = scale * a * delta
                newSlope = scale * b * delta
            }
        }

        let third = (new.x - old.x) / 3
        let minimum = min(old.y, new.y)
        let maximum = max(old.y, new.y)
        let firstControl = NSPoint(
            x: old.x + third,
            y: min(max(old.y + oldSlope * third, minimum), maximum)
        )
        let secondControl = NSPoint(
            x: new.x - third,
            y: min(max(new.y - newSlope * third, minimum), maximum)
        )
        path.curve(to: new, controlPoint1: firstControl, controlPoint2: secondControl)
    }

    private func tangent(
        _ values: [ThemedChartRenderedPoint],
        at index: Int,
        within indices: Range<Int>,
        ordinate: CurveOrdinate,
        in plot: NSRect
    ) -> CGFloat {
        if index == indices.lowerBound {
            return secant(values, from: index, to: index + 1, ordinate: ordinate, in: plot)
        }
        if index == indices.upperBound - 1 {
            return secant(values, from: index - 1, to: index, ordinate: ordinate, in: plot)
        }
        let before = secant(values, from: index - 1, to: index, ordinate: ordinate, in: plot)
        let after = secant(values, from: index, to: index + 1, ordinate: ordinate, in: plot)
        guard before.isFinite, after.isFinite, before * after > 0 else { return 0 }
        return (before + after) / 2
    }

    private func secant(
        _ values: [ThemedChartRenderedPoint],
        from oldIndex: Int,
        to newIndex: Int,
        ordinate: CurveOrdinate,
        in plot: NSRect
    ) -> CGFloat {
        let old = point(values[oldIndex], in: plot, ordinate: ordinate)
        let new = point(values[newIndex], in: plot, ordinate: ordinate)
        let width = new.x - old.x
        guard width > 0 else { return 0 }
        return (new.y - old.y) / width
    }

    /// The horizontal lines: a level the series is read against, drawn behind the time markers.
    ///
    /// Behind them because the two answer different questions and a crossing is where they meet —
    /// a vertical reset marker standing over the cap line reads as the reset clearing it, which is
    /// what happened. Skipped in a ranking chart, where the value axis runs the other way and a
    /// "level" is a bar length rather than a line anyone could draw.
    private func drawValueRules(in plot: NSRect) {
        guard model.orientation == .vertical, !model.valueRules.isEmpty else { return }

        let span = resolvedYRange.upperBound - resolvedYRange.lowerBound
        guard span > 0 else { return }

        for rule in model.valueRules {
            let normalized = (rule.value - resolvedYRange.lowerBound) / span
            guard (0...1).contains(normalized) else { continue }

            let y = plot.minY + CGFloat(normalized) * plot.height
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            valueRuleColor(rule.kind).setStroke()
            path.lineWidth = Design.Chart.markerLineWidth
            // A longer dash than a time marker's, so the two read as different kinds of line even
            // where they cross and even in one ink.
            let dash = [Design.Spacing.small, Design.Spacing.tight]
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.stroke()

            // Measured rather than given the axis slot: an axis label is a formatted number in a
            // fixed column, while this is a short phrase naming the line. Drawn at the axis width
            // it truncated to `Your limit ·…`, which names nothing.
            let font = Design.Typography.numericDetail()
            let measured = (rule.title as NSString).size(withAttributes: [.font: font]).width
            draw(
                rule.title,
                at: NSPoint(x: plot.minX + Design.Spacing.tight, y: y + Design.Spacing.hairline),
                color: valueRuleColor(rule.kind),
                alignment: .left,
                width: min(measured + Design.Spacing.small, plot.width)
            )
        }
    }

    private func valueRuleColor(_ kind: ThemedChartValueRule.Kind) -> NSColor {
        switch kind {
        case .cap: return Design.Status.warning
        }
    }

    private func drawMarkers(in plot: NSRect) {
        guard let range = xDomain else { return }
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)
        guard duration > 0 else { return }
        for marker in renderedMarkers where range.contains(marker.at) {
            let phase = marker.at.timeIntervalSince(range.lowerBound) / duration
            let x = plot.minX + CGFloat(phase) * plot.width
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: plot.minY))
            path.line(to: NSPoint(x: x, y: plot.maxY))
            markerColor(marker.kind).setStroke()
            path.lineWidth = Design.Chart.markerLineWidth
            let dash = [Design.Spacing.tight, Design.Spacing.tight]
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.stroke()

            let glyph: String
            switch marker.kind {
            case .reset: glyph = "↻"
            case .expiry: glyph = "◆"
            case .projection: glyph = "◇"
            case .now: glyph = L10n.string("Now")
            }
            draw(
                glyph,
                at: NSPoint(x: x, y: plot.maxY + Design.Spacing.tight),
                color: markerColor(marker.kind),
                alignment: .center
            )
        }
    }

    private func drawSelection(_ selection: (series: Int, point: Int), in plot: NSRect) {
        guard model.series.indices.contains(selection.series),
              model.series[selection.series].points.indices.contains(selection.point),
              displayedGeometry.indices.contains(selection.series),
              !displayedGeometry[selection.series].points.isEmpty else { return }
        let source = model.series[selection.series].points[selection.point]
        let rendered = nearestRenderedPoint(to: source.at, in: selection.series)
        guard let rendered else { return }
        let location = point(rendered, in: plot)

        color(for: model.series[selection.series].style).setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: location.x - Design.Chart.selectedPointRadius,
                y: location.y - Design.Chart.selectedPointRadius,
                width: Design.Chart.selectedPointRadius * 2,
                height: Design.Chart.selectedPointRadius * 2
            )
        ).fill()
        drawTooltip(for: source, series: model.series[selection.series], near: location)
    }

    private func drawTooltip(
        for value: ThemedChartPoint,
        series: ThemedChartSeries,
        near location: NSPoint
    ) {
        let text = inspectionLines(for: value, series: series).joined(separator: "\n")
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.detail(),
            .foregroundColor: Design.Text.label
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let measured = string.boundingRect(
            with: NSSize(width: Design.Chart.tooltipMaxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral
        let size = NSSize(
            width: min(Design.Chart.tooltipMaxWidth, measured.width) + Design.Chart.tooltipInset * 2,
            height: measured.height + Design.Chart.tooltipInset * 2
        )
        var origin = NSPoint(
            x: location.x + Design.Chart.tooltipOffset,
            y: location.y + Design.Chart.tooltipOffset
        )
        if origin.x + size.width > bounds.maxX - Design.Spacing.inset {
            origin.x = location.x - Design.Chart.tooltipOffset - size.width
        }
        if origin.y + size.height > bounds.maxY - Design.Spacing.inset {
            origin.y = location.y - Design.Chart.tooltipOffset - size.height
        }
        let rect = NSRect(origin: origin, size: size)
        _ = ThemedSurface.draw(
            rect,
            fill: Design.Surface.elevated,
            border: Design.Surface.border,
            radius: Design.Radius.control
        )
        string.draw(
            with: rect.insetBy(dx: Design.Chart.tooltipInset, dy: Design.Chart.tooltipInset),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private func draw(
        _ text: String,
        at point: NSPoint,
        color: NSColor,
        alignment: NSTextAlignment,
        width: CGFloat = Design.Chart.axisLeading,
        font: NSFont? = nil
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        // An axis label is a fixed-width slot. A category name is a word rather than a formatted
        // number, so it must end in an ellipsis instead of overrunning the bar beside it.
        paragraph.lineBreakMode = .byTruncatingTail
        let x: CGFloat
        switch alignment {
        case .right: x = point.x - width
        case .center: x = point.x - width / 2
        default: x = point.x
        }
        NSAttributedString(
            string: text,
            attributes: [
                .font: font ?? Design.Typography.numericDetail(),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        ).draw(in: NSRect(x: x, y: point.y, width: width, height: Design.Spacing.large))
    }

    private func point(
        _ value: ThemedChartRenderedPoint,
        in plot: NSRect,
        y overrideY: Double? = nil
    ) -> NSPoint {
        let ordinate = CGFloat(overrideY ?? value.y)
        // Selection, tooltips and curves all resolve a rendered point through here, so a ranking
        // chart transposes once, in one place, rather than in each of them.
        if model.orientation == .horizontal {
            return NSPoint(
                x: plot.minX + ordinate * plot.width,
                y: plot.maxY - CGFloat(value.x) * plot.height
            )
        }
        return NSPoint(
            x: plot.minX + CGFloat(value.x) * plot.width,
            y: plot.minY + ordinate * plot.height
        )
    }

    private func point(
        _ value: ThemedChartRenderedPoint,
        in plot: NSRect,
        ordinate: CurveOrdinate
    ) -> NSPoint {
        point(
            value,
            in: plot,
            y: ordinate == .upper ? value.y : value.baselineY
        )
    }

    private var xDomain: ClosedRange<Date>? {
        resolvedXRange
    }

    private func yValue(at phase: Double) -> Double {
        resolvedYRange.lowerBound
            + (resolvedYRange.upperBound - resolvedYRange.lowerBound) * phase
    }

    private func valueString(_ value: Double) -> String {
        switch model.valueFormat {
        case .percent: return "\(Int((value * 100).rounded()))%"
        // Abbreviated, like the token axis beside it: this string goes into a fixed 64-point
        // slot that truncates its tail, and an exact `US$100,000.00` there is `US$100,0…` —
        // a label whose only job is to say what the marks mean, saying nothing.
        case .currency: return UsageFormat.compactCurrency(value)
        case .tokens: return UsageFormat.tokens(Int64(value.rounded()))
        case .number: return value.formatted(.number.precision(.fractionLength(0...1)))
        case .unit(let suffix):
            let number = value.formatted(.number.precision(.fractionLength(0...1)))
            return suffix.isEmpty ? number : "\(number) \(suffix)"
        }
    }

    private func color(for style: ThemedChartSeriesStyle) -> NSColor {
        Design.Chart.color(for: style)
    }

    private func markerColor(_ kind: ThemedChartMarkerKind) -> NSColor {
        switch kind {
        case .reset: return Design.Status.positive
        case .expiry: return Design.Status.warning
        case .projection: return Design.Surface.accent
        case .now: return Design.Text.secondary
        }
    }

    /// Where a hover is answered: the plot, plus the gutter its **category names** are drawn in.
    ///
    /// A category name is a word in a fixed-width slot, so a long one ends in an ellipsis — and the
    /// pointer that goes to read it lands on the one part of the chart that answered nothing.
    /// Inspection already carries the whole name, so the fix is where the chart listens rather than
    /// what it says: a name and the band it labels are the same target. The time axis keeps the
    /// plot alone — its leading gutter holds *values*, not names, and a hover there would be
    /// answered by whichever point happens to sit at the left edge.
    private var hoverRect: NSRect {
        let plot = plotRect
        guard model.xAxis.categories != nil, plot.width > 0, plot.height > 0 else { return plot }
        if model.orientation == .horizontal {
            return NSRect(
                x: bounds.minX,
                y: plot.minY,
                width: plot.maxX - bounds.minX,
                height: plot.height
            )
        }
        return NSRect(
            x: plot.minX,
            y: bounds.minY,
            width: plot.width,
            height: plot.maxY - bounds.minY
        )
    }

    /// Hover, without a window or a synthesized event: a test drives the same entry point the
    /// tracking area does, and reads the answer back through `inspectionForTesting`.
    func hoverForTesting(at location: NSPoint) {
        selectNearest(to: location)
    }

    /// What the tooltip and VoiceOver currently state, or nothing when no point is selected.
    var inspectionForTesting: [String] {
        guard let selected,
              model.series.indices.contains(selected.series),
              model.series[selected.series].points.indices.contains(selected.point)
        else { return [] }
        let series = model.series[selected.series]
        return inspectionLines(for: series.points[selected.point], series: series)
    }

    private func selectNearest(to location: NSPoint) {
        let plot = plotRect
        guard hoverRect.contains(location), !model.series.isEmpty else {
            selected = nil
            needsDisplay = true
            return
        }
        let targetX = model.orientation == .horizontal
            ? Double((plot.maxY - location.y) / plot.height)
            : Double((location.x - plot.minX) / plot.width)
        var best: (distance: Double, series: Int, point: Int)?
        for (seriesIndex, series) in displayedGeometry.enumerated() {
            guard model.series.indices.contains(seriesIndex) else { continue }
            for value in series.points
                where model.series[seriesIndex].points.indices.contains(value.sourceIndex) {
                let distance = abs(value.x - targetX)
                if best.map({ distance < $0.distance }) ?? true {
                    best = (distance, seriesIndex, value.sourceIndex)
                }
            }
        }
        selected = best.map { ($0.series, $0.point) }
        needsDisplay = true
    }

    private func moveSelection(by offset: Int) {
        let values = targetGeometry.enumerated().flatMap { seriesIndex, series in
            series.points.compactMap { rendered -> (series: Int, point: Int)? in
                guard model.series.indices.contains(seriesIndex),
                      model.series[seriesIndex].points.indices.contains(rendered.sourceIndex)
                else { return nil }
                return (seriesIndex, rendered.sourceIndex)
            }
        }.sorted {
            model.series[$0.series].points[$0.point].at
                < model.series[$1.series].points[$1.point].at
        }
        guard !values.isEmpty else { return }
        let current = selected.flatMap { selection in
            values.firstIndex { $0.series == selection.series && $0.point == selection.point }
        } ?? (offset > 0 ? -1 : values.count)
        let next = min(max(current + offset, 0), values.count - 1)
        selected = values[next]
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func nearestRenderedPoint(
        to date: Date,
        in seriesIndex: Int
    ) -> ThemedChartRenderedPoint? {
        guard displayedGeometry.indices.contains(seriesIndex), let domain = xDomain else { return nil }
        let duration = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let x = duration > 0 ? date.timeIntervalSince(domain.lowerBound) / duration : 0
        return displayedGeometry[seriesIndex].points.min { abs($0.x - x) < abs($1.x - x) }
    }

    private func accessibilityDescription(for series: Int, point: Int) -> String {
        let group = model.series[series]
        return inspectionLines(for: group.points[point], series: group).joined(separator: ", ")
    }

    /// What hover, keyboard inspection and VoiceOver all say about one point — one list, so the
    /// picture and the spoken sentence cannot disagree about what is under the pointer.
    ///
    /// A time series' `label` is its *reading* (`42%`, `US$1.20`), and stating the value again
    /// beside it would say the same thing twice. A categorical point's label is its **name**, so
    /// the reading has to be stated separately: on a compressed ranking the bar is too thin to
    /// print its own number and the name on the axis is an ellipsized stub, which leaves this the
    /// only place either can be read. Empty strings are dropped rather than joined — a series with
    /// no title is normal (one series needs no key) and used to open the tooltip with a blank line.
    private func inspectionLines(
        for value: ThemedChartPoint,
        series: ThemedChartSeries
    ) -> [String] {
        let lines = model.xAxis.categories == nil
            ? [series.title, value.label ?? valueString(value.value), value.detail]
            : [series.title, value.label, valueString(value.value), value.detail]
        return lines.compactMap { $0 }.filter { !$0.isEmpty }
    }

    private func startDriver() {
        guard displayLink == nil, fallbackTimer == nil else { return }
        if #available(macOS 14.0, *) {
            let link = self.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(tick),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func stopDriver() {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func tick() {
        advanceAnimation(now: CACurrentMediaTime())
    }
}

/// A separate reusable chart surface for additive composition. It shares the retained geometry,
/// interaction, animation and theme machinery with `ThemedTimeSeriesChartView`, but its bands are
/// semantically cumulative: the final upper edge is the total at that timestamp.
final class ThemedStackedBandChartView: ThemedTimeSeriesChartView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect, composition: .stackedBands)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
