import AppKit

// MARK: - Themed Bar Sparkline

/// A compact, axis-free bar series for supplemental trends inside cards and rows.
///
/// The caller supplies one accessible sentence because a tiny chart has no room for labels. The
/// full chart remains the right component when axes, values, focus, or tooltips are the content.
@MainActor
final class ThemedBarSparklineView: NSView, ThemedComponent {
    private var values: [Double]
    private var themeRedraw: ThemeRedraw?

    init(values: [Double], accessibilityLabel: String) {
        self.values = values.map { $0.isFinite ? max(0, $0) : 0 }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityLabel)
    }

    /// Replaces the fixed-size series without replacing the view. Cards with retained identity
    /// can therefore refresh their cached aggregate in place.
    func setValues(_ values: [Double], accessibilityLabel: String) {
        self.values = values.map { $0.isFinite ? max(0, $0) : 0 }
        setAccessibilityLabel(accessibilityLabel)
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Layout.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        let count = CGFloat(values.count)
        let totalGap = Layout.gap * max(0, count - 1)
        let width = max(1, (bounds.width - totalGap) / count)
        let peak = values.max() ?? 0
        let color = Design.Chart.color(for: .primary)

        for (index, value) in values.enumerated() {
            let fraction = peak > 0 ? CGFloat(value / peak) : 0
            let height = value > 0
                ? max(Layout.minimumActiveHeight, fraction * bounds.height)
                : Layout.zeroHeight
            let rect = NSRect(
                x: bounds.minX + CGFloat(index) * (width + Layout.gap),
                y: bounds.minY,
                width: width,
                height: min(height, bounds.height)
            )
            color.withAlphaComponent(value > 0 ? Layout.activeOpacity : Layout.zeroOpacity).setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: min(Layout.radius, width / 2),
                yRadius: min(Layout.radius, width / 2)
            ).fill()
        }
    }

    private enum Layout {
        static let height: CGFloat = 28
        static let gap: CGFloat = 3
        static let minimumActiveHeight: CGFloat = 3
        static let zeroHeight: CGFloat = 1
        static let radius: CGFloat = 1.5
        static let activeOpacity: CGFloat = 0.72
        static let zeroOpacity: CGFloat = 0.18
    }
}
