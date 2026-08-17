import AppKit

/// A centred, theme-owned title whose authored line breaks are part of its meaning.
///
/// `MorphingTitleLabel` is deliberately single-line because its animation engine lays out one
/// glyph run. Passing newlines to it collapses those separators to zero-width glyphs and joins
/// the lines together. This companion keeps multiline copy on the ordinary text layout path
/// while exposing the same small title-label contract to feature surfaces.
final class ThemedMultilineTitleLabel: NSView, ThemedComponent {
    private let label = NSTextField(wrappingLabelWithString: "")

    var stringValue: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            setAccessibilityLabel(newValue.replacingOccurrences(of: "\n", with: ". "))
            invalidateIntrinsicContentSize()
        }
    }

    var alignment: NSTextAlignment {
        get { label.alignment }
        set { label.alignment = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = Design.Text.label
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { label.intrinsicContentSize }

    func applyFont(_ role: Design.FontRole) {
        label.applyFont(role)
        invalidateIntrinsicContentSize()
    }
}
