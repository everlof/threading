import AppKit

/// The app-owned geometry around an opening greeting. Themes may replace its content.
enum ComposerWelcomeLayout {
    static let markSide: CGFloat = 40
    static let minimumClearance: CGFloat = 48
    static let maximumLines = 3
    static var measure: CGFloat { Design.Size.readableWidth }
}

/// The mark, greeting and optional caption share one stack on both platforms. Hosts supply
/// their theme-aware mark and text leaves, then place this stack in the opening hero region.
@MainActor
final class ComposerWelcomeStackView: NSStackView {
    init(mark: NSView, greeting: NSView, caption: NSView? = nil) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = Design.Spacing.inset
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(mark)
        addArrangedSubview(greeting)
        if let caption {
            addArrangedSubview(caption)
            setCustomSpacing(Design.Spacing.small, after: greeting)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func exceedsHeroRegion(height: CGFloat) -> Bool {
        height < fittingSize.height + ComposerWelcomeLayout.minimumClearance
    }
}

#if os(Linux)
/// Static house-theme welcome, using the same mark and greeting policy as the Mac composer.
/// A single bounded label retains its text metrics between input/presentation callbacks.
final class ComposerWelcomeView: NSView, ThemedComponent {
    private let mark = ThreadingMarkView()
    private let greeting = NSTextField(wrappingLabelWithString: "")
    private lazy var stack = ComposerWelcomeStackView(mark: mark, greeting: greeting)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        greeting.applyFont(.welcomeGreeting)
        greeting.textColor = Design.Text.label
        greeting.alignment = .center
        greeting.maximumNumberOfLines = ComposerWelcomeLayout.maximumLines
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
        isHidden = stack.exceedsHeroRegion(height: bounds.height)
    }
}
#endif
