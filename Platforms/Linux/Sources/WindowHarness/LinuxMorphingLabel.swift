import AppKit

/// Pango glyph renderer behind the production MorphingTitleLabel wrapper.
/// Linux does not yet provide LabelMorph's Core Animation glyph transitions.
@MainActor
final class MorphingLabel: NSView {
    enum Truncation { case tail }

    private let textField = NSTextField(labelWithString: "")
    var text: String { textField.stringValue }
    var truncation: Truncation = .tail
    var rasterizationBackground: NSColor = .clear

    var font: NSFont {
        get { textField.font ?? NSFont.systemFont(ofSize: 13) }
        set {
            textField.font = newValue
            invalidateIntrinsicContentSize()
        }
    }

    var textColor: NSColor {
        get { textField.textColor ?? .black }
        set { textField.textColor = newValue }
    }

    var alignment: NSTextAlignment {
        get { textField.alignment }
        set { textField.alignment = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { textField.intrinsicContentSize }

    func setText(_ value: String, animated: Bool) {
        guard textField.stringValue != value else { return }
        textField.stringValue = value
        invalidateIntrinsicContentSize()
    }

    func width(fitting available: CGFloat) -> CGFloat {
        min(max(0, available), intrinsicContentSize.width)
    }

    func naturalWidth(of candidate: String) -> CGFloat {
        let previous = textField.stringValue
        textField.stringValue = candidate
        let width = textField.intrinsicContentSize.width
        textField.stringValue = previous
        return width
    }
}

public enum ChatNameMorphStyle: String {
    case automatic, shapeMorph, crossfade, slideUp, slideDown, scale, bounce, drop, flip, blur, scramble, typewriter
}

extension MorphingTitleLabel {
    enum FontRole { case control, controlRegular, emphasizedBody, caption, body }

    func applyFont(_ role: FontRole) {
        switch role {
        case .control: font = NSFont.systemFont(ofSize: 12, weight: .medium)
        case .controlRegular: font = Design.Typography.controlRegular()
        case .emphasizedBody: font = NSFont.systemFont(ofSize: SidebarRowDefaults.projectFontSize,
                                                      weight: .semibold)
        case .caption: font = NSFont.systemFont(ofSize: SidebarRowDefaults.headingFontSize,
                                               weight: .regular)
        case .body: font = Design.Typography.body()
        }
    }
}
