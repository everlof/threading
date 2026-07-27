import AppKit

/// An editable field drawn from the theme, replacing a bezelled `NSTextField`.
///
/// The one themed control that is *not* a `ThemedControl`: a field needs `NSTextField`'s field
/// editor, formatter, delegate and the whole of text editing, none of which is worth
/// reimplementing to gain a drawn border. It subclasses `NSTextField`, turns its bezel off, and
/// draws the same surface every other themed control draws — so what changes is the chrome, and
/// nothing about editing.
///
/// A label is deliberately *not* this. `NSTextField(labelWithString:)` draws no bezel and no
/// background, so it is already nothing but text in a themed colour; the erosion this exists to
/// stop is the bezel, not the type.
class ThemedTextField: NSTextField, ThemedComponent, SystemChromeBoundary {

    // MARK: - Geometry

    fileprivate enum Layout {
        static let height: CGFloat = Design.Size.chipHeight
        /// Clear of the border, and roughly where a stock field puts its own text.
        static let inset: CGFloat = Design.Spacing.small + 2
    }

    // MARK: - State

    private var themeRedraw: ThemeRedraw?
    private let placeholderRefresh = AppEventObservations()

    /// The field editor is what actually becomes first responder, so "focused" is asked of the
    /// editor rather than tracked. Redraws are triggered by the two edges below.
    private var isEditing: Bool { currentEditor() != nil }

    // MARK: - Initialization

    /// Overridden so every `NSTextField` initializer — `init()`, `init(frame:)`, `init(string:)`
    /// — builds the inset-aware cell. Assigning `cell` afterwards would work too, and would drop
    /// whatever each initializer had already configured on the cell it made.
    override class var cellClass: AnyClass? {
        get { ThemedTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Declared rather than inherited. `NSTextField(string:)` imports a *class factory* method,
    /// which is free to hand back a plain `NSTextField` — a subclass would then be one only by
    /// the type annotation at the call site.
    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    private func setup() {
        isBezeled = false
        // The surface is ours; leaving AppKit's on would paint a system rectangle under it.
        drawsBackground = false
        // Likewise the focus ring: the system's is drawn outside the control's bounds and in the
        // system accent, which is the one colour a themed page has already replaced.
        focusRingType = .none
        applyFont(.body)
        textColor = Design.Text.label
        themeRedraw = ThemeRedraw(self)

        // The placeholder is a *built* attributed string, so its font and its ink both freeze
        // where the field's own would be re-resolved: `ThemeRedraw` marks the view dirty, and a
        // stored attributed string does not care. Rebuilding it is the whole fix, and it has to
        // run after the sweep has had the field's font, which is why it is its own observation
        // rather than a line inside `applyPlaceholderColour`'s only current caller.
        placeholderRefresh.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyPlaceholderColour()
        }
    }

    /// On recent AppKit releases an on-screen text field expands into a private clip view and
    /// text view. They are the field editor that preserves selection, input methods and undo—not
    /// application chrome. Permit only that exact direct hierarchy; a text view elsewhere under
    /// the component is still a violation.
    func permitsSystemChrome(_ view: NSView) -> Bool {
        if let clip = view as? NSClipView {
            return clip.superview === self
        }
        if view is NSTextView, let clip = view.superview as? NSClipView {
            return clip.superview === self
        }
        return false
    }

    // MARK: - Placeholder

    /// Restated in the theme's own tertiary label, because AppKit's placeholder is drawn in a
    /// *system* grey that a styled page has already moved away from.
    override var placeholderString: String? {
        didSet { applyPlaceholderColour() }
    }

    private func applyPlaceholderColour() {
        guard let placeholderString else { return }
        placeholderAttributedString = NSAttributedString(
            string: placeholderString,
            attributes: [.font: font ?? Design.Typography.body(), .foregroundColor: Design.Text.tertiary]
        )
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = max(size.height, Layout.height)
        return size
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        needsDisplay = true
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawSurface()
        super.draw(dirtyRect)
    }

    /// The leading edge the text begins at, so a subclass can put a glyph in front of it.
    fileprivate var contentInset: CGFloat {
        get { (cell as? ThemedTextFieldCell)?.contentInset ?? Layout.inset }
        set { (cell as? ThemedTextFieldCell)?.contentInset = newValue }
    }

    private func drawSurface() {
        let path = ThemedSurface.draw(
            bounds,
            fill: Design.Surface.controlResting,
            border: isEditing ? Design.Surface.accent : Design.Surface.border
        )

        guard isEditing else { return }
        // A second pass on the same shape rather than a wider single stroke: half of a thick
        // stroke falls outside the path, which on a squared theme clips against the bounds.
        Design.Surface.accent.setStroke()
        path.lineWidth = Design.Accessibility.focusRingWidth
        path.stroke()
    }
}

// MARK: - Cell

/// Insets the text so it clears the drawn border, and centres it in a control whose height comes
/// from the design scale rather than from the font.
private final class ThemedTextFieldCell: NSTextFieldCell {

    var contentInset: CGFloat = ThemedTextField.Layout.inset

    /// Height is taken from the font rather than from `cellSize(forBounds:)`, which AppKit may
    /// answer by asking for this rect back.
    private func adjusted(_ rect: NSRect) -> NSRect {
        let height = ceil((font ?? Design.Typography.body()).boundingRectForFont.height)
        return NSRect(
            x: rect.minX + contentInset,
            y: rect.midY - height / 2,
            width: max(0, rect.width - contentInset - ThemedTextField.Layout.inset),
            height: height
        )
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: adjusted(rect))
    }

    /// The field editor is placed by these two, not by `drawingRect`, so text would jump on
    /// click without them.
    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor: NSText,
        delegate: Any?,
        start: Int,
        length: Int
    ) {
        super.select(
            withFrame: adjusted(rect), in: controlView, editor: editor,
            delegate: delegate, start: start, length: length
        )
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: adjusted(rect), in: controlView, editor: editor,
            delegate: delegate, event: event
        )
    }
}

// MARK: - Search

/// A search field drawn from the theme, replacing `NSSearchField`.
///
/// Its own class rather than a flag, because a search field is a *shape*: the magnifier is what
/// says the field filters rather than accepts, and the find bar and the import sheet both rely
/// on that being obvious at a glance.
final class ThemedSearchField: ThemedTextField {

    private enum Layout {
        static let glyphSize: CGFloat = Design.Symbol.control
        static let glyphLeading: CGFloat = Design.Spacing.small
        static let glyphGap: CGFloat = Design.Spacing.small
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentInset = Layout.glyphLeading + Layout.glyphSize + Layout.glyphGap
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let glyph = NSImage(
            systemSymbolName: DesignSymbols.search,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(Design.Symbol.configuration(Layout.glyphSize)) else { return }

        let rect = NSRect(
            x: Layout.glyphLeading,
            y: bounds.midY - Layout.glyphSize / 2,
            width: Layout.glyphSize,
            height: Layout.glyphSize
        )

        // Tinted by drawing the template and filling through what it laid down — the same trick
        // a menu item's image needs, since a template image carries no colour of its own.
        glyph.draw(in: rect)
        Design.Text.tertiary.set()
        rect.fill(using: .sourceAtop)
    }
}
