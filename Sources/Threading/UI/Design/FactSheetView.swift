import AppKit

/// A spec sheet of labelled facts: quiet trailing labels against leading readings, so the
/// readings line up as one column to read down rather than as a ragged list of `Key: value`
/// lines. A fact may carry a second, quieter line under its reading (a folder under a project
/// name, the login directory under an account), and a caution tone for a reading the person
/// should not skim past, such as a run falling back to a login nobody chose.
///
/// About's build details are the same shape; this is the component a second sheet needed so the
/// column measure, baseline alignment and wrapping are stated once.
@MainActor
final class FactSheetView: NSView {
    struct Fact: Equatable {
        enum Tone: Equatable { case normal, caution }

        let label: String
        let value: String
        var detail: String?
        var tone: Tone = .normal
        /// Stable identifier for tests and accessibility queries; never shown.
        var identifier: String?
    }

    let facts: [Fact]

    /// `width` is the sheet's whole measure; the reading column wraps inside what the label
    /// column leaves of it.
    init(facts: [Fact], width: CGFloat) {
        self.facts = facts
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let labels = facts.map(Self.makeLabel)
        let labelWidth = ceil(labels.map(\.fittingSize.width).max() ?? 0)
        let readingWidth = max(1, width - labelWidth - Design.Spacing.medium)

        let rows: [[NSView]] = zip(facts, labels).map { fact, label in
            [label, Self.makeReading(fact, width: readingWidth)]
        }
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Design.Spacing.small
        grid.columnSpacing = Design.Spacing.medium
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = labelWidth
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).width = readingWidth
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            widthAnchor.constraint(equalToConstant: width),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeLabel(_ fact: Fact) -> NSTextField {
        let label = NSTextField(labelWithString: fact.label)
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.alignment = .right
        return label
    }

    private static func makeReading(_ fact: Fact, width: CGFloat) -> NSView {
        let value = NSTextField(wrappingLabelWithString: fact.value)
        value.applyFont(.body)
        value.textColor = Design.Text.label
        value.isSelectable = true
        value.preferredMaxLayoutWidth = width
        value.setAccessibilityLabel(fact.label)
        if let identifier = fact.identifier { value.setAccessibilityIdentifier("fact.\(identifier)") }

        var views: [NSView] = [value]
        if let detail = fact.detail {
            let line = NSTextField(wrappingLabelWithString: detail)
            line.applyFont(.detail())
            line.textColor = fact.tone == .caution ? Design.Status.warning : Design.Text.secondary
            line.isSelectable = true
            line.preferredMaxLayoutWidth = width
            if let identifier = fact.identifier {
                line.setAccessibilityIdentifier("fact.\(identifier).detail")
            }
            views.append(line)
        }
        let stack = BaselineStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        return stack
    }
}

/// A reading and its detail line align with their label by the reading's first baseline, which
/// a plain stack does not report.
private final class BaselineStackView: NSStackView {
    override var firstBaselineOffsetFromTop: CGFloat {
        arrangedSubviews.first?.firstBaselineOffsetFromTop ?? super.firstBaselineOffsetFromTop
    }
}
