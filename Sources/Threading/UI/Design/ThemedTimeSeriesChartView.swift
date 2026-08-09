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

struct ThemedChartSeries: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let points: [ThemedChartPoint]
    let style: ThemedChartSeriesStyle
    let fillsArea: Bool
    let curve: ThemedChartCurve

    init(
        id: String,
        title: String,
        points: [ThemedChartPoint],
        style: ThemedChartSeriesStyle = .primary,
        fillsArea: Bool = false,
        curve: ThemedChartCurve = .smooth
    ) {
        self.id = id
        self.title = title
        self.points = points
        self.style = style
        self.fillsArea = fillsArea
        self.curve = curve
    }
}

enum ThemedChartMarkerKind: Equatable, Sendable {
    case reset
    case expiry
    case projection
}

struct ThemedChartMarker: Equatable, Sendable, Identifiable {
    let id: String
    let at: Date
    let title: String
    let detail: String?
    let kind: ThemedChartMarkerKind
}

enum ThemedChartValueFormat: Equatable, Sendable {
    case percent
    case currency
    case tokens
    case number
}

struct ThemedChartModel: Equatable, Sendable {
    let title: String
    let accessibilitySummary: String
    let series: [ThemedChartSeries]
    let markers: [ThemedChartMarker]
    let xRange: ClosedRange<Date>?
    let yRange: ClosedRange<Double>?
    let valueFormat: ThemedChartValueFormat
    let emptyMessage: String

    init(
        title: String,
        accessibilitySummary: String,
        series: [ThemedChartSeries],
        markers: [ThemedChartMarker] = [],
        xRange: ClosedRange<Date>? = nil,
        yRange: ClosedRange<Double>? = nil,
        valueFormat: ThemedChartValueFormat = .number,
        emptyMessage: String = L10n.string("No data in this range")
    ) {
        self.title = title
        self.accessibilitySummary = accessibilitySummary
        self.series = series
        self.markers = markers
        self.xRange = xRange
        self.yRange = yRange
        self.valueFormat = valueFormat
        self.emptyMessage = emptyMessage
    }

    static let empty = Self(title: "", accessibilitySummary: "", series: [])
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
            xRange = nonEmpty(requested)
            let lower = xRange!.lowerBound.timeIntervalSinceReferenceDate
            let upper = xRange!.upperBound.timeIntervalSinceReferenceDate
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

        let automaticY = 0...max(maximumValue * 1.08, 1)
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
        selectNearest(to: convert(event.locationInWindow, from: nil))
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
        drawGrid(in: plot)

        // Do not flatten provider-sized source arrays on every animation frame. Geometry is
        // bounded, but the retained model deliberately keeps full source indices for tooltips.
        if !model.series.contains(where: { !$0.points.isEmpty }) {
            drawCentered(model.emptyMessage, in: plot)
            return
        }

        if isSpectrum {
            let spectrumIndices = displayedGeometry.indices.filter { index in
                model.series.indices.contains(index)
                    && model.series[index].style != .projection
                    && (composition == .stackedBands || model.series[index].fillsArea)
            }
            drawSpectrum(seriesIndices: spectrumIndices, in: plot)
            for index in displayedGeometry.indices where !spectrumIndices.contains(index) {
                guard model.series.indices.contains(index) else { continue }
                draw(series: model.series[index], geometry: displayedGeometry[index], in: plot)
            }
        } else {
            for (index, geometry) in displayedGeometry.enumerated() {
                guard model.series.indices.contains(index) else { continue }
                draw(series: model.series[index], geometry: geometry, in: plot)
            }
        }
        drawMarkers(in: plot)
        if let selected { drawSelection(selected, in: plot) }
    }

    private var plotRect: NSRect {
        NSRect(
            x: bounds.minX + Design.Chart.axisLeading,
            y: bounds.minY + Design.Chart.axisBottom,
            width: max(0, bounds.width - Design.Chart.axisLeading - Design.Chart.axisTrailing),
            height: max(0, bounds.height - Design.Chart.axisBottom - Design.Chart.axisTop)
        )
    }

    private func drawGrid(in plot: NSRect) {
        let grid = NSBezierPath()
        for index in 0..<Design.Chart.gridLineCount {
            let phase = CGFloat(index) / CGFloat(Design.Chart.gridLineCount - 1)
            let y = plot.minY + phase * plot.height
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            let value = yValue(at: Double(phase))
            draw(
                valueString(value),
                at: NSPoint(x: bounds.minX + Design.Spacing.inset, y: y - Design.Spacing.small),
                color: Design.Chart.style == .spectrum
                    ? Design.Surface.accent.withAlphaComponent(0.62)
                    : Design.Text.tertiary,
                alignment: .left
            )
        }
        let gridColor: NSColor
        if Design.Chart.style == .spectrum {
            gridColor = Design.Surface.accent.withAlphaComponent(0.16)
        } else if AppThemePalette.current.isSystem {
            gridColor = Design.Surface.divider.withAlphaComponent(0.42)
        } else {
            gridColor = Design.Surface.divider
        }
        gridColor.setStroke()
        grid.lineWidth = Design.Radius.border
        grid.stroke()

        guard let range = xDomain else { return }
        for index in 0..<Design.Chart.xLabelCount {
            let phase = Double(index) / Double(Design.Chart.xLabelCount - 1)
            let date = range.lowerBound.addingTimeInterval(
                range.upperBound.timeIntervalSince(range.lowerBound) * phase
            )
            let x = plot.minX + CGFloat(phase) * plot.width
            draw(
                dateFormatter.string(from: date),
                at: NSPoint(x: x, y: bounds.minY + Design.Spacing.small),
                color: Design.Chart.style == .spectrum
                    ? Design.Surface.accent.withAlphaComponent(0.62)
                    : Design.Text.tertiary,
                alignment: index == 0 ? .left : (index == Design.Chart.xLabelCount - 1 ? .right : .center)
            )
        }
    }

    private func draw(series: ThemedChartSeries, geometry: ThemedChartRenderedSeries, in plot: NSRect) {
        if composition == .stackedBands, series.style != .projection {
            drawStackedBand(series: series, geometry: geometry, in: plot)
        } else {
            drawIndependentSeries(series: series, geometry: geometry, in: plot)
        }
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
        let lines = [series.title, value.label ?? valueString(value.value), value.detail]
            .compactMap { $0 }
        let text = lines.joined(separator: "\n")
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

    private func drawCentered(_ text: String, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.body(),
            .foregroundColor: Design.Text.secondary
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func draw(
        _ text: String,
        at point: NSPoint,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let width = Design.Chart.axisLeading
        let x: CGFloat
        switch alignment {
        case .right: x = point.x - width
        case .center: x = point.x - width / 2
        default: x = point.x
        }
        NSAttributedString(
            string: text,
            attributes: [
                .font: Design.Typography.numericDetail(),
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
        NSPoint(
            x: plot.minX + CGFloat(value.x) * plot.width,
            y: plot.minY + CGFloat(overrideY ?? value.y) * plot.height
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
        case .currency: return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
        case .tokens: return UsageFormat.tokens(Int64(value.rounded()))
        case .number: return value.formatted(.number.precision(.fractionLength(0...1)))
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
        }
    }

    private func selectNearest(to location: NSPoint) {
        let plot = plotRect
        guard plot.contains(location), !model.series.isEmpty else {
            selected = nil
            needsDisplay = true
            return
        }
        let targetX = Double((location.x - plot.minX) / plot.width)
        var best: (distance: Double, series: Int, point: Int)?
        for (seriesIndex, series) in displayedGeometry.enumerated() {
            guard model.series.indices.contains(seriesIndex) else { continue }
            for value in series.points
                where model.series[seriesIndex].points.indices.contains(value.sourceIndex) {
                let distance = abs(value.x - targetX)
                if best == nil || distance < best!.distance {
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
        let value = group.points[point]
        return [group.title, value.label ?? valueString(value.value), value.detail]
            .compactMap { $0 }
            .joined(separator: ", ")
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
