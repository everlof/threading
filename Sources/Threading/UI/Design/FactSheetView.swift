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

    /// The measure this sheet was given, or nil when it follows the width its host lays it out
    /// at.
    private let fixedWidth: CGFloat?
    private let labelWidth: CGFloat
    /// Every wrapping reading line, so a sheet that follows its host can re-measure them.
    private var readings: [NSTextField] = []
    private var readingWidth: CGFloat

    /// `width` is the sheet's whole measure; the reading column wraps inside what the label
    /// column leaves of it.
    convenience init(facts: [Fact], width: CGFloat) {
        self.init(facts: facts, fixedWidth: width)
    }

    /// A sheet as wide as the row it is placed in, its readings wrapping to whatever the label
    /// column leaves. For a page column that narrows with its pane: a sheet stating its own
    /// width there either overflows a narrow pane or leaves a wide one half used.
    convenience init(facts: [Fact]) {
        self.init(facts: facts, fixedWidth: nil)
    }

    private init(facts: [Fact], fixedWidth: CGFloat?) {
        self.facts = facts
        self.fixedWidth = fixedWidth
        let labels = facts.map(Self.makeLabel)
        labelWidth = ceil(labels.map(\.fittingSize.width).max() ?? 0)
        readingWidth = max(1, (fixedWidth ?? Design.Size.readableWidth) - labelWidth - Design.Spacing.medium)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let rows: [[NSView]] = zip(facts, labels).map { fact, label in
            [label, makeReading(fact)]
        }
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Design.Spacing.small
        grid.columnSpacing = Design.Spacing.medium
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = labelWidth
        grid.column(at: 1).xPlacement = .leading
        if fixedWidth != nil { grid.column(at: 1).width = readingWidth }
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        if let fixedWidth {
            widthAnchor.constraint(equalToConstant: fixedWidth).isActive = true
        }
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

    /// A sheet that follows its host re-wraps its readings at the column it was actually given.
    /// Changing the measure invalidates each reading's height, which brings layout back here
    /// once more with the same width, and the guard ends it.
    override func layout() {
        super.layout()
        guard fixedWidth == nil else { return }
        let available = max(1, bounds.width - labelWidth - Design.Spacing.medium)
        guard abs(available - readingWidth) >= 0.5 else { return }
        readingWidth = available
        for reading in readings { reading.preferredMaxLayoutWidth = available }
    }

    private func makeReading(_ fact: Fact) -> NSView {
        let value = NSTextField(wrappingLabelWithString: fact.value)
        value.applyFont(.body)
        value.textColor = Design.Text.label
        value.isSelectable = true
        value.preferredMaxLayoutWidth = readingWidth
        value.setAccessibilityLabel(fact.label)
        if let identifier = fact.identifier { value.setAccessibilityIdentifier("fact.\(identifier)") }
        readings.append(value)

        var views: [NSView] = [value]
        if let detail = fact.detail {
            let line = NSTextField(wrappingLabelWithString: detail)
            line.applyFont(.detail())
            line.textColor = fact.tone == .caution ? Design.Status.warning : Design.Text.secondary
            line.isSelectable = true
            line.preferredMaxLayoutWidth = readingWidth
            if let identifier = fact.identifier {
                line.setAccessibilityIdentifier("fact.\(identifier).detail")
            }
            readings.append(line)
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
