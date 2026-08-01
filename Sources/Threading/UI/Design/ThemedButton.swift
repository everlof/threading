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
final class ThemedButton: ThemedControl, OpticalInsetProviding {

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

        /// The chord is a reminder, not a second title, so it steps back from the same ink
        /// rather than taking a colour of its own — which on a filled primary is the only way
        /// to stay legible against the accent.
        static let shortcutAlpha: CGFloat = 0.7
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

    // MARK: - Content

    var title: String = "" {
        didSet { contentChanged() }
    }

    var image: NSImage? {
        didSet { contentChanged() }
    }

    /// `NSControl.font`, observed. Left nil it takes the scale's control size; a call site sets
    /// it where the title is not really type — the accounts page puts an *emoji* in a button and
    /// sizes it as a mark.
    override var font: NSFont? {
        didSet { contentChanged() }
    }

    private var titleFont: NSFont { font ?? Design.Typography.control() }

    /// One set of attributes for measuring and for drawing, and a paragraph style that forbids
    /// wrapping. Without it `NSString.draw(in:)` wraps to the rect it is given, so a title
    /// measured a hair too narrow silently breaks at its space and draws its second word off the
    /// bottom — "Add Project" in the sidebar footer read as "Add".
    private var titleAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: titleFont, .foregroundColor: foreground, .paragraphStyle: paragraph]
    }

    private var titleWidth: CGFloat {
        title.isEmpty ? 0 : ceil(title.size(withAttributes: [.font: titleFont]).width)
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
        didSet { needsDisplay = true }
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

    /// Mirrors `NSButton.keyEquivalent`, so a sheet's default and cancel buttons keep answering
    /// Return and Escape. It matches on the character whatever is held with it, which is what a
    /// sheet wants and what a pane holding a text field must not use — `shortcut` above is the
    /// one to reach for there.
    var keyEquivalent: String = ""

    // MARK: - State

    private var isPressed = false {
        didSet { needsDisplay = true }
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
    nonisolated(unsafe) private var releaseWatch: Any?

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
        toolTip = accessibility
    }

    // MARK: - Layout

    private func contentChanged() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let inset = isBordered ? Layout.titleInset : Layout.plainInset
        var width = inset * 2 + titleWidth
        if image != nil {
            width += Layout.imageSize
            if !title.isEmpty { width += Layout.imageTitleGap }
        }
        if shortcutWidth > 0 {
            width += shortcutWidth
            if !title.isEmpty || image != nil { width += Layout.shortcutGap }
        }
        let height = isBordered
            ? max(Layout.height, ceil(titleFont.boundingRectForFont.height) + Layout.plainInset * 2)
            : max(Layout.imageSize + Layout.plainInset * 2, ceil(titleFont.boundingRectForFont.height))
        return NSSize(width: width, height: height)
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

        releaseWatch = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .leftMouseDragged, .leftMouseDown]
        ) { [weak self] event in
            self?.track(event)
            return event
        }
    }

    private func endWatchingForRelease() {
        guard let releaseWatch else { return }
        NSEvent.removeMonitor(releaseWatch)
        self.releaseWatch = nil
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

    deinit {
        if let releaseWatch { NSEvent.removeMonitor(releaseWatch) }
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
    override func accessibilityLabel() -> String? { title.isEmpty ? toolTip : nil }
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

        let focusShape: ThemedSurface.Shape
        if isBordered {
            focusShape = ThemedSurface.draw(
                bounds,
                fill: surfaceFill,
                border: isProminent ? nil : Design.Surface.border,
                radius: corner
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

        drawKeyboardFocus(
            around: focusShape,
            color: isProminent ? Design.Text.selected : Design.Surface.accent
        )

        let content = bounds.insetBy(dx: isBordered ? Layout.titleInset : Layout.plainInset, dy: 0)
        let titleWidth = self.titleWidth
        let imageWidth = image == nil ? 0 : Layout.imageSize
        let gap = titleWidth > 0 && imageWidth > 0 ? Layout.imageTitleGap : 0
        let shortcutWidth = self.shortcutWidth
        let shortcutGap = shortcutWidth > 0 && (titleWidth > 0 || imageWidth > 0)
            ? Layout.shortcutGap
            : 0

        // Centred as one unit while it fits, so an icon-and-title button does not read as an icon
        // with a label hanging off it. Once squeezed, anchor that unit at the leading inset:
        // centring its *intrinsic* width in a narrower frame puts the drawing origin outside the
        // control and reveals an arbitrary middle slice instead of a conventional tail truncation.
        let measuredWidth = titleWidth + imageWidth + gap + shortcutWidth + shortcutGap
        var x = max(content.minX, content.midX - measuredWidth / 2)

        if let image {
            draw(image, in: imageRect(for: image, centredOn: content.midY, from: x))
            x += Layout.imageSize + gap
        }

        // Centred on the *line box* (ascender to descender), not `boundingRectForFont`: that
        // rect adds the font's glyph extremes, and `draw(in:)` top-aligns its line in whatever
        // rect it is given. Under SF the two heights all but coincide, so this looked right —
        // under a serif theme family the bounding rect runs several points taller and every
        // title quietly sat that much above centre.
        let height = lineHeight(of: titleFont)

        if !title.isEmpty {
            // Drawn into whatever is left rather than into the measured width, so a squeezed
            // button truncates instead of wrapping — and measured and drawn with the *same*
            // attributes, which is what went wrong first: measuring in the regular weight and
            // drawing in the medium one left "Add Project" a hair too wide for its own rect, so
            // it broke at the space and put "Project" on a second line nobody could see.
            //
            // The chord keeps its own width out of that: a hint is what the title truncates
            // *around*, never over.
            let available = max(0, content.maxX - x - shortcutWidth - shortcutGap)
            (title as NSString).draw(
                in: NSRect(
                    x: x,
                    y: content.midY - height / 2,
                    width: available,
                    height: height
                ),
                withAttributes: titleAttributes
            )
            x += min(titleWidth, available) + shortcutGap
        }

        guard shortcutWidth > 0 else { return }
        let shortcutHeight = lineHeight(of: shortcutFont)
        (shortcutText as NSString).draw(
            in: NSRect(
                x: x,
                y: content.midY - shortcutHeight / 2 + shortcutOpticalDrop,
                width: max(0, content.maxX - x),
                height: shortcutHeight
            ),
            withAttributes: shortcutAttributes
        )
    }

    /// The height `draw(in:)` actually lays a single line out at, so a rect made from it
    /// centres the text instead of top-aligning it in slack the font's extremes reserved.
    private func lineHeight(of font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// How far below the line-box centre this chord's *ink* wants to sit.
    ///
    /// A chord is symbols, not prose: `↩` carries no descender and its arrow rides near the cap
    /// line, so on the line box's centre it floats visibly high beside the title — the higher
    /// the quieter the theme's font, since the glyph comes from a fallback face either way.
    /// Measuring the drawn line's path bounds centres what is actually inked; for a lettered
    /// chord like `⌘K` the correction is a fraction of a point, so nothing else moves.
    private var shortcutOpticalDrop: CGFloat {
        let text = shortcutText
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: shortcutFont])
        )
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isNull, ink.height > 0 else { return 0 }
        let lineBoxCentre = (shortcutFont.ascender + shortcutFont.descender) / 2
        return ink.midY - lineBoxCentre
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

    /// Where a glyph is drawn: fitted into the image box, never stretched to fill it.
    ///
    /// `NSImage.draw(in:)` scales to the rect it is handed, on each axis independently, and an SF
    /// Symbol is square only by coincidence. `ellipsis` is three dots on one line — about four
    /// times wider than it is tall — so a square box pulled each dot into a vertical bar, which is
    /// what the session row's and the review header's overflow buttons were drawing. Fitting
    /// costs nothing for the square symbols and is the only thing that is right for the rest.
    private func imageRect(for image: NSImage, centredOn midY: CGFloat, from x: CGFloat) -> NSRect {
        let box = Layout.imageSize
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return NSRect(x: x, y: midY - box / 2, width: box, height: box)
        }

        let scale = min(box / size.width, box / size.height)
        let width = size.width * scale
        let height = size.height * scale
        // Centred in the slot it was allotted, so a wide-and-short glyph sits where a square one
        // would rather than hugging the slot's leading edge.
        return NSRect(
            x: x + (box - width) / 2,
            y: midY - height / 2,
            width: width,
            height: height
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
            return isPressed || isHovered
                ? Design.Surface.accent.withAlphaComponent(Layout.pressedDim)
                : Design.Surface.accent
        }
        return dimmed(isPressed || isHovered ? Design.Surface.controlHover : Design.Surface.controlResting)
    }

    /// The frame's horizontal padding around the title and glyph — the bordered shape's title
    /// inset, or the plain shape's breathing room for its hover surface. What `PaneFooterView`
    /// subtracts to put the *ink* on a stated margin.
    var opticalHorizontalInset: CGFloat {
        isBordered ? Layout.titleInset : Layout.plainInset
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
        if isProminent { return dimmed(Design.Surface.ground) }
        // A plain button is a mark until it is wanted, so it rests in the secondary tier and
        // steps up on hover — the design system's "quiet until relevant", in one control.
        if !isBordered { return dimmed(isHovered ? Design.Text.label : Design.Text.secondary) }
        return dimmed(Design.Text.label)
    }
}
