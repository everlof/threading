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
public class ThemedTextField: NSTextField, ThemedComponent, SystemChromeBoundary, PointerClaiming {

    /// Whether the editable well is permanent or belongs only to interaction.
    ///
    /// Most forms need a standing field silhouette: the empty well is part of the question the
    /// form asks. Chrome such as a browser address bar already has content at rest, and another
    /// outlined object around that content only competes with the page. It keeps the same frame,
    /// text inset and hit target, raises a quiet plate under the pointer, and becomes the ordinary
    /// focused field once editing begins.
    public enum SurfacePresentation: Equatable {
        case persistent
        case onInteraction
    }

    // MARK: - Geometry

    fileprivate enum Layout {
        static let height: CGFloat = Design.Size.fieldHeight
        /// Clear of the border, and roughly where a stock field puts its own text.
        static let inset: CGFloat = Design.Spacing.small + 2
    }

    // MARK: - State

    private var themeRedraw: ThemeRedraw?
    private let placeholderRefresh = AppEventObservations()
    private var hoverTrackingArea: NSTrackingArea?

    public let surfacePresentation: SurfacePresentation

    public private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The field editor is what actually becomes first responder, so "focused" is asked of the
    /// editor rather than tracked. Redraws are triggered by the two edges below.
    private var isEditing: Bool { currentEditor() != nil }

    // MARK: - Initialization

    /// Overridden so every `NSTextField` initializer — `init()`, `init(frame:)`, `init(string:)`
    /// — builds the inset-aware cell. Assigning `cell` afterwards would work too, and would drop
    /// whatever each initializer had already configured on the cell it made.
    public override class var cellClass: AnyClass? {
        get { ThemedTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    public override init(frame frameRect: NSRect) {
        surfacePresentation = .persistent
        super.init(frame: frameRect)
        setup()
    }

    public init(frame frameRect: NSRect, surfacePresentation: SurfacePresentation) {
        self.surfacePresentation = surfacePresentation
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Declared rather than inherited. `NSTextField(string:)` imports a *class factory* method,
    /// which is free to hand back a plain `NSTextField` — a subclass would then be one only by
    /// the type annotation at the call site.
    public convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    public convenience init(surfacePresentation: SurfacePresentation) {
        self.init(frame: .zero, surfacePresentation: surfacePresentation)
    }

    private func setup() {
        isBezeled = false
        // The surface is ours; leaving AppKit's on would paint a system rectangle under it.
        drawsBackground = false
        // A field is one line that scrolls — and AppKit only configures it that way through the
        // `NSTextField(string:)` *factory*, which `cellClass` rules out here (see `init(string:)`
        // below). A cell built by `init(frame:)` arrives wrapping instead: `wraps` true,
        // `isScrollable` false. A wrapping cell grows its **field editor** rather than scrolling
        // it, and the editor is not confined to the control — measured, a `fieldHeight` well
        // holding one long sentence took a 128pt editor, so the caret's line was the only one
        // left inside the drawn well and the lines above it were struck through by the border and
        // spilled over the row above. Settings' opening message shipped like that. These two are
        // exactly what AppKit's own editable field carries; `wraps` also moves the cell to
        // `.byClipping`.
        cell?.wraps = false
        cell?.isScrollable = true
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
    public func permitsSystemChrome(_ view: NSView) -> Bool {
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
    public override var placeholderString: String? {
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

    public override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = max(size.height, Layout.height)
        return size
    }

    // MARK: - Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }

        guard surfacePresentation == .onInteraction else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area

        // A browser strip can move when responsive controls fold. Tracking reports only pointer
        // movement, so clear a hover that became stale because the field itself moved.
        if hoverIsStale(isHovered) {
            isHovered = false
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        guard surfacePresentation == .onInteraction else { return }
        isHovered = true
    }

    public override func mouseExited(with event: NSEvent) {
        guard surfacePresentation == .onInteraction else { return }
        isHovered = false
    }

    // MARK: - Pointer

    /// The room the caret's cursor may claim — the whole control for an ordinary field, and less
    /// for one carrying controls inside its trailing edge.
    public var caretRect: NSRect { bounds }

    /// `NSTextField` claims one I-beam rectangle over its **whole bounds** — measured: it ignores
    /// the cell's drawing rect, so an inset that keeps the *text* clear of something does not keep
    /// the *pointer* clear of it — and claims none at all once the field is neither editable nor
    /// selectable. Restated here rather than clipped afterwards, so the field answers the same
    /// question every other view answers, in one place a test can read. `SearchFieldPointerTests`
    /// pins the AppKit behaviour this mirrors.
    public var pointerClaims: [PointerClaim] {
        guard isEnabled, isEditable || isSelectable else { return [] }
        return [PointerClaim(caretRect, .iBeam)]
    }

    /// A field is a drawn well, so what is not the caret's room is still the field's own plate.
    public var restingPointer: NSCursor? { .arrow }

    public override func resetCursorRects() {
        registerPointerClaims()
    }

    public override func layout() {
        super.layout()
        refreshPointerClaims()
    }

    // MARK: - Focus

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        needsDisplay = true
        return became
    }

    public override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        drawSurface()
        withThemeRasterization { super.draw(dirtyRect) }
    }

    /// The leading edge the text begins at, so a subclass can put a glyph in front of it.
    fileprivate var contentInset: CGFloat {
        get { (cell as? ThemedFieldCell)?.contentInset ?? Layout.inset }
        set { (cell as? ThemedFieldCell)?.contentInset = newValue }
    }

    /// The trailing edge the text stops at, so a subclass can put a control after it.
    fileprivate var trailingContentInset: CGFloat {
        get { (cell as? ThemedFieldCell)?.trailingContentInset ?? Layout.inset }
        set {
            guard newValue != trailingContentInset else { return }
            (cell as? ThemedFieldCell)?.trailingContentInset = newValue
            needsDisplay = true
        }
    }

    /// The well's fill.
    ///
    /// Period fields are their own semantic surface. Windows 98's 98.css field is a white writable
    /// well against the button-face chrome (and its disabled field falls back to that chrome);
    /// using the generic control face here erased that distinction even though `fieldSurface` was
    /// already authored by every retro material. 98.css treats read-only inputs the same way as
    /// disabled ones, so a non-editable field is not allowed to keep advertising a writable white
    /// well either.
    private var wellFill: NSColor {
        isEnabled && isEditable ? Design.Surface.field : Design.Surface.controlResting
    }

    /// The opaque ground selected text in this field lands on: the well, over whatever is behind
    /// the field.
    ///
    /// Asked only while a field editor is lent to the field, which is exactly when the well is
    /// drawn — `.onInteraction` included. `resolvedGround()` alone answers for the pane behind the
    /// field, because the well is painted in `draw(_:)` and never recorded; a selection measured
    /// there was measured against a colour it is not painted on.
    public func textSelectionGround() -> NSColor {
        wellFill.composited(over: resolvedGround())
    }

    private func drawSurface() {
        if surfacePresentation == .onInteraction, !isEditing {
            guard isHovered else { return }
            // Hover is an invitation rather than an already active text well. Keeping its bevel
            // flat lets it rise without changing visual grammar before the field is selected.
            ThemedSurface.draw(
                bounds,
                fill: Design.Surface.controlHover,
                bevel: .none
            )
            return
        }

        // A text well is carved into the surface, not resting on it — the one place a bevel
        // material reads sunken rather than raised.
        let shape = ThemedSurface.draw(
            bounds,
            fill: wellFill,
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

    /// Workbench Topaz and Win32's small UI strikes are bitmap faces. Buttons and menu rows
    /// already suppress smoothing for the same material flag; fields must do it as well or the
    /// text changes construction merely because it sits inside an editable well.
    private func withThemeRasterization(_ draw: () -> Void) {
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        guard !material.buttonStyle.antialiasesTitle,
              let context = NSGraphicsContext.current else {
            draw()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.shouldAntialias = false
        context.cgContext.setShouldAntialias(false)
        context.cgContext.setAllowsAntialiasing(false)
        context.cgContext.setShouldSmoothFonts(false)
        context.cgContext.setAllowsFontSmoothing(false)
        draw()
    }
}

// MARK: - Cell

/// What `ThemedTextField` needs of whichever cell it was built with, so the glyph inset is
/// reachable without naming one concrete cell class. Secure entry is a *cell* behaviour and
/// `NSSecureTextFieldCell` descends from `NSTextFieldCell` directly, so the themed cells are
/// siblings rather than a chain — see `ThemedSecureField`.
@MainActor
public protocol ThemedFieldCell: AnyObject {
    var contentInset: CGFloat { get set }
    var trailingContentInset: CGFloat { get set }
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
    contentInset: CGFloat,
    trailingContentInset: CGFloat
) -> NSRect {
    let height = ceil((font ?? Design.Typography.body()).boundingRectForFont.height)
    return NSRect(
        x: rect.minX + contentInset,
        y: rect.midY - height / 2,
        width: max(0, rect.width - contentInset - trailingContentInset),
        height: height
    )
}

/// Insets the text so it clears the drawn border, and centres it in a control whose height comes
/// from the design scale rather than from the font.
private final class ThemedTextFieldCell: NSTextFieldCell, ThemedFieldCell {

    var contentInset: CGFloat = ThemedTextField.Layout.inset
    var trailingContentInset: CGFloat = ThemedTextField.Layout.inset

    private func adjusted(_ rect: NSRect) -> NSRect {
        themedFieldTextRect(
            rect,
            font: font,
            contentInset: contentInset,
            trailingContentInset: trailingContentInset
        )
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
public final class ThemedSecureField: ThemedTextField {

    public override class var cellClass: AnyClass? {
        get { ThemedSecureFieldCell.self }
        set { super.cellClass = newValue }
    }

    // Both designated initializers restated so `init()` keeps being inherited — the search
    // field's note on `init(frame:surfacePresentation:)` applies here too.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public override init(frame frameRect: NSRect, surfacePresentation: SurfacePresentation) {
        super.init(frame: frameRect, surfacePresentation: surfacePresentation)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The secure field editor is a `NSSecureTextView` inside the same private clip view an
    /// ordinary field expands into. `ThemedTextField.permitsSystemChrome` already answers for
    /// `NSTextView` subclasses, so nothing is relaxed here — this is only where that is stated.
    public override func accessibilityRole() -> NSAccessibility.Role? {
        .textField
    }
}

/// The secure sibling of `ThemedTextFieldCell`, sharing its text rect and nothing else.
private final class ThemedSecureFieldCell: NSSecureTextFieldCell, ThemedFieldCell {

    var contentInset: CGFloat = ThemedTextField.Layout.inset
    var trailingContentInset: CGFloat = ThemedTextField.Layout.inset

    private func adjusted(_ rect: NSRect) -> NSRect {
        themedFieldTextRect(
            rect,
            font: font,
            contentInset: contentInset,
            trailingContentInset: trailingContentInset
        )
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
public final class ThemedSearchField: ThemedTextField, ThemeDerivedContent {

    @MainActor
    private enum Layout {
        static var glyphSize: CGFloat { Design.Symbol.control }
        static let glyphLeading: CGFloat = Design.Spacing.small
        static let glyphGap: CGFloat = Design.Spacing.small
        /// Air between the trailing controls and the field's own border.
        static let actionEdgeGap: CGFloat = Design.Spacing.tight
        /// Air the *text* keeps clear of the controls, so a long query truncates before it
        /// runs underneath them.
        static let actionTextGap: CGFloat = Design.Spacing.small
    }

    // MARK: - Trailing Controls

    /// The controls riding inside the field's trailing edge, sharing one run: an optional
    /// owner-installed action (Settings' Ask AI), then the ✕ every search field owes its
    /// reader. Inside the field rather than beside the results, because both act on *what was
    /// typed*: they belong to the query the way the magnifier does, and a button below a
    /// changing results list is never twice in the same place.
    private var trailingControlsBuilt = false

    /// Holds the trailing run on the query's own optical centre; see `textInkCenterOffset`.
    private var trailingControlsCentering: NSLayoutConstraint?

    /// The room the run last asked for. Kept only to notice when it changes shape — a control
    /// appearing or leaving moves the edge the pointer's I-beam stops at, and nothing about a
    /// *subview's* visibility invalidates this view's own cursor rectangles.
    private var trailingControlsWidth: CGFloat = 0

    private lazy var trailingControls: NSStackView = {
        trailingControlsBuilt = true
        let stack = NSStackView(views: [clearButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let centering = stack.centerYAnchor.constraint(
            equalTo: centerYAnchor,
            constant: textInkCenterOffset
        )
        trailingControlsCentering = centering
        NSLayoutConstraint.activate([
            centering,
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Layout.actionEdgeGap
            )
        ])
        return stack
    }()

    /// Where the query's visible letters actually centre, as an offset from the field's own
    /// vertical middle.
    ///
    /// The cell centres a rect of the font's *bounding* height, which reaches further below the
    /// baseline than any letter of a search term does — so the ink the reader sees sits above
    /// the field's geometric middle, by more the further a themed face's metrics stray from the
    /// system's. A mark centred on `midY` therefore drew visibly below the words beside it,
    /// which is the settings search field's "the magnifier is misaligned". The offset is the
    /// same arithmetic the cell's rect uses, carried on to the baseline and up half a cap.
    private var textInkCenterOffset: CGFloat {
        let font = font ?? Design.Typography.body()
        let height = ceil(font.boundingRectForFont.height)
        // In this flipped control, the text rect's top is midY - height/2, the baseline sits an
        // ascender below it, and the ink's centre half a cap height back up.
        return font.ascender - font.capHeight / 2 - height / 2
    }

    /// The way a query leaves without being deleted a character at a time. At the far edge —
    /// every search field's own convention — and only while there is something to clear.
    public private(set) lazy var clearButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "xmark",
            accessibility: L10n.string("Clear Search"),
            target: .inline,
            inkSource: .chrome
        )
        button.onPress = { [weak self] in self?.clear() }
        button.isHidden = true
        return button
    }()

    /// The owner-installed action while it is on offer, nil while hidden.
    ///
    /// Tertiary emphasis on purpose: no surface until the pointer is on it, so at rest it
    /// reads as part of the field, not as a second control fighting the caret for the row.
    public private(set) var trailingActionButton: ThemedButton?

    /// Creates the action once. Hidden until `isTrailingActionVisible` says otherwise, because
    /// with nothing typed there is nothing for it to act on.
    public func installTrailingAction(
        title: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        target: AnyObject,
        action: Selector
    ) {
        guard trailingActionButton == nil else { return }
        let button = ThemedButton(title: title, target: target, action: action)
        button.emphasis = .tertiary
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        trailingControls.insertArrangedSubview(button, at: 0)
        trailingActionButton = button
        refreshTrailingControls()
    }

    public var isTrailingActionVisible = false {
        didSet {
            guard isTrailingActionVisible != oldValue else { return }
            trailingActionButton?.isHidden = !isTrailingActionVisible
            refreshTrailingControls()
        }
    }

    // MARK: - Clearing

    /// Empties the field the way typing would have: the live editor with it, and the owner's
    /// text-change path afterwards, so a cleared search rebuilds exactly what a deleted query
    /// rebuilds.
    ///
    /// The ✕ presses this; **Escape is the owner's to bind**, through the ordinary
    /// `control(_:textView:doCommandBy:)` seam, because what Escape means belongs to the
    /// surface — the find bar closes on it, the settings sidebar clears. A component that
    /// claimed the key would decide that for every owner at once.
    public func clear() {
        guard !stringValue.isEmpty else { return }
        stringValue = ""
        currentEditor()?.string = ""
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: self)
    }

    /// The ✕ answers the text, the text yields the room the visible controls occupy — and with
    /// nothing visible the field is exactly the field it always was.
    private func refreshTrailingControls() {
        // An empty field that has never shown a control has nothing to lay out — and this can
        // run from `stringValue`'s setter mid-`init`, where forcing the lazy stack into
        // existence would build subviews under a half-initialized field.
        guard trailingControlsBuilt || !stringValue.isEmpty else { return }
        clearButton.isHidden = stringValue.isEmpty
        let width = ceil(trailingControls.fittingSize.width)
        trailingContentInset = width > 0
            ? Layout.actionEdgeGap + width + Layout.actionTextGap
            : ThemedTextField.Layout.inset
        guard width != trailingControlsWidth else { return }
        trailingControlsWidth = width
        refreshPointerClaims()
    }

    // MARK: - Pointer

    /// Where the trailing run begins, in this field's own coordinates — nil while it holds
    /// nothing visible.
    ///
    /// Read from the controls' **frames** rather than derived from the room the text yields: a
    /// themed button's frame reaches past the alignment rect the stack lays it out by, so the
    /// two answers differ by an optical inset, and it is the frame the pointer meets.
    private var trailingControlsLeadingEdge: CGFloat? {
        guard trailingControlsBuilt else { return nil }
        return trailingControls.arrangedSubviews
            .filter { !$0.isHidden }
            .map { $0.convert($0.bounds, to: self).minX }
            .min()
    }

    /// The caret's room stops where the trailing run begins: the words are what the I-beam is
    /// for, and Ask AI and the ✕ are buttons. The field's own plate takes the arrow behind them,
    /// and the buttons — themed controls — claim it for themselves as well.
    public override var caretRect: NSRect {
        guard let edge = trailingControlsLeadingEdge else { return bounds }
        return NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(0, edge - bounds.minX),
            height: bounds.height
        )
    }

    public override var stringValue: String {
        get { super.stringValue }
        set {
            super.stringValue = newValue
            refreshTrailingControls()
        }
    }

    public override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        refreshTrailingControls()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyGlyphInset()
    }

    /// Overridden alongside `init(frame:)` so the subclass keeps providing **all** of the
    /// field's designated initializers — that is what lets `init()` and `init(string:)` keep
    /// being inherited, which every call site building a bare `ThemedSearchField()` relies on.
    public override init(frame frameRect: NSRect, surfacePresentation: SurfacePresentation) {
        super.init(frame: frameRect, surfacePresentation: surfacePresentation)
        applyGlyphInset()
    }

    /// The magnifier's room, however the field was built.
    private func applyGlyphInset() {
        contentInset = Layout.glyphLeading + Layout.glyphSize + Layout.glyphGap
    }

    /// Both insets are cut from a mark's size, and a mark's optical size follows the chrome's
    /// type scale — so a theme switch that redrew the query at 0.80× left it starting behind
    /// the room the previous theme's magnifier had asked for. See `SymbolMetric`. The trailing
    /// run re-centres for the same reason: the ink offset is the font's, and the font moved.
    public func rederiveThemedContent() {
        applyGlyphInset()
        refreshTrailingControls()
        trailingControlsCentering?.constant = textInkCenterOffset
        needsDisplay = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let glyph = NSImage(
            systemSymbolName: DesignSymbols.search,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(Design.Symbol.configuration(Layout.glyphSize)) else { return }

        // On the query's optical centre, not the field's: the two differ by however far the
        // font's bounding box outreaches its letters, and a mark on `midY` sat visibly below
        // the words it introduces. See `textInkCenterOffset`.
        let rect = NSRect(
            x: Layout.glyphLeading,
            y: bounds.midY + textInkCenterOffset - Layout.glyphSize / 2,
            width: Layout.glyphSize,
            height: Layout.glyphSize
        )

        TemplateImageDrawing.draw(glyph, in: rect, tint: Design.Text.tertiary)
    }
}
