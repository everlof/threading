import AppKit

// MARK: - Usage Bar Row

/// A labelled row with a proportional bar behind its value — one checkout, one day, one model.
///
/// The bar is what makes a list of numbers comparable at a glance: "45.5M and 24.4M and 21.7M"
/// is arithmetic, while three bars of falling length is a shape. It is drawn relative to the
/// largest row rather than to the total, so the leader always fills the width and the rest read
/// against it — the question these rows answer is "which is biggest and by how much", not "what
/// share of everything".
final class UsageBarRow: NSView {

    // MARK: - Initialization

    init(title: String, detail: String?, value: String, fraction: Double) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.applyFont(.body)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.applyFont(.numericControl())
        valueLabel.textColor = Design.Text.secondary
        valueLabel.alignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let heading = NSStackView(views: [titleLabel, spacer(), valueLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = Design.Spacing.medium

        var rows: [NSView] = [heading, bar(fraction: fraction)]

        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.applyFont(.subheading)
            detailLabel.textColor = Design.Text.tertiary
            rows.insert(detailLabel, at: 1)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.medium),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.medium),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Private Methods

    /// The bar itself — `UsageBarView`, the same gauge the toolbar popover and the composer
    /// draw.
    ///
    /// It was a second implementation until this was written, and the duplicate was the *only*
    /// un-themed one: a track in `quaternaryLabelColor` and a fill in `controlAccentColor`, both
    /// frozen into a layer at construction. So the Usage page drew system-blue bars on a
    /// Cyberpunk-green card — the switch's bug exactly, one level down, and the reason the answer
    /// is always "share the themed component" rather than "fix the colour here".
    private func bar(fraction: Double) -> NSView {
        let bar = UsageBarView()
        // A floor keeps the smallest rows visible — a row whose bar rounds to nothing reads as a
        // rendering failure rather than as a small number.
        bar.fraction = max(min(fraction, 1), UsageBarRowDefaults.minimumFraction)
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}

// MARK: - Usage Bar Row Defaults

enum UsageBarRowDefaults {
    static let height: CGFloat = 4
    static let valueFontSize: CGFloat = 12

    /// Smallest visible fill, so a row that rounds to nothing still draws as a small number
    /// rather than as a missing bar.
    static let minimumFraction = 0.015
}
