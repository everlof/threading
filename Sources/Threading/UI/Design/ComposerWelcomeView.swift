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
    private lazy var stack = NSStackView(views: [mark, greeting])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        greeting.applyFont(.welcomeGreeting)
        greeting.textColor = Design.Text.label
        greeting.alignment = .center
        greeting.maximumNumberOfLines = ComposerWelcomeLayout.maximumLines
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Spacing.inset
        addSubview(stack)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: ComposerWelcomeLayout.markSide),
            mark.heightAnchor.constraint(equalToConstant: ComposerWelcomeLayout.markSide),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                           constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                            constant: -Design.Spacing.pane)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(greeting text: String) {
        if greeting.stringValue != text { greeting.stringValue = text }
    }

    var greetingBounds: NSRect { greeting.convert(greeting.bounds, to: superview) }

    func updateVisibility() {
        let measure = min(ComposerWelcomeLayout.measure,
            max(1, bounds.width - 2 * Design.Spacing.pane))
        if greeting.preferredMaxLayoutWidth != measure { greeting.preferredMaxLayoutWidth = measure }
        isHidden = bounds.height
            < stack.fittingSize.height + ComposerWelcomeLayout.minimumClearance
    }
}
#endif
