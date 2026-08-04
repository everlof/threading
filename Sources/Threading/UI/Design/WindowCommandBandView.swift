import AppKit

/// The command row directly below an app-drawn title bar.
///
/// A native toolbar disappears while a chrome theme owns the frame, but its application
/// commands do not become title-bar furniture as a consequence. Classic desktop chrome makes
/// that distinction especially visible: the title band contains only window identity and
/// caption buttons; navigation lives on the button-face row below it. This component preserves
/// that structure for every takeover theme and gives those controls the ordinary chrome ink
/// they sit on.
final class WindowCommandBandView: NSView, ThemedComponent {

    static let bandHeight = Design.Size.toolbarButtonHeight + Design.Spacing.hairline

    private let leadingStack = NSStackView()
    private let separator = SeparatorView()
    private var themeRedraw: ThemeRedraw?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = Design.Spacing.tight
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingStack)
        addSubview(separator)

        NSLayoutConstraint.activate([
            leadingStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.tight
            ),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLeadingControls(_ views: [NSView]) {
        leadingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(leadingStack.addArrangedSubview)
    }

    override func draw(_ dirtyRect: NSRect) {
        ThemedSurface.draw(
            bounds,
            fill: Design.Surface.background,
            radius: 0,
            bevel: .none
        )
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}
