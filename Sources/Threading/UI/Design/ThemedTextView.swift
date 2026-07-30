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

    /// The text network's root, when this view built one for itself.
    ///
    /// Ownership in TextKit 1 runs storage → layout manager → container, and the view holds
    /// only the container — so without this the whole network would be released the moment
    /// the initializer returned.
    private let ownedTextStorage: NSTextStorage?

    /// **A nil container is not "the default container".** `init(frame:textContainer:)` is the
    /// designated initializer, and passing nil leaves the view outside any text network at
    /// all: no storage, no layout manager, no container. Such a view still draws, still takes
    /// focus and still shows a focus ring — and silently discards every keystroke, refuses
    /// every selection, and reports a nil `layoutManager` to anything sizing itself to the
    /// text. `NSTextView()` builds the network; this initializer did not, which is how the
    /// composer's prompt became an inert box that looked focused.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container {
            ownedTextStorage = nil
            super.init(frame: frameRect, textContainer: container)
        } else {
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)

            // The same shape `NSTextView.init(frame:)` gives its own container: as wide as the
            // view, unbounded downward, and following the view's width.
            let container = NSTextContainer(
                size: NSSize(width: frameRect.width, height: .greatestFiniteMagnitude)
            )
            container.widthTracksTextView = true
            layoutManager.addTextContainer(container)

            ownedTextStorage = storage
            super.init(frame: frameRect, textContainer: container)
        }
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

        // **`isVerticallyResizable` alone does not let a text view grow.** `minSize` and `maxSize`
        // default to the *initializer's* frame — `.zero` for every view built here — and the
        // scroll view then hands the document view the clip's size, which becomes the cap. The
        // frame therefore stops at exactly the visible height while layout runs on past it:
        // `documentRect` equals the clip, so the scroll view has no range, the wheel is
        // constrained to zero, the scroller never appears, and `scrollRangeToVisible` cannot
        // reach the caret. Measured on the session composer at 480pt of text in a 154pt box.
        //
        // The symptom is not "the box won't grow" — a box measuring its own text through the
        // layout manager grows correctly, which is what hid this. It is that everything past the
        // growth cap is drawn where nothing can scroll to it: text kept arriving under the
        // bottom edge and the person typing could not read their own prompt.
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
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
