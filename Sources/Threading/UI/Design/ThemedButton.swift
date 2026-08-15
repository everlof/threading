import AppKit
import CoreText

/// A button drawn from the theme, replacing `NSButton`.
///
/// It carries the design system's oldest rule — *flat over bezelled* — into the one control that
/// had kept ignoring it: a stock `NSButton` draws a system bezel sized for a system window, and a
/// row of them is the heaviest thing on any page they land on. `FlatButton` said this first, for
/// settings only, by hiding the bezel and setting a layer colour; this replaces it, because a
/// layer colour is a frozen `cgColor` that a live theme switch leaves stale.
///
/// Two shapes, chosen by `isBordered` so a call site that already said `isBordered = false`
/// migrates by changing a type and nothing else:
///
/// - **bordered** — a surface, a hairline and a title. The ordinary push button.
/// - **plain** — no surface at rest: an icon in a row, a close button, anything that should read
///   as a mark rather than as a control. It gains a surface under the pointer, which is the only
///   thing that says a bare glyph can be clicked.
///
/// `isProminent` fills the bordered shape with the theme's accent, for the one action a sheet is
/// asking about. There is deliberately no third colour: a destructive button says so in its
/// *title*, and a red control on a theme whose accent is already red says nothing at all.
///
/// Those two flags are the app's whole button hierarchy, and `Emphasis` is their name: **one**
/// primary per screen, secondary for everything else that needs a surface, tertiary for what
/// should read as a mark. The flags stay because the call sites already say them; a new screen
/// should say `emphasis` instead, because "which of the three is this" is the question being
/// answered and `isBordered = false` is not an answer to it.
final class ThemedButton: ThemedControl, OpticalInsetProviding, TextBaselineProviding {

    // MARK: - Geometry

    private enum Layout {
        static let height: CGFloat = Design.Size.chipHeight
        static let titleInset: CGFloat = Design.Spacing.inset
        static let imageSize: CGFloat = Design.Symbol.control + 3
        static let imageTitleGap: CGFloat = Design.Spacing.small
        static let plainInset: CGFloat = Design.Spacing.tight
        static let disabledAlpha: CGFloat = 0.4
        static let pressedDim: CGFloat = 0.75

        /// Between the title and the chord named after it. Wider than the image gap: the two
        /// are different kinds of thing, and a hint crowding the words reads as one word.
        static let shortcutGap: CGFloat = Design.Spacing.medium

        /// A menu-row disclosure is a trailing column, not another word in the title. It uses
        /// the same optical size as the app's real menu chevron so a button acting as a cell and
        /// a row inside `ThemedMenu` make the same promise.
        static let submenuIndicatorSize: CGFloat = Design.Symbol.chevron
        static let submenuIndicatorGap: CGFloat = Design.Spacing.small

        /// The chord is a reminder, not a second title, so it steps back from the same ink
        /// rather than taking a colour of its own — which on a filled primary is the only way
        /// to stay legible against the accent.
        static let shortcutAlpha: CGFloat = 0.7

        /// Ordinary mixed-case ink, for finding where a title's band of ink sits in its face:
        /// an ascender and a round letter, so the band runs from the overshoot just below the
        /// baseline up to a lowercase ascender — which is what a button title actually inks.
        ///
        /// Measured from this rather than from the button's own title deliberately. Reading the
        /// real title would put the chord somewhere different on "Apply" than on "Add", since a
        /// descender drags the measured band down half a point, and a row of buttons would
        /// disagree with itself.
        static let opticalReference = "bo"
    }

    /// Where a plain symbol button's *title* starts, for a sibling row that carries no symbol
    /// and still has to line its words up with the rows that do. Published rather than
    /// re-derived at the call site: the arithmetic belongs beside the drawing that uses it.
    ///
    /// Composed from the two below rather than from `Layout` again, so the word column and the
    /// mark column cannot drift apart — they are the same three numbers read twice.
    static let plainTitleLeadingInset: CGFloat =
        Layout.plainInset + markSlotWidth + markTitleGap

    // MARK: - Emphasis

    /// How loudly this button asks to be pressed — the three tiers the design system has, named.
    ///
    /// - **primary** — the accent-filled shape. The one action the screen is about, and there is
    ///   at most one per screen; a second makes both of them ordinary.
    /// - **secondary** — a surface, a hairline, a title. Every other real action.
    /// - **tertiary** — no surface until the pointer is on it. A mark that happens to be
    ///   clickable, which is what an icon in a row should read as.
    enum Emphasis {
        case primary
        case secondary
        case tertiary
    }

    /// Where an icon/title unit sits when the control is wider than its intrinsic content.
    ///
    /// Buttons are centred by default, which is right for ordinary actions. Menu rows are a
    /// different shape: every hit target fills one shared column, while the icon and words keep
    /// a stable leading edge. Keeping that distinction in the design-system control means a
    /// feature does not have to wrap a button in a second hover-drawing view to get a menu cell.
    enum ContentAlignment {
        case center
        case leading
    }

    /// The tier, over the two flags that draw it. Reading it back is exact, since every
    /// combination of the flags maps to one tier and back.
    var emphasis: Emphasis {
        get {
            if isProminent { return .primary }
            return isBordered ? .secondary : .tertiary
        }
        set {
            isProminent = newValue == .primary
            isBordered = newValue != .tertiary
        }
    }

    var contentAlignment: ContentAlignment = .center {
        didSet { needsDisplay = true }
    }

    /// Draws the trailing `›` that says resting on this menu-like row reveals more choices.
    ///
    /// The indicator owns a real trailing column and therefore participates in intrinsic width
    /// and title truncation. Appending a Unicode arrow to `title` cannot do either: it follows a
    /// short title around the row and is the first thing lost when a long title truncates.
    var showsSubmenuIndicator = false {
        didSet {
            guard showsSubmenuIndicator != oldValue else { return }
            contentChanged()
        }
    }

    // MARK: - Content

    var title: String = "" {
        didSet { contentChanged() }
    }

    /// Optional keyboard mnemonic. Its underline is part of the label and Option+character
    /// activates the same action as a click—the behavior behind the underlined B/N in the
    /// imported Win32 action row, not fixture-only decoration.
    var mnemonicCharacter: Character? {
        didSet { needsDisplay = true }
    }

    var image: NSImage? {
        didSet { contentChanged() }
    }

    /// The semantic name passed to the symbol initializer. It is deliberately independent of
    /// `toolTip`: a caller may make the Help Tag more explanatory without silently renaming the
    /// button for VoiceOver and UI automation.
    private var iconAccessibilityName: String?

    /// `NSControl.font`, observed. Left nil it takes the scale's control size; a call site sets
    /// it where the title is not really type — the accounts page puts an *emoji* in a button and
    /// sizes it as a mark.
    override var font: NSFont? {
        didSet { contentChanged() }
    }

    private var buttonStyle: AppTheme.Material.ButtonStyle {
        AppThemePalette.current.material(for: effectiveAppearance).buttonStyle
    }

    /// What is painted may follow a theme's display convention; what accessibility and the
    /// action model expose remains the authored title below.
    private var displayTitle: String {
        switch buttonStyle.textTransform {
        case .none: return title
        case .uppercase: return title.uppercased()
        }
    }

    private var titleFont: NSFont {
        font ?? Design.Typography.button(style: buttonStyle)
    }

    /// One set of attributes for measuring and for drawing, and a paragraph style that forbids
    /// wrapping. Without it `NSString.draw(in:)` wraps to the rect it is given, so a title
    /// measured a hair too narrow silently breaks at its space and draws its second word off the
    /// bottom — "Add Project" in the sidebar footer read as "Add".
    private func titleAttributes(foreground: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: foreground,
            .paragraphStyle: paragraph
        ]
        if buttonStyle.tracking != 0 { attributes[.kern] = buttonStyle.tracking }
        return attributes
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        titleAttributes(foreground: foreground)
    }

    private func attributedDisplayTitle(foreground: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: displayTitle,
            attributes: titleAttributes(foreground: foreground)
        )
        if let mnemonicCharacter {
            let range = (displayTitle as NSString).range(
                of: String(mnemonicCharacter),
                options: .caseInsensitive
            )
            if range.location != NSNotFound {
                result.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }
        return result
    }

    /// The pixel alphabet is deliberately finite. Copy outside it is still copy, not artwork:
    /// keep every localized character intact and let the scalable font path draw that title.
    private var usesPixelTitle: Bool {
        buttonStyle.titleRendering == .pixel5x6
            && PixelTitleArtwork.canDraw(displayTitle)
    }

    private var titleWidth: CGFloat {
        guard !displayTitle.isEmpty else { return 0 }
        if usesPixelTitle { return PixelTitleArtwork.width(of: displayTitle) }
        return ceil(attributedDisplayTitle(foreground: foreground).size().width)
    }

    private var titleLineHeight: CGFloat {
        usesPixelTitle
            ? PixelTitleArtwork.cellHeight
            : Design.Typography.lineHeight(of: titleFont)
    }

    /// The chord this button answers to, drawn on its face — `⌘↩` beside "Start session".
    ///
    /// One value for both halves on purpose. A button that answers a chord it does not name is
    /// a shortcut nobody finds, and a button that names one it does not answer is a lie; keeping
    /// them the same property makes both impossible.
    ///
    /// This is also the *modifier-carrying* key equivalent. `keyEquivalent` below matches on the
    /// character alone, which is right for a sheet's Return and wrong for anything sitting beside
    /// a text view: `keyEquivalent = "\r"` on the session composer's start button would claim the
    /// Return meant for the prompt, since AppKit offers every key-down to the view tree's key
    /// equivalents before the first responder ever sees it.
    var shortcut: KeyboardShortcut? {
        didSet { contentChanged() }
    }

    private var shortcutFont: NSFont { Design.Typography.controlRegular() }

    private var shortcutText: String { shortcut?.displayString ?? "" }

    private var shortcutWidth: CGFloat {
        let text = shortcutText
        guard !text.isEmpty else { return 0 }
        return ceil(text.size(withAttributes: [.font: shortcutFont]).width)
    }

    /// Mirrors `NSButton.contentTintColor`: the colour of the title and of a template image.
    /// `nil` follows the style — the label colour on a bordered button, the ground colour on a
    /// prominent one.
    var contentTintColor: NSColor? {
        didSet { needsDisplay = true }
    }

    // MARK: - Style

    /// Mirrors `NSButton.isBordered`, and means the same thing: `false` drops the surface and
    /// leaves the content. Kept under AppKit's name because that is what the call sites already
    /// say.
    var isBordered: Bool = true {
        didSet { contentChanged() }
    }

    /// The accent-filled shape, for the action a sheet or a card is asking about.
    var isProminent: Bool = false {
        didSet { contentChanged() }
    }

    /// What a *plain* button raises under the pointer, when the resting control surface is not
    /// enough to be seen.
    ///
    /// A plain button rests on nothing and lifts to `Design.Surface.controlResting`, which reads
    /// clearly against a pane. On top of a surface that is already filled — a tab's ×, sitting on
    /// the tab's own fill — the same colour is the same colour twice and says nothing, so the one
    /// control in the row that closes something looked inert. A call site that puts a plain button
    /// on a fill states the weight that reads there.
    var hoverFill: NSColor? {
        didSet { needsDisplay = true }
    }

    /// Whether this button draws its own fill, border and glow, or leaves them to whoever
    /// hosts it.
    ///
    /// False for the press half of a `SplitButtonView`, and *only* for a host that draws the
    /// surface itself — the seam `ThemedIconButton` already states, on the titled button. The
    /// title, the image, the chord, the focus ring and the press gesture are unchanged, because
    /// none of them is the surface. A hosted half also keeps its face put: the travel a material
    /// states for hover and press belongs to a whole control, and a half that moved alone would
    /// tear the plate it shares.
    var drawsSurface = true {
        didSet {
            guard drawsSurface != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Told to the host that draws this button's surface, whenever what it would draw changed —
    /// see `ThemedIconButton.surfaceStateDidChange` for why the host cannot track this itself.
    var surfaceStateDidChange: (() -> Void)?

    /// Whether a host drawing for this button should raise its half — the pointer is on it, or
    /// holding it down.
    var isRaised: Bool { isHovered || isPressed }

    /// Mirrors `NSButton.keyEquivalent`, so a sheet's default and cancel buttons keep answering
    /// Return and Escape. It matches on the character whatever is held with it, which is what a
    /// sheet wants and what a pane holding a text field must not use — `shortcut` above is the
    /// one to reach for there.
    var keyEquivalent: String = ""

    /// Whether a bare Return presses this button, however that was stated.
    ///
    /// A sheet asks in order to focus its default, and either spelling is a real answer: the
    /// plain `keyEquivalent`, or the exact-match `shortcut` a sheet switches to once ⌘Return is
    /// also on offer. Reading `keyEquivalent` alone made the alert focus Cancel.
    var answersReturn: Bool {
        keyEquivalent == "\r"
            || (shortcut?.key == "\r" && shortcut?.modifiers.isEmpty == true)
    }

    // MARK: - State

    /// Whether the floating presentation is on its way out — still drawn, no longer offered.
    /// See `setFloatingPresence(_:animated:)`, which is the only thing that writes it.
    fileprivate var isFloatingLeaving = false

    /// Which presence transition is the current one. A departure hides the view when its own
    /// animation finishes, and an arrival that interrupts it must be able to say so — the
    /// completion has no other way to tell "my departure ended" from "a departure ended".
    fileprivate var floatingMotionGeneration = 0

    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            needsDisplay = true
            surfaceStateDidChange?()
        }
    }

    /// A raised half is drawn by the plate, not by this button, so the plate has to be told.
    override func hoverDidChange() {
        super.hoverDidChange()
        surfaceStateDidChange?()
    }

    /// What this press will send, taken at the moment the press began, and where it was aimed,
    /// in screen coordinates.
    ///
    /// The same rule `ThemedIconButton` states at length: a press belongs to what the button was
    /// when it went down. This control reaches recycled rows too — an extension contributes a
    /// button into a sidebar row as a `ThemedButton` (see `ExtensionNodeRenderer`), and that row
    /// is handed back to the reuse pool whenever the sidebar's shape changes.
    private weak var pressedTarget: AnyObject?
    private var pressedAction: Selector?
    private var pressTarget: NSRect = .zero

    /// The release, watched at the application rather than waited for at this view — AppKit
    /// delivers no mouse-up at all to a view detached between the two. See `ThemedIconButton`.
    private let releaseWatch = LocalEventMonitor()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    convenience init(image: NSImage?, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.image = image
        self.isBordered = false
        self.target = target
        self.action = action
    }

    /// The common icon-button case, so a call site does not repeat the symbol configuration and
    /// then quietly disagree with the one beside it about how big a glyph is.
    convenience init(symbol: String, accessibility: String, target: AnyObject?, action: Selector?) {
        self.init(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
                .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control)),
            target: target,
            action: action
        )
        iconAccessibilityName = accessibility
        toolTip = accessibility
    }

    // MARK: - Layout

    private func contentChanged() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let inset = isBordered ? Layout.titleInset : Layout.plainInset
        // A raised primary adds a one-point default-action frame *outside* the ordinary face.
        // Its drawing therefore insets the face one point on both sides. Reserve that pair here
        // or an intrinsically sized title loses two pixels of its content budget: the 11-cell
        // "NEW SESSION" display label measured 55px, received 53px, and correctly—but
        // needlessly—truncated its final ON to an ellipsis.
        let raisedPrimaryFrameWidth: CGFloat = isBordered
            && isProminent
            && buttonStyle.primaryTreatment == .raised
            ? 2
            : 0
        var width = inset * 2 + titleWidth + raisedPrimaryFrameWidth
        if image != nil {
            width += Layout.imageSize
            if !title.isEmpty { width += Layout.imageTitleGap }
        }
        if shortcutWidth > 0 {
            width += shortcutWidth
            if !title.isEmpty || image != nil { width += Layout.shortcutGap }
        }
        if showsSubmenuIndicator {
            width += Layout.submenuIndicatorSize
            if !title.isEmpty || image != nil || shortcutWidth > 0 {
                width += Layout.submenuIndicatorGap
            }
        }
        if isBordered, let minimumWidth = buttonStyle.minimumWidth {
            width = max(width, minimumWidth)
        }
        let borderedHeight = buttonStyle.minimumHeight ?? Layout.height
        let naturalTitleHeight = usesPixelTitle
            ? PixelTitleArtwork.cellHeight
            : ceil(titleFont.boundingRectForFont.height)
        let natural = isBordered
            ? max(borderedHeight, naturalTitleHeight + Layout.plainInset * 2)
            : max(Layout.imageSize + Layout.plainInset * 2, naturalTitleHeight)
        // A row's height wins, but never below the line the title actually sets: a theme may
        // author a control height shorter than its own face draws at, and a clipped title is a
        // worse answer than a button standing a point proud of its row.
        //
        // The *line*, not `boundingRectForFont` — which is the union of a family's glyph
        // extremes and is why a rect measured from it top-aligns the words it meant to centre
        // (see the 2026-07-31 note). Geneva reports 24.41 against a 16pt line, so a floor taken
        // from it would have stood every button in a 16pt Platinum row nine points proud of the
        // chooser beside it, which is the imbalance this adoption exists to remove.
        let floor = rowHeight.map {
            max($0, buttonStyle.minimumHeight ?? 0, titleLineHeight)
        }
        return NSSize(width: width, height: floor ?? natural)
    }

    /// The height a `ControlRowView` this button stands in has stated. Nil everywhere else.
    ///
    /// `Layout.height` is `chipHeight`, a constant — which was right while a chip was one too,
    /// and stopped being right when the chooser's height became the theme's. A bordered button
    /// beside a chip under Platinum stood ten points taller than it.
    private var rowHeight: CGFloat?

    /// Where the title's baseline sits, stated to Auto Layout — the `TextBaselineProviding`
    /// promise. `NSView`'s default answer is a frame edge, so a bare label baseline-constrained
    /// to this button hung from its bottom; centring the label instead misaligned by half the
    /// difference in the two fonts' metrics, which is the bug the pane bands wore (a point
    /// under SF, more under a theme family — the story `lineHeight(of:)` and the chord's drop
    /// already tell).
    ///
    /// Computed from the *intrinsic* height rather than `bounds`: every host gives this control
    /// its intrinsic measure (the bands centre it unconstrained, and a `ControlRowView`'s
    /// promotion feeds `rowHeight` back into that measure), and a value read from the solved
    /// frame would be a moving target while the engine is still solving it. The arithmetic is
    /// `drawContent`'s, read in reverse: the line box is centred in the face, and `draw(in:)`
    /// sets the baseline down from the box's top by the layout manager's own offset.
    override var firstBaselineOffsetFromTop: CGFloat {
        let height = intrinsicContentSize.height
        if usesPixelTitle {
            return (height - PixelTitleArtwork.cellHeight) / 2
                + CGFloat(PixelTitleArtwork.inkRows)
        }
        return (height - titleLineHeight) / 2
            + NSLayoutManager().defaultBaselineOffset(for: titleFont)
    }

    /// One line of text, so the last baseline is the first, measured from the other edge.
    override var lastBaselineOffsetFromBottom: CGFloat {
        intrinsicContentSize.height - firstBaselineOffsetFromTop
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isPressed = true

        pressedTarget = target
        pressedAction = action
        beginWatchingForRelease()
    }

    private func beginWatchingForRelease() {
        endWatchingForRelease()
        guard let window else { return }
        pressTarget = window.convertToScreen(convert(bounds, to: nil))

        releaseWatch.install(matching: [.leftMouseUp, .leftMouseDragged, .leftMouseDown]) {
            [weak self] event in
            self?.track(event)
            return event
        }
    }

    private func endWatchingForRelease() {
        releaseWatch.remove()
    }

    /// Where an event happened, in screen space — the one frame of reference that outlives the
    /// view hierarchy the press started in.
    private func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func track(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            isPressed = pressTarget.contains(screenLocation(of: event))
        case .leftMouseUp:
            completePress(firing: isPressed && pressTarget.contains(screenLocation(of: event)))
        default:
            // A fresh press supersedes this one, so a gesture whose release the app never saw
            // cannot be completed later by an unrelated click.
            completePress(firing: false)
        }
    }

    /// Ends the gesture exactly once, whichever half of the app got there first.
    private func completePress(firing shouldFire: Bool) {
        let sentTarget = pressedTarget
        let sentAction = pressedAction
        pressedTarget = nil
        pressedAction = nil
        isPressed = false
        endWatchingForRelease()
        guard shouldFire, isEnabled else { return }
        sendAction(sentAction, to: sentTarget)
    }

    /// A drag out of the button releases the press without firing, which is what AppKit does and
    /// what anyone who has ever changed their mind mid-click expects.
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// The same decision for a view still in its window, and the only one when a press is
    /// delivered straight to the view. A press already completed by the watch above is spent,
    /// so this cannot send it twice.
    override func mouseUp(with event: NSEvent) {
        completePress(
            firing: isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        )
    }

    func performClick() {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        performClick()
        return true
    }

    /// A key equivalent belongs to what is **on screen**.
    ///
    /// `NSButton` refuses one while hidden and this has to as well, because the app hides panes
    /// rather than tearing them down: `TerminalContainerViewController` keeps the session
    /// composer in the hierarchy with `isHidden = true` so a half-written prompt survives a
    /// detour. Without this guard the composer's ⌘Return would start a session from behind a
    /// conversation the user was replying to — the offscreen button hearing a chord meant for
    /// the reply box.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }

        if matches(shortcut, event) || (!keyEquivalent.isEmpty
            && event.charactersIgnoringModifiers == keyEquivalent) {
            performClick()
            return true
        }
        if let mnemonicCharacter,
           event.modifierFlags.intersection(Self.chordModifiers) == .option,
           event.charactersIgnoringModifiers?.compare(
               String(mnemonicCharacter), options: .caseInsensitive
           ) == .orderedSame {
            performClick()
            return true
        }
        return false
    }

    /// The chord modifiers a shortcut may state. Caps Lock and the function/numeric-pad bits
    /// ride along on ordinary events and are not part of anybody's key equivalent, so comparing
    /// the whole mask would make `⌘↩` stop working the moment Caps Lock was on.
    private static let chordModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    private func matches(_ shortcut: KeyboardShortcut?, _ event: NSEvent) -> Bool {
        guard let shortcut, !shortcut.key.isEmpty,
              let typed = event.charactersIgnoringModifiers else { return false }

        // Case-insensitively: a chord holding Shift arrives with an uppercase character while
        // the shortcut, like a menu item's, states the lowercase key and the modifier.
        guard typed.compare(shortcut.key, options: .caseInsensitive) == .orderedSame else {
            return false
        }
        return event.modifierFlags.intersection(Self.chordModifiers)
            == shortcut.modifiers.intersection(Self.chordModifiers)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    /// A button's words are its *title*; `accessibilityLabel` maps to AXDescription, which is
    /// where an icon-only button's tooltip belongs and where a titled button's text does not —
    /// a screen reader and a UI script both ask for the title first.
    override func accessibilityTitle() -> String? { title.isEmpty ? nil : title }
    override func accessibilityLabel() -> String? {
        title.isEmpty ? (iconAccessibilityName ?? toolTip) : nil
    }
    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // A button handed an applied surface is already wearing that shape — the accounts pane's
        // icon well is a disc — and the layer's corner clips this drawing to it. Taking the
        // radius from the record rather than from the token is what keeps a hover fill, and the
        // ring around it, the same silhouette as the well underneath.
        let corner = appliedSurfaceRadius ?? Design.Radius.control(fitting: bounds.size)

        // The press half of a split control draws no surface of its own: the plate underneath
        // is one shape, and a second one raised inside it is the seam `SplitButtonView` removes.
        // The glow is *cleared* rather than skipped — the half may have drawn one before it was
        // welded — and the ring still needs a silhouette to follow, so it takes the one that
        // was not drawn. The face stays put too: no visual offset, because a half that travelled
        // alone would tear the plate it shares.
        guard drawsSurface else {
            applyThemeControlGlow(nil, radius: corner)
            drawKeyboardFocus(
                around: ThemedSurface.Shape(rect: bounds, radius: corner),
                color: Design.Surface.accent
            )
            drawContent(in: bounds)
            return
        }

        // Clay's controls are separate lifted objects, not flat drawings on a lifted card. The
        // material may state that tighter depth independently from the broad panel shadow; a
        // pressed control drops the outer lift while the existing sunken drawing reports press.
        let collapsesOnHover = isHovered && buttonStyle.collapseShadowOnHover
        // A disabled clay control is the whole object at reduced emphasis in the reference,
        // not faint ink floating above a full-strength violet bloom. Removing its lift leaves
        // the still-visible face and dimmed content to communicate the state cleanly.
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        let shadow: AppTheme.Glow?
        if isProminent {
            shadow = material.controlGlow
        } else {
            switch buttonStyle.secondaryShadow {
            case .control: shadow = material.controlGlow
            case .panel: shadow = material.glow
            case .none: shadow = nil
            }
        }
        applyThemeControlGlow(
            isBordered && isEnabled && !isPressed && !collapsesOnHover ? shadow : nil,
            radius: corner
        )

        // The hit target stays put while the face travels, exactly like the translated CSS
        // control in the references. AppKit's Y axis points up, while the authored response
        // uses screen/CSS coordinates where positive Y means down.
        let offset = visualOffset
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.translateBy(x: offset.x, y: -offset.y)
        defer { context?.restoreGState() }

        let raisedPrimary = isProminent && buttonStyle.primaryTreatment == .raised
        let faceBounds = raisedPrimary ? bounds.insetBy(dx: 1, dy: 1) : bounds

        // A Win32 default button is not a blue action. It is the same raised button face as its
        // siblings, set apart by one additional dark frame around the bevel. The frame is always
        // present because "default" is the dialog's action hierarchy, while the dotted inset
        // below is keyboard focus and may move independently.
        //
        // Filled to the control's *silhouette*, not its box. On the square materials this rule
        // came from the two are the same rect; on a rounded one a square plate leaves a corner
        // of frame colour outside every curve, which reads as a hard tab behind the button
        // rather than as an edge around it.
        if raisedPrimary {
            dimmed(primaryColor).setFill()
            ThemedSurface.Shape(rect: bounds, radius: corner).path.fill()
        }

        let focusShape: ThemedSurface.Shape
        if isBordered {
            focusShape = ThemedSurface.draw(
                faceBounds,
                fill: surfaceFill,
                border: surfaceBorder,
                radius: corner,
                bevel: isPressed ? .sunken : .automatic
            )
        } else if isHovered || isPressed {
            // A plain button carries no surface at rest and lifts under the pointer — the design
            // system's "quiet until relevant". It is also the only thing saying the mark can be
            // clicked, which matters most exactly where the mark is all there is.
            focusShape = ThemedSurface.draw(
                bounds,
                fill: isPressed
                    ? (hoverFill ?? Design.Surface.controlHover)
                    : (hoverFill ?? Design.Surface.controlResting),
                radius: corner
            )
        } else {
            focusShape = ThemedSurface.Shape(rect: bounds, radius: corner)
        }

        // A prominent button keeps a band of its own fill outside the ring. Stroked on the edge,
        // the way a bordered button's is, the ring replaces the outermost points of the accent
        // with `Text.selected` — a near-ground tone, by definition — so the fill ends 2pt in on
        // every side and the pill reads 4pt shorter and 4pt narrower than the secondary beside
        // it. That is what a quit dialog looked like: Cancel and Quit, plainly different sizes,
        // on every theme, with nothing in the picture saying "focus". A bordered button asks for
        // no band, because the edge its ring lands on is a hairline rather than the surface.
        if raisedPrimary {
            drawClassicKeyboardFocus(in: faceBounds)
        } else {
            // In the tone the title is already cut from, because that tone is the one measured to
            // read on this button's own face. Stroking the ring in `primaryColor` instead — the
            // colour of the *fill* on a filled primary — is a ring painted on itself: the band
            // above kept the silhouette honest and the ring inside it then disappeared, so a
            // focused Quit and an unfocused one were the same picture.
            drawKeyboardFocus(
                around: focusShape,
                color: isProminent ? foreground : Design.Surface.accent,
                keepingEdge: isProminent ? Design.Accessibility.focusRingWidth : 0
            )
        }

        drawContent(in: faceBounds)
    }

    /// The face's ink — image, title and chord — drawn the same whether the surface under it is
    /// this button's own or a host plate's.
    private func drawContent(in faceBounds: NSRect) {
        let content = faceBounds.insetBy(
            dx: isBordered ? Layout.titleInset : Layout.plainInset,
            dy: 0
        )
        let titleWidth = self.titleWidth
        let imageWidth = image == nil ? 0 : Layout.imageSize
        let gap = titleWidth > 0 && imageWidth > 0 ? Layout.imageTitleGap : 0
        let shortcutWidth = self.shortcutWidth
        let shortcutGap = shortcutWidth > 0 && (titleWidth > 0 || imageWidth > 0)
            ? Layout.shortcutGap
            : 0
        let indicatorWidth = showsSubmenuIndicator
            ? Layout.submenuIndicatorSize + Layout.submenuIndicatorGap
            : 0
        let contentMaxX = max(content.minX, content.maxX - indicatorWidth)

        // Centred as one unit while it fits, so an icon-and-title button does not read as an icon
        // with a label hanging off it. Once squeezed, anchor that unit at the leading inset:
        // centring its *intrinsic* width in a narrower frame puts the drawing origin outside the
        // control and reveals an arbitrary middle slice instead of a conventional tail truncation.
        //
        // An image on its own is indivisible, however: there is no title to truncate and no
        // conventional leading edge for the mark to take. The Themes page's 26pt raised actions
        // are narrower than two title insets plus the 14pt image slot, so treating their symbol
        // as squeezed content pinned each affected mark four points to the right. Keep that unit on
        // the face's centre even when the title-padding budget does not fit.
        let measuredWidth = titleWidth + imageWidth + gap + shortcutWidth + shortcutGap
            + indicatorWidth
        let isImageOnly = image != nil && titleWidth == 0 && shortcutWidth == 0
        let fits = measuredWidth <= content.width || isImageOnly
        var x: CGFloat
        switch contentAlignment {
        case .center:
            x = fits ? faceBounds.midX - measuredWidth / 2 : content.minX
        case .leading:
            if userInterfaceLayoutDirection == .rightToLeft, fits {
                x = content.maxX - measuredWidth
            } else {
                x = content.minX
            }
        }

        if let image {
            draw(image, in: imageRect(for: image, centredOn: content.midY, from: x))
            x += Layout.imageSize + gap
        }

        // Centred on the *line box* (ascender to descender), not `boundingRectForFont`: that
        // rect adds the font's glyph extremes, and `draw(in:)` top-aligns its line in whatever
        // rect it is given. Under SF the two heights all but coincide, so this looked right —
        // under a serif theme family the bounding rect runs several points taller and every
        // title quietly sat that much above centre.
        let height = titleLineHeight
        let titleTop = content.midY + height / 2

        if !displayTitle.isEmpty {
            // Drawn into whatever is left rather than into the measured width, so a squeezed
            // button truncates instead of wrapping — and measured and drawn with the *same*
            // attributes, which is what went wrong first: measuring in the regular weight and
            // drawing in the medium one left "Add Project" a hair too wide for its own rect, so
            // it broke at the space and put "Project" on a second line nobody could see.
            //
            // The chord keeps its own width out of that: a hint is what the title truncates
            // *around*, never over.
            let available = max(0, contentMaxX - x - shortcutWidth - shortcutGap)
            let titleRect = NSRect(
                x: x,
                y: titleTop - height,
                width: available,
                height: height
            )
            if !isEnabled && buttonStyle.embossesDisabledTitle {
                drawDisplayTitle(
                    foreground: Design.Surface.bevelHighlight,
                    in: titleRect.offsetBy(dx: 1, dy: -1)
                )
            }
            drawDisplayTitle(foreground: foreground, in: titleRect)
            x += min(titleWidth, available) + shortcutGap
        }

        if shortcutWidth > 0 {
            let shortcutHeight = lineHeight(of: shortcutFont)
            let top = shortcutRectTop(titleTop: title.isEmpty ? nil : titleTop, centre: content.midY)
            withTitleRasterization {
                (shortcutText as NSString).draw(
                    in: NSRect(
                        x: x,
                        y: top - shortcutHeight,
                        width: max(0, contentMaxX - x),
                        height: shortcutHeight
                    ),
                    withAttributes: shortcutAttributes
                )
            }
        }

        if showsSubmenuIndicator {
            drawSubmenuIndicator(
                in: NSRect(
                    x: content.maxX - Layout.submenuIndicatorSize,
                    y: content.midY - Layout.submenuIndicatorSize / 2,
                    width: Layout.submenuIndicatorSize,
                    height: Layout.submenuIndicatorSize
                )
            )
        }
    }

    /// The same two grammars as `ThemedMenuRowView`: a hard filled triangle for the historical
    /// menu families, a quiet stroked chevron for modern material. Kept here rather than supplied
    /// as an SF Symbol so classic themes do not acquire one scalable Aqua glyph in their rows.
    private func drawSubmenuIndicator(in rect: NSRect) {
        let pointsRight = userInterfaceLayoutDirection != .rightToLeft
        if AppThemePalette.current.material.menuAppearance.isHistorical {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(
                x: pointsRight ? rect.minX + 1 : rect.maxX - 1,
                y: rect.minY
            ))
            triangle.line(to: NSPoint(
                x: pointsRight ? rect.maxX - 1 : rect.minX + 1,
                y: rect.midY
            ))
            triangle.line(to: NSPoint(
                x: pointsRight ? rect.minX + 1 : rect.maxX - 1,
                y: rect.maxY
            ))
            triangle.close()
            foreground.setFill()
            triangle.fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        let near = pointsRight ? rect.minX + rect.width * 0.3 : rect.maxX - rect.width * 0.3
        let far = pointsRight ? rect.maxX - rect.width * 0.2 : rect.minX + rect.width * 0.2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: near, y: rect.minY))
        path.line(to: NSPoint(x: far, y: rect.midY))
        path.line(to: NSPoint(x: near, y: rect.maxY))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        foreground.setStroke()
        path.stroke()
    }

    private func drawDisplayTitle(foreground: NSColor, in rect: NSRect) {
        if usesPixelTitle {
            PixelTitleArtwork.draw(
                displayTitle,
                in: rect,
                ink: foreground,
                mnemonicCharacter: mnemonicCharacter
            )
            return
        }
        withTitleRasterization {
            attributedDisplayTitle(foreground: foreground).draw(in: rect)
        }
    }

    /// Font smoothing is a construction choice for the tiny bitmap strikes used by Win32 and
    /// Workbench, not a process-wide preference. Saving the graphics state confines their hard
    /// device pixels to this title while neighbouring Aqua or application prose stays smooth.
    private func withTitleRasterization(_ draw: () -> Void) {
        guard !buttonStyle.antialiasesTitle, let context = NSGraphicsContext.current else {
            draw()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.setAllowsAntialiasing(false)
        context.cgContext.setShouldAntialias(false)
        context.cgContext.setAllowsFontSmoothing(false)
        context.cgContext.setShouldSmoothFonts(false)
        draw()
    }

    /// A clean-room display alphabet using the same fixed cell as classic Winamp's `TEXT`
    /// sheet: five device pixels wide by six high. The source skin used a sprite atlas rather
    /// than asking a scalable font renderer to become jagged; keeping this as authored vectors
    /// of one-bit cells gives custom themes the same construction without shipping its artwork.
    ///
    /// This is intentionally not a prose renderer. `canDraw` rejects the whole title when one
    /// character is absent, so a localized action never becomes a mixture of pixels and missing
    /// glyphs. That title takes the ordinary antialiased font path intact.
    enum PixelTitleArtwork {
        static let cellWidth: CGFloat = 5
        static let cellHeight: CGFloat = 6
        /// The rows of ink above the sixth-row baseline/spacing cell — which is also where the
        /// baseline sits, measured from the cell's top. `firstBaselineOffsetFromTop` reads it.
        static let inkRows = 5

        static func canDraw(_ title: String) -> Bool {
            title.allSatisfy { glyphs[$0] != nil }
        }

        static func width(of title: String) -> CGFloat {
            CGFloat(title.count) * cellWidth
        }

        static func draw(
            _ title: String,
            in rect: NSRect,
            ink: NSColor,
            mnemonicCharacter: Character?
        ) {
            guard canDraw(title), rect.width >= cellWidth else { return }
            let capacity = max(1, Int(floor(rect.width / cellWidth)))
            var cells = Array(title)
            if cells.count > capacity {
                cells = capacity == 1
                    ? ["…"]
                    : Array(cells.prefix(capacity - 1)) + ["…"]
            }

            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let context = NSGraphicsContext.current
            context?.shouldAntialias = false
            context?.cgContext.setAllowsAntialiasing(false)
            context?.cgContext.setShouldAntialias(false)
            ink.setFill()

            let isFlipped = context?.isFlipped ?? false
            let originY = floor(rect.midY - cellHeight / 2)
            let mnemonic = mnemonicCharacter.map { String($0).uppercased() }

            for (cellIndex, character) in cells.enumerated() {
                guard let rows = glyphs[character] else { continue }
                let originX = floor(rect.minX + CGFloat(cellIndex) * cellWidth)
                for (rowIndex, row) in rows.enumerated() {
                    let y = isFlipped
                        ? originY + CGFloat(rowIndex)
                        : originY + CGFloat(inkRows - rowIndex)
                    for (column, pixel) in row.enumerated() where pixel == "#" {
                        NSRect(
                            x: originX + CGFloat(column),
                            y: y,
                            width: 1,
                            height: 1
                        ).fill()
                    }
                }

                if mnemonic == String(character).uppercased() {
                    NSRect(
                        x: originX,
                        y: isFlipped ? originY + CGFloat(inkRows) : originY,
                        width: cellWidth - 1,
                        height: 1
                    ).fill()
                }
            }
        }

        // Five rows of ink plus the sixth-row baseline/spacing cell. The shapes are designed
        // here, not sampled from a skin; leading/trailing blanks keep adjacent cells distinct.
        private static let glyphs: [Character: [String]] = [
            "A": [".###.", "#...#", "#####", "#...#", "#...#"],
            "B": ["####.", "#...#", "####.", "#...#", "####."],
            "C": [".####", "#....", "#....", "#....", ".####"],
            "D": ["####.", "#...#", "#...#", "#...#", "####."],
            "E": ["#####", "#....", "####.", "#....", "#####"],
            "F": ["#####", "#....", "####.", "#....", "#...."],
            "G": [".###.", "#....", "#.###", "#...#", ".###."],
            "H": ["#...#", "#...#", "#####", "#...#", "#...#"],
            "I": [".###.", "..#..", "..#..", "..#..", ".###."],
            "J": ["..###", "...#.", "...#.", "#..#.", ".##.."],
            "K": ["#..#.", "#.#..", "##...", "#.#..", "#..#."],
            "L": ["#....", "#....", "#....", "#....", "#####"],
            "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
            "N": ["#...#", "##..#", "#.#.#", "#..##", "#...#"],
            "O": [".###.", "#...#", "#...#", "#...#", ".###."],
            "P": ["####.", "#...#", "####.", "#....", "#...."],
            "Q": [".###.", "#...#", "#...#", "#.#.#", ".####"],
            "R": ["####.", "#...#", "####.", "#.#..", "#..#."],
            "S": [".####", "#....", ".###.", "....#", "####."],
            "T": ["#####", "..#..", "..#..", "..#..", "..#.."],
            "U": ["#...#", "#...#", "#...#", "#...#", ".###."],
            "V": ["#...#", "#...#", "#...#", ".#.#.", "..#.."],
            "W": ["#...#", "#...#", "#.#.#", "##.##", "#...#"],
            "X": ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
            "Y": ["#...#", ".#.#.", "..#..", "..#..", "..#.."],
            "Z": ["#####", "...#.", "..#..", ".#...", "#####"],
            "0": [".###.", "#..##", "#.#.#", "##..#", ".###."],
            "1": ["..#..", ".##..", "..#..", "..#..", ".###."],
            "2": [".###.", "#...#", "...#.", "..#..", "#####"],
            "3": ["####.", "....#", ".###.", "....#", "####."],
            "4": ["#..#.", "#..#.", "#####", "...#.", "...#."],
            "5": ["#####", "#....", "####.", "....#", "####."],
            "6": [".###.", "#....", "####.", "#...#", ".###."],
            "7": ["#####", "...#.", "..#..", ".#...", ".#..."],
            "8": [".###.", "#...#", ".###.", "#...#", ".###."],
            "9": [".###.", "#...#", ".####", "....#", ".###."],
            " ": [".....", ".....", ".....", ".....", "....."],
            ".": [".....", ".....", ".....", ".....", "..#.."],
            ",": [".....", ".....", ".....", "..#..", ".#..."],
            ":": [".....", "..#..", ".....", "..#..", "....."],
            "-": [".....", ".....", ".###.", ".....", "....."],
            "_": [".....", ".....", ".....", ".....", "#####"],
            "+": [".....", "..#..", ".###.", "..#..", "....."],
            "!": ["..#..", "..#..", "..#..", ".....", "..#.."],
            "?": [".###.", "...#.", "..#..", ".....", "..#.."],
            "/": ["....#", "...#.", "..#..", ".#...", "#...."],
            "\\": ["#....", ".#...", "..#..", "...#.", "....#"],
            "(": ["...#.", "..#..", "..#..", "..#..", "...#."],
            ")": [".#...", "..#..", "..#..", "..#..", ".#..."],
            "[": [".###.", ".#...", ".#...", ".#...", ".###."],
            "]": [".###.", "...#.", "...#.", "...#.", ".###."],
            "'": ["..#..", "..#..", ".....", ".....", "....."],
            "\"": [".#.#.", ".#.#.", ".....", ".....", "....."],
            "#": [".#.#.", "#####", ".#.#.", "#####", ".#.#."],
            "=": [".....", ".###.", ".....", ".###.", "....."],
            "…": [".....", ".....", ".....", ".....", "#.#.#"]
        ]
    }

    /// The height `draw(in:)` actually lays a single line out at, so a rect made from it
    /// centres the text instead of top-aligning it in slack the font's extremes reserved.
    ///
    /// The rule this button was the first to need is now the design system's, so every surface
    /// that places drawn text answers the same way: the menu row and the closed chooser had the
    /// same defect, invisible under SF and 4pt under Platinum's Geneva.
    private func lineHeight(of font: NSFont) -> CGFloat {
        Design.Typography.lineHeight(of: font)
    }

    /// Where the chord's drawing rect starts, so the hint reads as part of the title's line
    /// rather than as a second thing floating beside it.
    ///
    /// Two corrections, and both were arrived at by rendering the thing and looking at it.
    ///
    /// **The baseline.** `NSString.draw(in:)` sets its line down from the rect's *top* by the
    /// layout manager's offset for the font it was handed. That offset is neither the ascender
    /// nor `ceil` of it — under New York at 12pt it is 11 against an ascender of 11.43 — so it
    /// is asked for rather than computed, and it answers for the **nominal** font, which is what
    /// keeps a chord whose `⌘` and `↩` arrive from a fallback face landing where the theme's own
    /// face says.
    ///
    /// **The drop.** A shared baseline is still not enough, because `⌘` is drawn a good deal
    /// taller than the caps around it and stops short of the baseline, so all of that excess
    /// sticks out of the top of the line. Under SF that is invisible — the title's own `t` and
    /// `i` reach nearly as high — but under a serif face, whose ascenders are shorter, the hint
    /// visibly floats. So the chord's band of ink is centred on the band a title inks, which
    /// costs SF a fifth of a point and a serif theme three fifths, matching what the eye wants
    /// in both.
    ///
    /// A `nil` title has no line to join, so its chord centres its ink on the button instead.
    private func shortcutRectTop(titleTop: CGFloat?, centre: CGFloat) -> CGFloat {
        let manager = NSLayoutManager()
        let chord = inkBand(of: shortcutText, in: shortcutFont)
        let baseline: CGFloat
        if let titleTop {
            let reference = inkBand(of: Layout.opticalReference, in: titleFont)
            let drop = chord.map { $0.midY - (reference?.midY ?? $0.midY) } ?? 0
            baseline = titleTop - manager.defaultBaselineOffset(for: titleFont) - drop
        } else {
            baseline = centre - (chord?.midY ?? 0)
        }
        return baseline + manager.defaultBaselineOffset(for: shortcutFont)
    }

    /// What a string actually inks, relative to its own baseline — the glyph paths rather than
    /// the font's reserved extremes, since it is the ink that has to line up.
    private func inkBand(of text: String, in font: NSFont) -> CGRect? {
        guard !text.isEmpty else { return nil }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isNull, ink.height > 0 else { return nil }
        return ink
    }

    /// The hint's ink: the title's colour, stepped back rather than replaced — see
    /// `Layout.shortcutAlpha`.
    private var shortcutAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let resolved = foreground.usingColorSpace(.sRGB) ?? foreground
        return [
            .font: shortcutFont,
            .foregroundColor: resolved.withAlphaComponent(
                resolved.alphaComponent * Layout.shortcutAlpha
            ),
            .paragraphStyle: paragraph
        ]
    }

    /// Where a glyph is drawn: fitted into the image box, never stretched to fill it — the rule
    /// `TemplateImageDrawing.fitted(_:in:)` states for every slot in the design system.
    ///
    /// It is computed here as well because the button *lays out* around it: the rect a glyph
    /// settles into is what the title measures itself against, so the fit has to be knowable
    /// before anything is drawn rather than only inside the draw call.
    private func imageRect(for image: NSImage, centredOn midY: CGFloat, from x: CGFloat) -> NSRect {
        let box = Layout.imageSize
        return TemplateImageDrawing.fitted(
            image,
            in: NSRect(x: x, y: midY - box / 2, width: box, height: box)
        )
    }

    /// A template image carries no colour of its own, so it is drawn and then filled through what
    /// it laid down. A real image — a brand mark — is left alone.
    private func draw(_ image: NSImage, in rect: NSRect) {
        TemplateImageDrawing.draw(image, in: rect, tint: foreground)
    }

    /// Disabled dims the *ink*, never `alphaValue` — the sidebar and the tab bar crossfade these
    /// buttons in and out by animating alpha, and a control that wrote to it while drawing would
    /// fight them for it.
    private func dimmed(_ colour: NSColor) -> NSColor {
        guard !isEnabled else { return colour }
        // Multiplied, not assigned. `withAlphaComponent` *replaces* alpha, so dimming a control
        // surface that is already translucent — Cyberpunk's resting fill is its neon at 10% —
        // made a disabled button four times louder than an enabled one. Resolved first, because
        // a theme role is a dynamic colour and has no alpha to read until it is.
        let resolved = colour.usingColorSpace(.sRGB) ?? colour
        return resolved.withAlphaComponent(resolved.alphaComponent * Layout.disabledAlpha)
    }

    private var surfaceFill: NSColor {
        if isProminent {
            if buttonStyle.primaryTreatment == .raised {
                return dimmed(secondaryFill)
            }
            if buttonStyle.primaryTreatment == .outlined {
                let fill = isPressed || isHovered
                    ? primaryColor.withAlphaComponent(1 - Layout.pressedDim)
                    : .clear
                return dimmed(fill)
            }
            let fill = isPressed || isHovered
                ? primaryColor.withAlphaComponent(Layout.pressedDim)
                : primaryColor
            return dimmed(fill)
        }
        return dimmed(secondaryFill)
    }

    private var secondaryFill: NSColor {
        AppThemePalette.color(
            isPressed || isHovered
                ? buttonStyle.secondaryHoverRole
                : buttonStyle.secondaryRole
        )
    }

    private var surfaceBorder: NSColor? {
        guard isProminent else { return Design.Surface.border }
        if buttonStyle.primaryTreatment == .raised { return nil }
        if buttonStyle.primaryTreatment == .outlined { return dimmed(primaryColor) }
        return buttonStyle.primaryBorderRole.map { dimmed(AppThemePalette.color($0)) }
    }

    private var primaryColor: NSColor {
        AppThemePalette.color(buttonStyle.primaryRole)
    }

    private var visualOffset: NSPoint {
        if isPressed {
            return NSPoint(x: buttonStyle.pressedOffsetX, y: buttonStyle.pressedOffsetY)
        }
        if isHovered {
            return NSPoint(x: buttonStyle.hoverOffsetX, y: buttonStyle.hoverOffsetY)
        }
        return .zero
    }

    /// The frame's horizontal padding around the title and glyph — the bordered shape's title
    /// inset, or the plain shape's breathing room for its hover surface. What `PaneFooterView`
    /// subtracts to put the *ink* on a stated margin.
    var opticalHorizontalInset: CGFloat {
        isBordered ? Layout.titleInset : Layout.plainInset
    }

    /// A bordered button's face is visible ink and reaches its frame, so it has no vertical
    /// correction. A plain button is a menu-like row whose frame reserves its hover target even
    /// at rest; report the air around the tallest thing actually drawn inside it. The caller
    /// supplies the row's height because a host may promote this control above its intrinsic
    /// measure — exactly what the session status card does.
    func opticalVerticalInset(forFrameHeight frameHeight: CGFloat) -> CGFloat {
        guard !isBordered else { return 0 }
        let contentHeight = max(
            displayTitle.isEmpty ? 0 : titleLineHeight,
            image == nil ? 0 : Layout.imageSize,
            shortcutText.isEmpty ? 0 : Design.Typography.lineHeight(of: shortcutFont)
        )
        guard contentHeight > 0 else { return 0 }
        return max(0, (frameHeight - contentHeight) / 2)
    }

    /// The slot this button draws its symbol in, and the gap after it.
    ///
    /// `PaneFooterView` aligns controls by *edge*, which is what a row of them needs. A
    /// **column** of rows needs the other alignment: marks in one vertical line and words in
    /// another, so a stack of readings reads as a list rather than as sentences that happen to
    /// share a left margin. When one of those rows is a titled button, every other row has to
    /// match the geometry it already has — so it is stated here rather than guessed there.
    static let markSlotWidth: CGFloat = Layout.imageSize
    static let markTitleGap: CGFloat = Layout.imageTitleGap

    private var foreground: NSColor {
        if let contentTintColor { return dimmed(contentTintColor) }
        if !isEnabled && buttonStyle.embossesDisabledTitle {
            return Design.Surface.bevelShadow
        }
        if isProminent {
            if buttonStyle.primaryTreatment == .raised { return dimmed(Design.Text.label) }
            if buttonStyle.primaryTreatment == .outlined { return dimmed(primaryColor) }
            if buttonStyle.primaryRole == .accent { return dimmed(Design.Text.selected) }
            return dimmed(Design.Text.on(primaryColor).label)
        }
        // A plain button is a mark until it is wanted, so it rests in the secondary tier and
        // steps up on hover — the design system's "quiet until relevant", in one control.
        if !isBordered { return dimmed(isHovered ? Design.Text.label : Design.Text.secondary) }
        return dimmed(Design.Text.label)
    }

    /// Classic keyboard focus is a one-pixel dotted inset, not the accent-coloured rounded
    /// outline used by current macOS controls. It sits inside the face, leaving both raised edge
    /// and default-action frame intact.
    private func drawClassicKeyboardFocus(in face: NSRect) {
        guard hasKeyboardFocus else { return }
        let rect = face.insetBy(dx: 4.5, dy: 4.5)
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([1, 1], count: 2, phase: 0)
        dimmed(Design.Text.label).setStroke()
        path.stroke()
    }
}

// MARK: - Shared Presentations

extension ThemedButton {

    /// The one down-arrow used to return to the live end of a scrolling surface.
    ///
    /// The component owns its target, surface and semantic shape; hosts contribute only the
    /// wording, action and placement. Keeping those together is what makes Git Review and Native
    /// Chat one affordance rather than two buttons that happen to use the same symbol.
    static func floatingScrollToEnd(
        accessibility: String,
        target: AnyObject?,
        action: Selector?
    ) -> ThemedButton {
        let button = ThemedButton(
            symbol: "arrow.down",
            accessibility: accessibility,
            target: target,
            action: action
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.toolTip = accessibility
        button.applySurface(
            fill: Design.Surface.elevated,
            radius: .pill(height: Design.Size.floatingNavigationTarget),
            border: Design.Surface.border,
            glow: true
        )
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Design.Size.floatingNavigationTarget),
            button.heightAnchor.constraint(equalToConstant: Design.Size.floatingNavigationTarget)
        ])
        return button
    }

    // MARK: Floating presence

    /// Whether the floating target is currently being offered.
    ///
    /// Read rather than `isHidden`, because a target on its way out is still on screen and is
    /// no longer on offer: the host asks the same question every scroll event, and answering it
    /// from the pixels would restart the departure on every one of them.
    var isFloatingPresent: Bool { !isHidden && !isFloatingLeaving }

    /// Offers the floating target, or takes it back — travelling either way.
    ///
    /// The arrival comes **up** from below its resting place and grows to full size, so the
    /// arrow reads as rising out of the edge it steers toward rather than being switched on
    /// over the content. The departure is its mirror, and quicker: arriving is information the
    /// eye follows, leaving is a decision already made.
    ///
    /// Idempotent, and safe to interrupt in either direction — the hosts call this from a
    /// scroll callback, so "still absent" has to cost nothing and a reader who scrolls back up
    /// mid-departure must get the arrow back rather than a second animation fighting the first.
    ///
    /// `animated: false` is for a host replacing everything under the target — a re-render has
    /// no *from* picture to travel out of, so the arrow leaves with the content it belonged to.
    func setFloatingPresence(_ present: Bool, animated: Bool = true) {
        guard present != isFloatingPresent else { return }

        // Whatever was in flight is now history: its completion must not hide a target that is
        // arriving again, and its opacity animation must not keep dimming one.
        floatingMotionGeneration &+= 1
        let generation = floatingMotionGeneration
        isFloatingLeaving = false
        layer?.removeAnimation(forKey: FloatingTargetMotion.animationKey)
        settleFloatingOpacity()

        // Each branch below names its own token, because the durations are not one duration
        // read twice: the arrival is the length of a rise, the departure the length of a drop.
        let travelTime = present
            ? Design.Motion.floatingTargetArrive
            : Design.Motion.vanish
        // No window means no render tree to animate in: a completion that may never arrive
        // would leave the target visible and unhittable, so the state is simply applied.
        guard animated, travelTime > 0, let layer, window != nil else {
            isHidden = !present
            return
        }

        guard present else {
            isFloatingLeaving = true
            let fall = floatingTransform(
                dy: FloatingTargetMotion.fall * floatingDownward,
                scale: FloatingTargetMotion.leaveScale
            )
            let sink = CABasicAnimation(keyPath: FloatingTargetMotion.transformKeyPath)
            sink.toValue = NSValue(caTransform3D: fall)
            sink.duration = Design.Motion.vanish
            sink.timingFunction = Design.Motion.drop
            sink.fillMode = .forwards
            sink.isRemovedOnCompletion = false
            layer.add(sink, forKey: FloatingTargetMotion.animationKey)

            // The fade is driven through AppKit rather than Core Animation so that *this*
            // group's completion is what hides the view: a layer animation's own completion
            // is the render tree's to deliver, and this one has a model change hanging off it.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Design.Motion.vanish
                context.timingFunction = Design.Motion.drop
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.floatingMotionGeneration == generation else { return }
                    self.isFloatingLeaving = false
                    self.isHidden = true
                    self.layer?.removeAnimation(forKey: FloatingTargetMotion.animationKey)
                    self.settleFloatingOpacity()
                }
            })
            return
        }

        isHidden = false
        // Presentation only: the model transform and opacity are already the resting ones, so
        // an arrival interrupted by anything at all leaves the target exactly where it belongs.
        let rise = floatingTransform(
            dy: FloatingTargetMotion.rise * floatingDownward,
            scale: FloatingTargetMotion.arriveScale
        )
        let travel = CABasicAnimation(keyPath: FloatingTargetMotion.transformKeyPath)
        travel.fromValue = NSValue(caTransform3D: rise)
        let fade = CABasicAnimation(keyPath: FloatingTargetMotion.opacityKeyPath)
        fade.fromValue = 0
        let arrival = CAAnimationGroup()
        arrival.animations = [travel, fade]
        arrival.duration = Design.Motion.floatingTargetArrive
        // `lift` rather than the `glide` every larger arrival here uses: over this rise glide
        // finishes before the eye has it, and the arrow reads as switched on. See the curve.
        arrival.timingFunction = Design.Motion.lift
        layer.add(arrival, forKey: FloatingTargetMotion.animationKey)
    }

    /// The resting transform, moved and shrunk about the button's own visual centre.
    ///
    /// Composed about that centre whatever the layer's anchor point, so the arithmetic holds
    /// under AppKit's own layer geometry rather than assuming a particular one — the same
    /// composition `ThemedMenu` uses for its panels.
    private func floatingTransform(dy: CGFloat, scale: CGFloat) -> CATransform3D {
        let anchor = layer?.anchorPoint ?? CGPoint(x: 0.5, y: 0.5)
        let centre = CGPoint(
            x: (0.5 - anchor.x) * bounds.width,
            y: (0.5 - anchor.y) * bounds.height
        )
        var transform = CATransform3DMakeTranslation(0, dy, 0)
        transform = CATransform3DTranslate(transform, centre.x, centre.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -centre.x, -centre.y, 0)
        return transform
    }

    /// Which way is *down* on screen, in the coordinates the transform is composed in.
    ///
    /// A layer-backed view under a flipped host inherits that host's flipped layer geometry,
    /// where y grows downward; under an unflipped one it grows upward. Both of this affordance's
    /// hosts are unflipped today, and a bare `-rise` written on that fact would silently invert
    /// the whole arrival the day a pane becomes flipped.
    private var floatingDownward: CGFloat {
        let flipped = superview?.layer?.isGeometryFlipped ?? superview?.isFlipped ?? false
        return flipped ? 1 : -1
    }

    /// Returns the view to full opacity *now*, cancelling an in-flight fade rather than
    /// starting a second one — `Design.Motion.immediate` is the group that makes an
    /// `animator()` proxy apply its value immediately instead of taking AppKit's default
    /// quarter second.
    private func settleFloatingOpacity() {
        guard alphaValue != 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.immediate
            self.animator().alphaValue = 1
        }
    }
}

// MARK: - Floating Target Motion

/// The picture a floating navigation target arrives from, and leaves into.
enum FloatingTargetMotion {

    /// How far below its resting place the target starts. `Design.Spacing.large` is the
    /// distance it reads as *rising from the pane's edge*: the arrow rests
    /// `Design.Spacing.inset` above that edge, so a rise of one step more begins just past it
    /// — far enough to be movement, and at the opacity it starts on, never a glyph seen
    /// hanging over whatever is below the pane.
    static let rise: CGFloat = Design.Spacing.large

    /// How far it sinks on the way out. Shorter than the rise, because a departure only has to
    /// read as *going*, and the eye is no longer following it.
    static let fall: CGFloat = Design.Spacing.medium

    /// How small it starts. Enough that the arrow visibly grows into its resting size; below
    /// about this the arrival stops reading as approach and starts reading as a zoom.
    static let arriveScale: CGFloat = 0.86

    /// How small it ends. Held closer to full than the arrival, so the exit reads as the same
    /// object leaving rather than as one collapsing.
    static let leaveScale: CGFloat = 0.92

    /// One key for both directions: adding either animation is what cancels the other.
    static let animationKey = "threading.floatingTarget.presence"
    static let transformKeyPath = "transform"
    static let opacityKeyPath = "opacity"
}

// MARK: - ControlRowMember

extension ThemedButton: ControlRowMember {

    func adopt(_ metrics: ControlRowMetrics) {
        guard rowHeight != metrics.height else { return }
        rowHeight = metrics.height
        contentChanged()
    }
}
