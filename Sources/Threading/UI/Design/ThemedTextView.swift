import AppKit

/// A text surface in the theme's colours, replacing `NSTextView`.
///
/// A stock text view is a white system page: `drawsBackground` on, text in a colour AppKit
/// chose, an insertion point in the system accent. On a themed pane every one of those is a
/// hole. This starts transparent, writes in the theme's label tier, and blinks the theme's
/// accent — and like `ThemedTextField`, it subclasses rather than redraws, because the field
/// editor machinery and text layout are not worth reimplementing to gain three colours.
/// What a run of *selected text* is painted with, wherever text is edited.
///
/// The fourth colour in a text view, and the one that stayed AppKit's: `selectedTextAttributes`
/// defaults to `selectedTextBackgroundColor`, so dragging across a prompt in a lavender window
/// highlighted it in system blue-grey. Exactly the defect the attachments row had — a framework
/// default standing in for a decision nobody made, invisible to a lint because no call site
/// mentions it — found while hardening against that one, and fixed the same way: stated once, in
/// the component, where no caller has to remember.
///
/// The ground is the theme's `selection` role, the same one a selected list row fills with, so a
/// selection reads as one idea across the window. The foreground is stated too rather than left to
/// `selectedTextColor`, which is a system near-white and would disappear into a light theme's
/// selection ground.
///
/// **Stating it was not enough; it had to be stated against the right thing.** The foreground was
/// `Design.Text.label` — the ink for the *chrome's* ground, not for the fill this paints — so under
/// Windows 98 a selected run came out near-black on a 90%-opaque navy at 1.47:1, and the drag that
/// selected it appeared to erase the text. Text is the case that *can* state both, so it takes
/// `SelectionSurface.stated`: the theme's own fill, and the ink measured against it. The result
/// inverts on its own — white on Windows 98's navy, the ordinary near-black on Christmas's wash.
///
/// **Readable ink was not the whole promise either.** A highlight is a highlight only if it can be
/// seen. Pure's night `#292929` — right for a row over a black sidebar — stood ΔE 11.9 from the
/// browser address field's `#101010` well, so a URL selected in a focused field kept perfectly
/// legible white text on a grey the eye could hardly separate from the field. Text therefore takes
/// `SelectionSurface.distinct`, which raises a selection standing too close to its ground; and a
/// field's selection is measured over the **well the field paints**, which `resolvedGround()`
/// cannot see because the well is drawn rather than recorded.
///
/// Dynamic colours, so a live theme switch is answered at the next draw — the attributes
/// dictionary is set once and never rebuilt. The **ground** is dynamic for the same reason and is
/// therefore passed as a closure: what a text view sits on moves with the theme too.
@MainActor
public enum ThemedTextSelection {

    /// `host` is what the selection is painted over. Weakly held: these attributes outlive nothing,
    /// but they are read by TextKit at arbitrary later moments and a strong capture would make a
    /// text view own itself.
    public static func attributes(over host: NSView?) -> [NSAttributedString.Key: Any] {
        let selection = SelectionSurface.dynamic { [weak host] in
            ground(under: host)
        }
        return [
            .backgroundColor: selection.fill,
            .foregroundColor: selection.ink.label
        ]
    }

    /// What a selection inside `host` is painted over. A themed field draws its well in `draw(_:)`
    /// rather than recording it, so it answers for itself; anything else is measured.
    private static func ground(under host: NSView?) -> NSColor {
        if let field = host as? ThemedTextField {
            return field.textSelectionGround()
        }
        return host?.resolvedGround() ?? Design.Surface.ground
    }

    /// The same statement for a field editor — the `NSTextView` AppKit lends an `NSTextField`
    /// while it is being edited. It is created by the framework, shared between fields and never
    /// constructed here, so it can only be told at the moment it is handed over.
    ///
    /// The **field** is the ground, not the editor: the editor is lent, re-parented and reused, so
    /// a ground read through it answers for whichever field borrowed it last.
    public static func apply(to editor: NSText, in field: NSView?) {
        guard let editor = editor as? NSTextView else { return }
        editor.selectedTextAttributes = attributes(over: field)
        editor.insertionPointColor = Design.Surface.accent
    }
}

public class ThemedTextView: NSTextView, ThemedComponent {

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
    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
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
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        drawsBackground = false
        textColor = Design.Text.label
        insertionPointColor = Design.Surface.accent
        selectedTextAttributes = ThemedTextSelection.attributes(over: self)
        themeRedraw = ThemeRedraw(self)

        // NSTextView is editable by default but, surprisingly, does not record edits with an
        // undo manager by default. That leaves the application's ordinary Edit ▸ Undo command
        // correctly routed to this view with no operation to perform. User-authored text is the
        // default for this component (prompt drafts and longer form fields), so undo belongs at
        // the same boundary; read-only specializations can still opt out after initialization.
        allowsUndo = true

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
    public static func scrolling() -> ThemedTextScrollView { ThemedTextScrollView() }
}

/// A scrolling text surface whose document type remains visible to the compiler.
///
/// Returning a plain scroll view forced every caller to rediscover the factory invariant with
/// `documentView as? ThemedTextView`—and two important editors used `as!`. The composite owns the
/// invariant instead: replacing its document view remains possible through AppKit, but code built
/// by this factory never needs a runtime cast to reach the text view it created.
public final class ThemedTextScrollView: ThemedScrollView {
    public let textView: ThemedTextView

    public init() {
        textView = ThemedTextView(frame: .zero, textContainer: nil)
        super.init(frame: .zero)

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        documentView = textView
        hasVerticalScroller = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
