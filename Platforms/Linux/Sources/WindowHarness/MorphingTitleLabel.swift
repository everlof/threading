import AppKit

/// Linux's bounded Pango text leaf for the Apple-only LabelMorph wrapper. The shared page-title
/// component owns the title's geometry, hover, actions and accessibility; this leaf supplies
/// the single-line label API while glyph-layer morph animation is unavailable on Linux.
@MainActor
final class MorphingTitleLabel: NSView {
    enum FontRole { case control }

    private let textField = NSTextField(labelWithString: "")

    var stringValue: String { textField.stringValue }

    var font: NSFont? {
        get { textField.font }
        set {
            textField.font = newValue
            invalidateIntrinsicContentSize()
        }
    }

    var textColor: NSColor? {
        get { textField.textColor }
        set { textField.textColor = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        textField.setAccessibilityElement(false)
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { textField.intrinsicContentSize }

    func applyFont(_ role: FontRole) {
        switch role {
        case .control: font = NSFont.systemFont(ofSize: 12, weight: .medium)
        }
    }

    func setStringValue(_ value: String, animated: Bool) {
        guard textField.stringValue != value else { return }
        textField.stringValue = value
        setAccessibilityLabel(value)
        invalidateIntrinsicContentSize()
    }

    func width(fitting available: CGFloat) -> CGFloat {
        min(max(0, available), intrinsicContentSize.width)
    }
}
