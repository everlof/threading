import AppKit

/// The app-owned geometry around an opening greeting. Themes may replace its content.
enum ComposerWelcomeLayout {
    static let markSide: CGFloat = 40
    static let minimumClearance: CGFloat = 48
    static let maximumLines = 3
    static var measure: CGFloat { Design.Size.readableWidth }
}

#if os(Linux)
/// Static house-theme welcome, using the same mark and greeting policy as the Mac composer.
/// A single bounded label retains its text metrics between input/presentation callbacks.
final class ComposerWelcomeView: NSView, ThemedComponent {
    private let mark = ThreadingMarkView()
    private let greeting = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        greeting.applyFont(.welcomeGreeting)
        greeting.textColor = Design.Text.label
        greeting.alignment = .center
        greeting.maximumNumberOfLines = ComposerWelcomeLayout.maximumLines
        addSubview(mark)
        addSubview(greeting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(greeting text: String) {
        if greeting.stringValue != text { greeting.stringValue = text }
    }

    var greetingBounds: NSRect { greeting.convert(greeting.bounds, to: superview) }

    func place(in region: NSRect) {
        frame = region
        let measure = min(ComposerWelcomeLayout.measure,
            max(1, region.width - 2 * Design.Spacing.pane))
        if greeting.preferredMaxLayoutWidth != measure { greeting.preferredMaxLayoutWidth = measure }
        let textHeight = greeting.intrinsicContentSize.height
        let side = ComposerWelcomeLayout.markSide
        let contentHeight = side + Design.Spacing.inset + textHeight
        isHidden = region.height < contentHeight + ComposerWelcomeLayout.minimumClearance
        let bottom = (region.height - contentHeight) / 2
        greeting.frame = NSRect(x: (region.width - measure) / 2, y: bottom,
            width: measure, height: textHeight)
        mark.frame = NSRect(x: (region.width - side) / 2,
            y: bottom + textHeight + Design.Spacing.inset, width: side, height: side)
    }
}
#endif
