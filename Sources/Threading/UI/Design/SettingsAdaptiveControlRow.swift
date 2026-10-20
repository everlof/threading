import AppKit

/// Shared readable-width floor for Settings rows on both desktop platforms.
enum SettingsAdaptiveControlMetrics {
    static let minimumTextWidth: CGFloat = 180
}

// MARK: - Adaptive Control Row

/// A row's words beside its control while both fit, and the control on a line of its own when
/// they do not.
///
/// Beside was the only arrangement, and a narrow pane paid for it in words: the control keeps its
/// width by contract, so a three-way choice or a sign-in button beside a sentence left the label
/// column a hundred points, the title truncated to "Keep this…" and the subtitle broke the
/// readable floor `fill` states, because the row's required edges outrank it. Remote Access's
/// Connection card in a 420-point pane showed both at once, and so did every page with a wide
/// control. `stackedControlRow` already had the right shape, but only as a choice a page makes
/// once for every width.
///
/// So the row chooses by its own width: beside while the label column keeps
/// `SettingsAdaptiveControlMetrics.minimumTextWidth` next to the control at its narrowest, and stacked —
/// words across the row, control trailing beneath them, the `stackedControlRow` shape — when it
/// cannot. The row's width comes from its card and not from its arrangement, so the choice cannot
/// feed back into itself, and a pane dragged wider puts the control back beside the words.
///
/// Structural only: it draws nothing and chooses no styling.
final class SettingsAdaptiveControlRow: NSView {
    private let labels: NSView
    private let control: NSView
    private let stack = NSStackView()
    private let labelsSpanTheRow: NSLayoutConstraint
    private(set) var isStacked = false

    init(labels: NSView, control: NSView) {
        self.labels = labels
        self.control = control
        labelsSpanTheRow = labels.widthAnchor.constraint(equalTo: stack.widthAnchor)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // `.gravityAreas` (the default) may leave unused room after the arranged views. That is
        // invisible with a long subtitle, whose fitting width happens to consume the row, but a
        // short title beside a fixed-width control clusters at the leading edge and wraps its
        // subtitle one word per line. `.fill` makes the low-hugging label column absorb the row's
        // slack and keeps the control on the trailing edge.
        stack.distribution = .fill
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(labels)
        stack.addArrangedSubview(control)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        arrange(stacked: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The narrowest this row can be with the control beside its words.
    var besideWidth: CGFloat {
        SettingsAdaptiveControlMetrics.minimumTextWidth + Design.Spacing.medium + Self.narrowestWidth(of: control)
    }

    override func layout() {
        // A row not yet given a width has nothing to decide with.
        if bounds.width > 0 {
            let stacked = bounds.width < besideWidth
            if stacked != isStacked {
                arrange(stacked: stacked)
                needsLayout = true
            }
        }
        super.layout()
    }

    /// Stacked, the words take the row and the control keeps the trailing edge every other row's
    /// control is on.
    ///
    /// The order matters. "The words span the row" beside a horizontal run that also holds a
    /// control is unsatisfiable, and `NSStackView` rebuilds its own constraints lazily, on its
    /// next constraint pass rather than when its orientation is set. So the span goes before the
    /// run turns horizontal, and comes only after the vertical run's constraints actually exist:
    /// activated straight after setting the orientation, it met the old horizontal ones and
    /// AppKit broke a constraint to recover, once per row per switch.
    private func arrange(stacked: Bool) {
        isStacked = stacked
        if stacked {
            stack.orientation = .vertical
            stack.alignment = .trailing
            stack.updateConstraintsForSubtreeIfNeeded()
            labelsSpanTheRow.isActive = true
        } else {
            labelsSpanTheRow.isActive = false
            stack.orientation = .horizontal
            stack.alignment = .centerY
        }
    }

    /// The width a control will not give up: what it draws, or a width it requires.
    ///
    /// Not `fittingSize` for a control that has an intrinsic width, because that honours the
    /// *preferred* measure `SettingsUI.preferControlWidth` states and would stack a row whose
    /// control is only wishing for 380 points — the wish is what a narrow pane is meant to take
    /// back first. A composite control, a stack, has no intrinsic width, and its fitting size is
    /// its members' own.
    static func narrowestWidth(of control: NSView) -> CGFloat {
        let intrinsic = control.intrinsicContentSize.width
        let drawn = intrinsic == NSView.noIntrinsicMetric ? control.fittingSize.width : intrinsic
        let required = control.constraints
            .filter {
                $0.firstItem === control && $0.firstAttribute == .width && $0.secondItem == nil
                    && $0.relation != .lessThanOrEqual && $0.priority == .required
            }
            .map(\.constant)
            .max() ?? 0
        return max(drawn, required)
    }
}
