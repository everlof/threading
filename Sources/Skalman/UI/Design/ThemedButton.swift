import AppKit

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
    /// Return and Escape.
    var keyEquivalent: String = ""

    // MARK: - State

    private var isPressed = false {
        didSet { needsDisplay = true }
    }

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
    }

    /// A drag out of the button releases the press without firing, which is what AppKit does and
    /// what anyone who has ever changed their mind mid-click expects.
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled, !keyEquivalent.isEmpty,
              event.charactersIgnoringModifiers == keyEquivalent else { return false }
        performClick()
        return true
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
        let focusPath: NSBezierPath
        if isBordered {
            focusPath = ThemedSurface.draw(
                bounds,
                fill: surfaceFill,
                border: isProminent ? nil : Design.Surface.border
            )
        } else if isHovered || isPressed {
            // A plain button carries no surface at rest and lifts under the pointer — the design
            // system's "quiet until relevant". It is also the only thing saying the mark can be
            // clicked, which matters most exactly where the mark is all there is.
            focusPath = ThemedSurface.draw(
                bounds,
                fill: isPressed
                    ? (hoverFill ?? Design.Surface.controlHover)
                    : (hoverFill ?? Design.Surface.controlResting)
            )
        } else {
            let corner = Design.Radius.control(fitting: bounds.size)
            focusPath = NSBezierPath(
                roundedRect: bounds,
                xRadius: corner,
                yRadius: corner
            )
        }

        drawKeyboardFocus(
            around: focusPath,
            color: isProminent ? Design.Text.selected : Design.Surface.accent
        )

        var content = bounds.insetBy(dx: isBordered ? Layout.titleInset : Layout.plainInset, dy: 0)
        let titleWidth = self.titleWidth
        let imageWidth = image == nil ? 0 : Layout.imageSize
        let gap = titleWidth > 0 && imageWidth > 0 ? Layout.imageTitleGap : 0

        // Centred as one unit, so an icon-and-title button does not read as an icon with a label
        // hanging off it.
        var x = content.midX - (titleWidth + imageWidth + gap) / 2

        if let image {
            draw(image, in: imageRect(for: image, centredOn: content.midY, from: x))
            x += Layout.imageSize + gap
        }

        guard !title.isEmpty else { return }
        let height = ceil(titleFont.boundingRectForFont.height)
        // Drawn into whatever is left rather than into the measured width, so a squeezed button
        // truncates instead of wrapping — and measured and drawn with the *same* attributes,
        // which is what went wrong first: measuring in the regular weight and drawing in the
        // medium one left "Add Project" a hair too wide for its own rect, so it broke at the
        // space and put "Project" on a second line nobody could see.
        content = NSRect(
            x: x,
            y: content.midY - height / 2,
            width: max(0, content.maxX - x),
            height: height
        )
        (title as NSString).draw(in: content, withAttributes: titleAttributes)
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
        guard image.isTemplate, let context = NSGraphicsContext.current?.cgContext else {
            image.draw(in: rect)
            return
        }

        // Tint inside an isolated transparency layer. Applying source-in/source-atop directly
        // to the view's backing context also sees the button surface already drawn underneath,
        // and consequently paints the icon's entire bounding box as a solid rectangle.
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        foreground.set()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
        context.restoreGState()
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

    private var foreground: NSColor {
        if let contentTintColor { return dimmed(contentTintColor) }
        if isProminent { return dimmed(Design.Surface.ground) }
        // A plain button is a mark until it is wanted, so it rests in the secondary tier and
        // steps up on hover — the design system's "quiet until relevant", in one control.
        if !isBordered { return dimmed(isHovered ? Design.Text.label : Design.Text.secondary) }
        return dimmed(Design.Text.label)
    }
}
