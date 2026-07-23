import AppKit

/// A text surface in the theme's colours, replacing `NSTextView`.
///
/// A stock text view is a white system page: `drawsBackground` on, text in a colour AppKit
/// chose, an insertion point in the system accent. On a themed pane every one of those is a
/// hole. This starts transparent, writes in the theme's label tier, and blinks the theme's
/// accent — and like `ThemedTextField`, it subclasses rather than redraws, because the field
/// editor machinery and text layout are not worth reimplementing to gain three colours.
class ThemedTextView: NSTextView, ThemedComponent {

    private var themeRedraw: ThemeRedraw?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        drawsBackground = false
        textColor = Design.Text.label
        insertionPointColor = Design.Surface.accent
        themeRedraw = ThemeRedraw(self)
    }

    /// The themed replacement for `NSTextView.scrollableTextView()`: a transparent scroll
    /// view around a width-tracking, vertically growing text view — the wiring every
    /// scrolling text pane needs and nobody should re-derive.
    static func scrolling() -> ThemedScrollView {
        let scrollView = ThemedScrollView(frame: .zero)
        let textView = ThemedTextView(frame: .zero, textContainer: nil)

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        return scrollView
    }
}
