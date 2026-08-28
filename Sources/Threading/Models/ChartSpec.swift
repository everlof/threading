import Foundation

/// A chart an agent asked for, as data rather than as drawing.
///
/// The contract is deliberately one altitude above `display_scene`: a caller supplies values and
/// the words for them, never geometry. Threading owns the scale, the axes, the ticks, the palette,
/// the legend, hover, focus and the accessibility summary — which is the only way a chart produced
/// by a model can come out looking like the rest of the app instead of like whatever that model
/// last saw on the web. It is also the only way the picture can be *correct*: an agent asked for
/// normalized rectangles will cheerfully draw a 42 next to a bar 40% as tall as the 18 beside it.
///
/// Persisted with the pane tab that shows it, so it is a value model with no view or theme in it.
struct ChartSpec: Codable, Equatable, Sendable {

    // MARK: - Types

    enum Kind: String, Codable, Sendable {
        /// Vertical bars over categories: comparison and composition.
        case bar
        /// Horizontal bars, category names down the leading edge: ranking.
        case ranking
        /// A line over the same category positions: trend and progression.
        case line
        /// A line with the area under it filled.
        case area
    }

    enum ValueFormat: String, Codable, Sendable {
        case number
        case percent
        case currency
        case tokens
    }

    /// What a series *means*, when it means something. The default is a categorical hue chosen by
    /// position, because most series are simply different things rather than good or bad ones.
    enum Emphasis: String, Codable, Sendable {
        case neutral
        case positive
        case warning
        case negative
    }

    struct Series: Codable, Equatable, Sendable {
        let name: String
        let values: [Double]
        var details: [String]?
        var emphasis: Emphasis?
    }

    // MARK: - Limits

    enum Limits {
        static let maximumSeries = 8
        static let maximumCategories = 60
        static let maximumTitle = 120
        static let maximumLabel = 60
        /// A comparison of more than this many bars is a table wearing a chart's clothes.
        ///
        /// The cap is on the *product*, and is deliberately well below `maximumSeries ×
        /// maximumCategories`: eight series of sixty categories clears both per-axis limits and
        /// is still 480 bars in a pane three hundred points wide, where each one is a third of
        /// a point of ink. A cap equal to the product would never refuse anything.
        static let maximumMarks = 240
    }

    enum Failure: LocalizedError, Equatable {
        case noSeries
        case noCategories
        case tooManySeries(Int)
        case tooManyCategories(Int)
        case tooManyMarks(Int)
        case lengthMismatch(series: String, values: Int, categories: Int)
        case nonFiniteValue(series: String)
        case negativeStackedValue(series: String)

        var errorDescription: String? {
            switch self {
            case .noSeries:
                return "A chart needs at least one series."
            case .noCategories:
                return "A chart needs at least one category to plot against."
            case .tooManySeries(let count):
                return """
                    \(count) series is more than the \(Limits.maximumSeries) a readable chart \
                    holds. Chart the ones that carry the point, or split them across two charts.
                    """
            case .tooManyCategories(let count):
                return """
                    \(count) categories is more than the \(Limits.maximumCategories) a chart \
                    holds. Aggregate the tail, or show the top ones and say what was left out.
                    """
            case .tooManyMarks(let count):
                return """
                    \(count) bars or points is more than the \(Limits.maximumMarks) this panel \
                    renders. Reduce the series or the categories.
                    """
            case .lengthMismatch(let series, let values, let categories):
                return """
                    Series "\(series)" has \(values) values but there are \(categories) \
                    categories. Every series plots one value per category, in the same order.
                    """
            case .nonFiniteValue(let series):
                return "Series \"\(series)\" contains a value that is not a finite number."
            case .negativeStackedValue(let series):
                return """
                    Series "\(series)" contains a negative value, which cannot be stacked: a \
                    stacked bar's height is the total of its parts. Use stacked: false.
                    """
            }
        }
    }

    // MARK: - Properties

    var title: String
    var summary: String?
    let kind: Kind
    let categories: [String]
    var series: [Series]
    var stacked: Bool
    var valueFormat: ValueFormat
    /// A short suffix such as `ms`, `MB` or `req/s`. Threading appends it to every axis tick and
    /// value label, so a comparison says what it is measuring without a title that repeats it.
    var unit: String?
    /// Pins the top of the value axis, so two charts of the same thing can be read against each
    /// other. Left open, the axis fits the data.
    var maximumValue: Double?

    // MARK: - Validation

    /// Fails loudly and specifically, because the caller is a model that can fix its own call.
    /// A silently truncated chart is worse than an error: it is a wrong picture with no warning.
    func validated() throws -> ChartSpec {
        guard !series.isEmpty else { throw Failure.noSeries }
        guard !categories.isEmpty else { throw Failure.noCategories }
        guard series.count <= Limits.maximumSeries else {
            throw Failure.tooManySeries(series.count)
        }
        guard categories.count <= Limits.maximumCategories else {
            throw Failure.tooManyCategories(categories.count)
        }
        let marks = series.count * categories.count
        guard marks <= Limits.maximumMarks else { throw Failure.tooManyMarks(marks) }

        for entry in series {
            guard entry.values.count == categories.count else {
                throw Failure.lengthMismatch(
                    series: entry.name,
                    values: entry.values.count,
                    categories: categories.count
                )
            }
            guard entry.values.allSatisfy(\.isFinite) else {
                throw Failure.nonFiniteValue(series: entry.name)
            }
            if stacked, entry.values.contains(where: { $0 < 0 }) {
                throw Failure.negativeStackedValue(series: entry.name)
            }
        }
        return self
    }

    // MARK: - Derived

    var isStacked: Bool { stacked && series.count > 1 && kind.drawsBars }

    /// The chart as tab-separated text.
    ///
    /// A picture of numbers the reader cannot get the numbers back out of is a dead end — this
    /// is what Copy has to mean here, and it pastes straight into a spreadsheet or a message.
    var tabSeparatedValues: String {
        var rows = [(["", ] + series.map(\.name)).joined(separator: "\t")]
        for (index, category) in categories.enumerated() {
            let values = series.map { entry -> String in
                guard entry.values.indices.contains(index) else { return "" }
                return entry.values[index].formatted(.number.precision(.fractionLength(0...4)))
            }
            rows.append(([category] + values).joined(separator: "\t"))
        }
        return rows.joined(separator: "\n")
    }

    /// A stable fingerprint of the numbers, for deciding whether a panel actually changed.
    ///
    /// FNV-1a rather than `hashValue`, which Swift seeds per process: a launch-varying digest
    /// would report every restored chart as new and re-brief the agent about a panel nobody
    /// touched.
    var fingerprint: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (title + "\u{0}" + tabSeparatedValues).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    /// What the tool reports back, and what the pane tab shows under its title. An agent that
    /// cannot see the panel still learns what landed in it.
    var subtitle: String {
        let categoryCount = "\(categories.count) \(categories.count == 1 ? "category" : "categories")"
        let seriesCount = "\(series.count) \(series.count == 1 ? "series" : "series")"
        return [seriesCount, categoryCount].joined(separator: " · ")
    }
}

extension ChartSpec.Kind {
    var drawsBars: Bool {
        switch self {
        case .bar, .ranking: return true
        case .line, .area: return false
        }
    }
}

// MARK: - Reading a chart back out of a tool call

extension ChartSpec {

    /// The chart a `display_chart` call describes, or nil for any other tool.
    ///
    /// A natively rendered conversation sees the same call the panel does, as the arguments the
    /// agent sent. Decoding here — rather than waiting for the tool's textual result — is what
    /// lets the transcript draw the chart itself instead of a line saying a chart was drawn
    /// somewhere else. Anything malformed returns nil and stays an ordinary tool row: the panel
    /// is the surface that refuses a bad call, and the transcript must not refuse it twice.
    static func decoded(fromToolNamed name: String, input: [String: Any]) -> ChartSpec? {
        guard name == MCPDefaults.allowedToolName(MCPBuiltInTool.displayChart.rawValue)
            || name == MCPBuiltInTool.displayChart.rawValue
        else { return nil }

        // `series` stays all-or-nothing, and the `count` check further down already says so out
        // loud: a chart drawn from some of its series is not a smaller chart, it is a different
        // chart, and the axis, the legend and the comparison the agent was making all change
        // around the missing one with nothing on the picture to admit it. An element that is not
        // an object costs the whole spec exactly as an unreadable `name` or `values` does, and
        // the call stays an ordinary tool row showing the arguments as sent.
        guard let title = input["title"] as? String, !title.isEmpty,
              let categories = input["categories"] as? [String],
              let rawSeries = input["series"] as? [[String: Any]]
        else { return nil }

        let series: [Series] = rawSeries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            // Numbers arrive as `NSNumber` through the JSON bridge, so `as? [Double]` fails on
            // any array holding an integer literal — which every honest count is.
            guard let values = (entry["values"] as? [NSNumber])?.map(\.doubleValue) else {
                return nil
            }
            return Series(
                name: name,
                values: values,
                details: entry["details"] as? [String],
                emphasis: (entry["emphasis"] as? String).flatMap(Emphasis.init(rawValue:))
            )
        }
        guard series.count == rawSeries.count else { return nil }

        let spec = ChartSpec(
            title: title,
            summary: input["summary"] as? String,
            kind: (input["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .bar,
            categories: categories,
            series: series,
            stacked: input["stacked"] as? Bool ?? false,
            valueFormat: (input["value_format"] as? String)
                .flatMap(ValueFormat.init(rawValue:)) ?? .number,
            unit: input["unit"] as? String,
            maximumValue: (input["maximum_value"] as? NSNumber)?.doubleValue
        )
        return try? spec.validated()
    }
}
