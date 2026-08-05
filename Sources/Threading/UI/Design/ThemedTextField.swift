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
        static let height: CGFloat = Design.Size.fieldHeight
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
        get { (cell as? ThemedFieldCell)?.contentInset ?? Layout.inset }
        set { (cell as? ThemedFieldCell)?.contentInset = newValue }
    }

    private func drawSurface() {
        // A text well is carved into the surface, not resting on it — the one place a bevel
        // material reads sunken rather than raised.
        let shape = ThemedSurface.draw(
            bounds,
            fill: Design.Surface.controlResting,
            border: isEditing ? Design.Surface.accent : Design.Surface.border,
            bevel: .sunken
        )

        guard isEditing else { return }
        // A second pass just inside the border rather than a wider single stroke: half of a
        // thick stroke falls outside the path it is centred on, and drawing is clipped at the
        // bounds, so a ring on the border's own shape comes out at half weight.
        let width = Design.Accessibility.focusRingWidth
        let ring = shape.inset(by: width / 2).path
        Design.Surface.accent.setStroke()
        ring.lineWidth = width
        ring.stroke()
    }
}

// MARK: - Cell

/// What `ThemedTextField` needs of whichever cell it was built with, so the glyph inset is
/// reachable without naming one concrete cell class. Secure entry is a *cell* behaviour and
/// `NSSecureTextFieldCell` descends from `NSTextFieldCell` directly, so the themed cells are
/// siblings rather than a chain — see `ThemedSecureField`.
@MainActor
protocol ThemedFieldCell: AnyObject {
    var contentInset: CGFloat { get set }
}

/// The text rect both themed cells place their content in.
///
/// A free function rather than a shared superclass for the reason above: the two cells cannot
/// share an ancestor below `NSTextFieldCell`, and the alternative was this arithmetic — on which
/// the field editor's position and therefore whether text jumps on click depends — living in two
/// files and drifting.
///
/// Height is taken from the font rather than from `cellSize(forBounds:)`, which AppKit may answer
/// by asking for this rect back.
@MainActor
private func themedFieldTextRect(
    _ rect: NSRect,
    font: NSFont?,
    contentInset: CGFloat
) -> NSRect {
    let height = ceil((font ?? Design.Typography.body()).boundingRectForFont.height)
    return NSRect(
        x: rect.minX + contentInset,
        y: rect.midY - height / 2,
        width: max(0, rect.width - contentInset - ThemedTextField.Layout.inset),
        height: height
    )
}

/// Insets the text so it clears the drawn border, and centres it in a control whose height comes
/// from the design scale rather than from the font.
private final class ThemedTextFieldCell: NSTextFieldCell, ThemedFieldCell {

    var contentInset: CGFloat = ThemedTextField.Layout.inset

    private func adjusted(_ rect: NSRect) -> NSRect {
        themedFieldTextRect(rect, font: font, contentInset: contentInset)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: adjusted(rect))
    }

    /// The field editor is placed by these two, not by `drawingRect`, so text would jump on
    /// click without them — and coloured by them, for the reason `ThemedTextSelection` states:
    /// the editor is AppKit's own view, shared between every field in the window, so the moment
    /// it is handed over is the only place it can be told what a selection looks like here.
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
        // *After* `super`, which is the whole subtlety: AppKit configures the shared editor as it
        // hands it over, and anything said first is overwritten by the field it is being lent to.
        ThemedTextSelection.apply(to: editor, in: controlView)
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
        ThemedTextSelection.apply(to: editor, in: controlView)
    }
}

// MARK: - Secure

/// A masked field drawn from the theme, replacing a bezelled `NSSecureTextField`.
///
/// Subclasses `ThemedTextField` and swaps only the *cell*, because that is where secure entry
/// actually lives: `NSSecureTextField` is an `NSTextField` whose cell is an
/// `NSSecureTextFieldCell`, and the cell is what vends the secure field editor that suppresses
/// the glyphs, the pasteboard and the input-method log. Inheriting the themed field therefore
/// keeps one surface, one focus ring and one placeholder treatment, and puts the masking exactly
/// where AppKit puts it.
///
/// It exists for one screen — entering a test-account password in Settings — and deliberately
/// offers no reveal control. A field that can be un-masked is a field whose value is on screen
/// while an agent may be driving the app beside it.
final class ThemedSecureField: ThemedTextField {

    override class var cellClass: AnyClass? {
        get { ThemedSecureFieldCell.self }
        set { super.cellClass = newValue }
    }

    /// The secure field editor is a `NSSecureTextView` inside the same private clip view an
    /// ordinary field expands into. `ThemedTextField.permitsSystemChrome` already answers for
    /// `NSTextView` subclasses, so nothing is relaxed here — this is only where that is stated.
    override func accessibilityRole() -> NSAccessibility.Role? {
        .textField
    }
}

/// The secure sibling of `ThemedTextFieldCell`, sharing its text rect and nothing else.
private final class ThemedSecureFieldCell: NSSecureTextFieldCell, ThemedFieldCell {

    var contentInset: CGFloat = ThemedTextField.Layout.inset

    private func adjusted(_ rect: NSRect) -> NSRect {
        themedFieldTextRect(rect, font: font, contentInset: contentInset)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: adjusted(rect))
    }

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
        ThemedTextSelection.apply(to: editor, in: controlView)
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
        ThemedTextSelection.apply(to: editor, in: controlView)
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

        TemplateImageDrawing.draw(glyph, in: rect, tint: Design.Text.tertiary)
    }
}
