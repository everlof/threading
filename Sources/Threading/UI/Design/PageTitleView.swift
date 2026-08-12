import AppKit

/// The content pane's header names what is on screen: a mark, the page's title, and the one
/// menu that acts on it.
///
/// # Why this is not a tab
///
/// It was one — a `ThemedTabItemView` with a close box, and a `+` beside it. Every part of that
/// grammar promised something the window does not do. There is exactly one page here and there
/// can only ever be one, because opening a page swaps the whole workspace (see
/// `sessions.md`, "Why Sessions Are Not Tabs"); the sidebar is the switcher. A single chip drawn
/// as a *selected tab* says the opposite — that it is one of a set, with the rest just out of
/// view — and the `+` completed the lie: pressed, it did not add a second tab beside this one,
/// it started a session that took this one's place. The × had the same problem from the other
/// end, reading as "close this document" for a gesture that only empties the pane while the
/// session keeps running.
///
/// So the plate, the ×, and the `+` are gone. What is left is what a header is for: the mark,
/// the name, and the actions. `⌘W` still clears the pane and `⌘N` still starts a session — the
/// affordances that misdescribed those actions are what went, not the actions.
///
/// # What is still a control
///
/// The title is pressable and reveals its row in the sidebar, which is the question a page
/// name raises when the list has scrolled somewhere else. **It says so only under the pointer**
/// — a quiet plate behind the mark and the title, and nothing at rest. That is the difference
/// between this and the tab it replaces: a tab is a place and draws its fill whether or not
/// anybody is looking at it, while this is a label that happens to answer a press.
final class PageTitleView: BackdropThemedControl {

    /// Rounded rect rather than pill, matching every other small container in the chrome.
    private static var radius: CGFloat { Design.Radius.control }

    /// How far the hover plate reaches past the ink it holds. Small on purpose: the plate is
    /// feedback, not furniture, and the header's own `PaneHeaderDefaults.inset` is what places
    /// the mark against the pane's edge.
    private static var platePadding: CGFloat { Design.Spacing.small }

    /// The title was pressed — reveal this page wherever it lives.
    var onReveal: (() -> Void)?

    /// The `⋯` was pressed. The button travels with the report because the menu hangs off it.
    var onActions: ((ThemedIconButton) -> Void)?

    private let iconView = GlyphView()
    private let titleLabel = MorphingTitleLabel()
    private let actionsButton: ThemedIconButton
    private var isPressed = false { didSet { needsDisplay = true } }

    /// What the current title names, so a *rename* can be told from the header being pointed at
    /// something else. Only the first animates; see `update`.
    private var identity: AnyHashable?

    /// Widest the title may grow before it truncates. Stated as a number the view owns rather
    /// than only as a constraint on it, for the same reason `ThemedTabItemView.maxWidth` is:
    /// a merely capped label reports the whole title's width and then holds room it cannot fill.
    var maxWidth: CGFloat? {
        didSet {
            guard maxWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    init(symbolName: String, inkSource: InkSource) {
        actionsButton = ThemedIconButton(
            symbolName: "ellipsis",
            accessibility: L10n.string("Session context menu"),
            target: .inline,
            inkSource: inkSource
        )
        super.init(frame: .zero, inkSource: inkSource)
        setup(symbolName: symbolName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(symbolName: String) {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = Design.Symbol.image(
            symbolName,
            slot: Design.Size.tabIconSlot,
            pointSize: Design.Symbol.control
        )
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.applyFont(.control)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // **This view hugs; the header's spacer is what takes the slack.** A tab is often held
        // wider than it wants to be and hands the extra width to its title, and copying that here
        // was wrong in a way only a hit test showed: the label stretched to whatever the header
        // row had spare, so the hover plate — measured from the label — ran the width of the pane
        // and a click anywhere in that empty strip revealed the page. At `.defaultHigh` against
        // the spacer's `.defaultLow`, the name is as wide as the name.
        setContentHuggingPriority(.defaultHigh, for: .horizontal)

        actionsButton.toolTip = L10n.string("Context")
        actionsButton.presentsMenu = true
        actionsButton.onPress = { [weak self] in
            guard let self else { return }
            self.onActions?(self.actionsButton)
        }
        actionsButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [iconView, titleLabel, actionsButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        content.distribution = .fill
        // The `⋯` stands a step off the name rather than at the row's own rhythm, minus what the
        // button holds around its own glyph as click target — the same correction every other
        // container that places one of these makes. See `ThemedTabItemView.spacingBeforeClose`.
        content.setCustomSpacing(spacingBeforeActions, after: titleLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // Breakable, like the tab's: a header laid out before it has been given its band height
        // otherwise reports a conflict AppKit resolves by breaking one of them anyway.
        let height = heightAnchor.constraint(equalToConstant: Design.Size.tabHeight)
        height.priority = .required - 1

        NSLayoutConstraint.activate([
            height,
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.platePadding
            ),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -trailingContentInset
            ),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Design.Size.tabIconSlot)
        ])
    }

    // MARK: - Geometry

    /// The gap between the title and the `⋯`, measured to its glyph rather than to its target.
    private var spacingBeforeActions: CGFloat {
        max(0, Design.Spacing.medium - actionsButton.opticalHorizontalInset)
    }

    /// Where the row ends, measured so the `⋯`'s *ink* lands on the plate padding.
    private var trailingContentInset: CGFloat {
        Self.platePadding - actionsButton.opticalHorizontalInset
    }

    /// Every fixed part of the row, in the order it is laid out.
    private var everythingButTheTitle: CGFloat {
        Self.platePadding
            + trailingContentInset
            + Design.Size.tabIconSlot
            + Design.Spacing.small
            + spacingBeforeActions
            + Design.Size.inlineButtonTarget
    }

    /// What the title contributes: the width it wants where the header is free to grow, and the
    /// width it will actually **draw** where it is capped.
    private var titleWidth: CGFloat {
        guard let maxWidth else { return titleLabel.intrinsicContentSize.width }
        return titleLabel.width(fitting: max(0, maxWidth - everythingButTheTitle))
    }

    override var intrinsicContentSize: NSSize {
        let width = everythingButTheTitle + ceil(titleWidth)
        return NSSize(
            width: maxWidth.map { min(width, $0) } ?? width,
            height: Design.Size.tabHeight
        )
    }

    /// The hover plate: the mark and the name, not the `⋯`. The button answers a press of its
    /// own and draws its own feedback for it, so including it would put two plates under one
    /// pointer and say the whole row was one target.
    private var plateRect: NSRect {
        // Converted, not read: the label sits inside the content stack, so its own `frame` is in
        // that stack's coordinates and a plate measured from it comes out short by the stack's
        // leading inset — the padding after the name would silently be smaller than the padding
        // before the mark.
        let label = convert(titleLabel.bounds, from: titleLabel)
        // **The plate hugs the ink, not the slot.** This view hugs its content, so ordinarily
        // the two are the same — but a host that hands it more width than it asked for gives
        // that width to the label, and a plate measured from the label's *frame* then runs to
        // the edge of the pane with a click target behind it. Measured from what the line
        // actually draws, an over-wide host costs nothing but empty header.
        let ink = min(label.width, ceil(titleLabel.intrinsicContentSize.width))
        let trailing = label.minX + ink + Self.platePadding
        return NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(0, min(trailing, bounds.maxX) - bounds.minX),
            height: bounds.height
        )
    }

    // MARK: - Content

    /// Re-points the header at something else, or renames what it already names.
    ///
    /// `identity` is what tells those apart, exactly as it does for a tab: a title that changed
    /// under the same identity is a rename and morphs, while a new identity lands its title
    /// directly — animating between two unrelated names reads as a glitch rather than a change.
    func update(title: String, symbolName: String, identity: AnyHashable? = nil) {
        let isRename = identity != nil
            && identity == self.identity
            && title != titleLabel.stringValue
        self.identity = identity

        iconView.slot = nil
        iconView.image = Design.Symbol.image(
            symbolName,
            slot: Design.Size.tabIconSlot,
            pointSize: Design.Symbol.control
        )
        titleLabel.setStringValue(title, animated: isRename)
        setAccessibilityTitle(title)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Shows a template image in the mark's slot — an agent's own brand, where a symbol name
    /// cannot name what belongs there. Capped to the slot, since the artwork's natural size is
    /// the artist's rather than the header's.
    func setIcon(_ image: NSImage?) {
        iconView.slot = NSSize(width: Design.Size.tabIconSlot, height: Design.Size.tabIconSlot)
        iconView.image = image
    }

    var title: String { titleLabel.stringValue }

    /// The `⋯` itself: what the actions menu hangs off, and what the window's own state pass
    /// stands down when there is no session for the menu to act on.
    var actionsAnchor: ThemedIconButton { actionsButton }

    // MARK: - Drawing

    override func applyInk(_ ink: Design.Ink) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Nothing at rest. The plate is feedback for a press that is about to be possible, and
        // a header that carried one all the time would be the tab this replaced.
        let fill: NSColor = isPressed || isHovered || hasKeyboardFocus ? ink.surface : .clear
        let shape = ThemedSurface.draw(
            plateRect,
            fill: fill,
            border: nil,
            radius: Self.radius
        )
        drawKeyboardFocus(around: shape)

        // The page's name is the loudest thing in this strip, and its mark follows it — the
        // accent means "this needs you" everywhere else in the app.
        titleLabel.textColor = ink.label
        iconView.tint = isHovered ? ink.label : ink.secondary
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard wasPressed, isEnabled,
              plateRect.contains(convert(event.locationInWindow, from: nil))
        else { return }
        onReveal?()
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        onReveal?()
        return true
    }

    /// The name and the mark make no claim on the pointer; the `⋯` is the one child target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        let buttonPoint = actionsButton.convert(localPoint, from: self)
        if actionsButton.bounds.contains(buttonPoint) { return actionsButton }
        return plateRect.contains(localPoint) ? self : nil
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { titleLabel.stringValue }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}
