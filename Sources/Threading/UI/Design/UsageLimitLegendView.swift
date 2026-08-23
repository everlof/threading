import AppKit

/// One key for the user-authored line in a group of usage bars.
///
/// The host places this once in its footer rather than repeating it under every window. The mark
/// and `UsageBarView` resolve through the same semantic role, so a live theme change cannot make
/// the key describe a colour the bars no longer use.
final class UsageLimitLegendView: NSView, ThemedComponent {
    private let title: String
    private var themeRedraw: ThemeRedraw?

    init(title: String = L10n.string("Your limit")) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle
        return NSSize(
            width: ceil(Design.UsageBar.limitMarkWidth + Design.UsageBar.legendGap
                + text.size().width),
            height: ceil(max(Design.UsageBar.legendMarkHeight, text.size().height))
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = attributedTitle
        let textSize = text.size()
        let markSize = NSSize(
            width: Design.UsageBar.limitMarkWidth,
            height: Design.UsageBar.legendMarkHeight
        )
        let mark = NSRect(
            x: 0,
            y: ((bounds.height - markSize.height) / 2).rounded(),
            width: markSize.width,
            height: markSize.height
        )
        Design.UsageBar.limitMarkColor.setFill()
        NSBezierPath(roundedRect: mark, xRadius: mark.width / 2, yRadius: mark.width / 2).fill()

        text.draw(at: NSPoint(
            x: mark.maxX + Design.UsageBar.legendGap,
            y: ((bounds.height - textSize.height) / 2).rounded()
        ))
    }

    private var attributedTitle: NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: Design.Typography.caption(),
                .foregroundColor: Design.Text.tertiary
            ]
        )
    }
}
