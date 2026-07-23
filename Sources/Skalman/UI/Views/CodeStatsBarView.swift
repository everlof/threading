import AppKit

// MARK: - Code Stats Bar View

/// Draws a `CodeStatsBar` as one capsule of colour-run segments — the composition of a
/// project's code, largest language first.
///
/// Colours come from `Design.Categorical.ramp`: languages are things told *apart*, not things
/// with a meaning each. The "Other" fold draws in the quaternary text tone — present, muted,
/// visibly not a language of its own. Drawn in `draw(_:)` so a theme or appearance change
/// re-resolves every colour (`ThemeRedraw`).
final class CodeStatsBarView: NSView {

    // MARK: - Properties

    private let bar: CodeStatsBar
    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    init(bar: CodeStatsBar) {
        self.bar = bar
        super.init(frame: .zero)
        themeRedraw = ThemeRedraw(self)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilitySummary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CodeStatsBarDefaults.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !bar.isEmpty, bounds.width > 0 else { return }

        NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        ).addClip()

        let widths = bar.widths(
            totalWidth: bounds.width,
            gap: CodeStatsBarDefaults.segmentGap,
            minimumWidth: CodeStatsBarDefaults.minimumSegmentWidth
        )

        var x: CGFloat = 0
        for (segment, width) in zip(bar.segments, widths) {
            Self.color(for: segment).setFill()
            NSRect(x: x, y: 0, width: width, height: bounds.height).fill()
            x += width + CodeStatsBarDefaults.segmentGap
        }
    }

    /// The legend uses the same resolution, so a dot and its segment cannot disagree.
    static func color(for segment: CodeStatsBar.Segment) -> NSColor {
        guard let index = segment.colorIndex else { return Design.Text.quaternary }
        return Design.Categorical.ramp[index % Design.Categorical.ramp.count]
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        bar.segments
            .map { "\($0.name) \(Int(($0.fraction * 100).rounded()))%" }
            .joined(separator: ", ")
    }
}
