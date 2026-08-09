import AppKit

// MARK: - Presentation

extension ChartSpec {

    /// The chart contract the design system already speaks.
    ///
    /// Nothing here decides an appearance: the mapping chooses marks and words, and every colour,
    /// tick, corner and font is resolved later by the view against the live theme. That is what
    /// keeps an agent's chart and the Usage dashboard's chart the same object in two places.
    var themedModel: ThemedChartModel {
        let hasMeaning = series.contains { ($0.emphasis ?? .neutral) != .neutral }
        let marks: [ThemedChartSeries] = series.enumerated().map { index, entry in
            let style = Self.style(for: entry, at: index, meaningful: hasMeaning)
            if kind.drawsBars {
                return ThemedChartSeries(
                    id: "\(index)",
                    title: entry.name,
                    values: entry.values,
                    categories: categories,
                    details: entry.details ?? [],
                    style: style
                )
            }
            return ThemedChartSeries(
                id: "\(index)",
                title: entry.name,
                points: entry.values.enumerated().map { position, value in
                    ThemedChartPoint(
                        at: ThemedChartModel.categoryPosition(position),
                        value: value,
                        label: position < categories.count ? categories[position] : nil,
                        detail: (entry.details?.indices.contains(position) ?? false)
                            ? entry.details?[position]
                            : nil
                    )
                },
                style: style,
                fillsArea: kind == .area
            )
        }

        return ThemedChartModel.categorical(
            title: title,
            accessibilitySummary: summary ?? accessibilityNarration,
            categories: categories,
            series: marks,
            orientation: kind == .ranking ? .horizontal : .vertical,
            valueFormat: resolvedValueFormat,
            yRange: 0...(maximumValue ?? Self.axisCeiling(for: self))
        )
    }

    /// A top for the value axis that produces ticks a reader can do arithmetic with.
    ///
    /// Fitting the axis to the data gives a true chart with an unreadable scale — 73.4 ms and
    /// 55.1 ms are correct and tell nobody anything. The grid draws a fixed number of rules, so
    /// the ceiling is rounded up to a multiple of a *nice* step: the ticks then land on whole
    /// numbers and two charts of the same measurement can be compared by eye.
    static func axisCeiling(for spec: ChartSpec) -> Double {
        let peak: Double
        if spec.isStacked {
            peak = (0..<spec.categories.count).reduce(0.0) { highest, index in
                let total = spec.series.reduce(0.0) { running, entry in
                    running + max(0, entry.values.indices.contains(index) ? entry.values[index] : 0)
                }
                return max(highest, total)
            }
        } else {
            peak = spec.series.flatMap(\.values).filter(\.isFinite).max() ?? 0
        }
        guard peak > 0 else { return 1 }

        let intervals = Double(Design.Chart.gridLineCount - 1)
        let rough = peak / intervals
        let magnitude = pow(10, (log10(rough)).rounded(.down))
        // Steps whose four multiples all stay short. The ladder is deliberately fine: with only
        // 1, 2, 5 and 10 on it, a peak of 107 rounds up to a ceiling of 160 and the tallest bar
        // in the chart reaches two thirds of the plot with the rest left empty.
        let step = [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]
            .first { rough <= $0 * magnitude }
            .map { $0 * magnitude } ?? 10 * magnitude
        return step * intervals
    }

    var resolvedValueFormat: ThemedChartValueFormat {
        if let unit, !unit.isEmpty, valueFormat == .number { return .unit(unit) }
        switch valueFormat {
        case .number: return .number
        case .percent: return .percent
        case .currency: return .currency
        case .tokens: return .tokens
        }
    }

    /// What VoiceOver says about the chart as a whole when the caller supplied no summary.
    ///
    /// A chart with no words is a picture screen readers cannot enter, and asking every caller to
    /// remember one produces "chart" — so the fallback states the shape of the comparison, which
    /// is derivable and always true.
    private var accessibilityNarration: String {
        let names = series.map(\.name).filter { !$0.isEmpty }
        let plotted = names.isEmpty ? subtitle : names.joined(separator: ", ")
        return L10n.format(
            "%@ across %lld categories: %@",
            title,
            Int64(categories.count),
            plotted
        )
    }

    private static func style(
        for entry: Series,
        at index: Int,
        meaningful: Bool
    ) -> ThemedChartSeriesStyle {
        switch entry.emphasis ?? .neutral {
        case .positive: return .positive
        case .warning: return .warning
        case .negative: return .negative
        case .neutral:
            // A chart that names *one* series good or bad has said something about the others by
            // implication, so they stay quiet rather than joining the categorical carnival.
            return meaningful ? .primary : .categorical(index)
        }
    }
}

// MARK: - View

/// One agent-produced chart, titled, at the size the surface holding it allows.
///
/// The same card serves the display panel and an inline conversation row, which is the point: a
/// chart the user scrolled past and a chart they opened in the panel must not be two different
/// pictures. It owns no data of its own — the spec is the truth, and re-applying one re-animates
/// the existing chart rather than rebuilding the subtree.
@MainActor
final class ChartCardView: NSView, ThemedComponent {

    private enum Layout {
        static let titleSpacing = Design.Spacing.small
    }

    private(set) var spec: ChartSpec
    private let titleLabel: NSTextField
    private var chart: ThemedTimeSeriesChartView

    var chartForTesting: ThemedTimeSeriesChartView { chart }

    /// The height this card wants for a given width, which is what a virtualized row must be able
    /// to answer *before* the view exists.
    static func preferredHeight(for spec: ChartSpec) -> CGFloat {
        // A ranking grows with its rows — a chart of twenty tests in the height of a chart of
        // three is a smear — but only up to a bound: past it the bands compress and the axis
        // thins its labels, which is a chart that is hard to read rather than a row that is
        // impossible to scroll past.
        let bars = spec.kind == .ranking
            ? CGFloat(spec.categories.count) * Design.Chart.rankingRowHeight
            : 0
        let plot = min(
            max(Design.Chart.preferredHeight, bars),
            Design.Chart.maximumCardHeight
        )
        return plot + Design.Typography.heading().boundingRectForFont.height + Layout.titleSpacing
    }

    init(spec: ChartSpec) {
        self.spec = spec
        titleLabel = NSTextField.label(attributed: Self.titleText(spec))
        chart = Self.makeChart(for: spec)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(spec.title)
        setAccessibilityIdentifier("chart-card")

        addSubview(titleLabel)
        addSubview(chart)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            chart.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: Layout.titleSpacing
            ),
            chart.leadingAnchor.constraint(equalTo: leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor),
            chart.bottomAnchor.constraint(equalTo: bottomAnchor),
            chart.heightAnchor.constraint(
                greaterThanOrEqualToConstant: Design.Chart.minimumCardHeight
            )
        ])
        chart.setModel(spec.themedModel, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Applies a new spec, animating when the chart can morph into it.
    ///
    /// Only a change of composition rebuilds the chart view: stacked and grouped are different
    /// classes, and a stacked total cannot be interpolated from independent heights without
    /// drawing a frame that never described any data.
    func setSpec(_ newSpec: ChartSpec, animated: Bool = true) {
        let rebuilds = newSpec.isStacked != spec.isStacked
        spec = newSpec
        titleLabel.attributedStringValue = Self.titleText(newSpec)
        setAccessibilityLabel(newSpec.title)

        if rebuilds {
            let replacement = Self.makeChart(for: newSpec)
            replacement.frame = chart.frame
            chart.removeFromSuperview()
            chart = replacement
            addSubview(replacement)
            NSLayoutConstraint.activate([
                replacement.topAnchor.constraint(
                    equalTo: titleLabel.bottomAnchor,
                    constant: Layout.titleSpacing
                ),
                replacement.leadingAnchor.constraint(equalTo: leadingAnchor),
                replacement.trailingAnchor.constraint(equalTo: trailingAnchor),
                replacement.bottomAnchor.constraint(equalTo: bottomAnchor),
                replacement.heightAnchor.constraint(
                    greaterThanOrEqualToConstant: Design.Chart.minimumCardHeight
                )
            ])
        }
        chart.setModel(newSpec.themedModel, animated: animated && !rebuilds)
    }

    func applyTheme() {
        titleLabel.attributedStringValue = Self.titleText(spec)
    }

    private static func makeChart(for spec: ChartSpec) -> ThemedTimeSeriesChartView {
        let chart: ThemedTimeSeriesChartView = spec.isStacked
            ? ThemedStackedBandChartView(frame: .zero)
            : ThemedTimeSeriesChartView(frame: .zero)
        // The chart is laid out by this card's constraints, not by an autoresizing mask. Left
        // on the mask it keeps the zero frame it was built with, its constraints are ignored,
        // and the card draws its title over an empty rectangle — which every assertion here
        // passed through happily until the storybook was looked at.
        chart.translatesAutoresizingMaskIntoConstraints = false
        return chart
    }

    private static func titleText(_ spec: ChartSpec) -> NSAttributedString {
        NSAttributedString(
            string: spec.title,
            attributes: [
                .font: Design.Typography.heading(),
                .foregroundColor: Design.Text.label
            ]
        )
    }
}
