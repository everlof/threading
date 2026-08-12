import AppKit

/// One selectable destination, wherever the app draws one: a document in the display pane's
/// strip, a page in the settings sidebar, and the active page in the window's toolbar.
///
/// # Why this is one class
///
/// It was two. The pane's strip read the chrome's roles and the toolbar's page tab read ink from
/// the terminal backdrop (`BackdropOverlay`), and that single difference had been modelled as a
/// *base class* — so everything else about a tab existed twice.
///
/// The intermediate fix was a shared constants enum: both sides read one radius, one type scale,
/// one height. It did not hold, and the reason is worth keeping. **What drifted was never the
/// metrics.** One side gained hover and press states and the other stayed inert; one faded its
/// close button in on hover and the other showed it always; one was an `NSControl` with a
/// `.radioButton` role and keyboard activation and the other was a plain `NSView` that could not
/// be clicked at all; one grew a morphing title and the other kept a text field. A shared constant
/// reaches none of that.
///
/// So the colour source became data (`InkSource`) rather than a superclass, and there is one tab.
/// Two tabs cannot look different now for the same reason two instances of any class cannot: there
/// is only one place that draws.
final class ThemedTabItemView: BackdropThemedControl {

    /// AppKit numbers the primary, secondary and middle buttons 0, 1 and 2.
    /// Buttons beyond the middle one are auxiliary navigation controls, not tab-close gestures.
    private static let middleMouseButtonNumber = 2

    /// Rounded rect rather than pill: a tab is a small container in the window's furniture, which
    /// is what `Design.Radius.control` names.
    private static var radius: CGFloat { Design.Radius.control }

    /// A **role** rather than a font, because a tab's label is a `MorphingTitleLabel` that
    /// keeps whatever `NSFont` it was handed: assigning a resolved font here left every tab in
    /// the window set in the previous theme's typeface until it was next selected.
    private static func role(isSelected: Bool) -> Design.FontRole {
        isSelected ? .control : .controlRegular
    }

    enum Placement {
        case horizontal
        case sidebar

        var height: CGFloat {
            switch self {
            case .horizontal: Design.Size.tabHeight
            case .sidebar: Design.Size.sidebarTabHeight
            }
        }

        var horizontalInset: CGFloat {
            switch self {
            case .horizontal: Design.Spacing.inset
            case .sidebar: Design.Spacing.medium
            }
        }
    }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    /// A secondary click (or an accessibility "show menu") landed on the tab. Reported rather
    /// than handled: what can be done with a tab is its strip's knowledge, not the tab's.
    /// Answers whether a menu actually opened, so the accessibility route can say so honestly
    /// — a handler that presents nothing is a "show menu" that did not happen.
    ///
    /// The anchor travels with the report, because where the menu belongs is the *gesture's*
    /// knowledge and only the tab has it: a click puts it on the pointer, and a request with no
    /// pointer behind it puts it on the tab.
    var onContextMenu: ((ThemedMenuAnchor) -> Bool)?

    /// The press turned into a drag along the strip. The tab reports the raw phases and the
    /// strip owns the geometry of reordering — the tab cannot know its neighbours.
    enum DragPhase {
        case began
        case changed
        case ended
    }

    var onDrag: ((DragPhase, NSEvent) -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            titleLabel.applyFont(Self.role(isSelected: isSelected))
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Raised over its siblings by the strip's reorder gesture.
    ///
    /// The resting fills are translucent by design — quiet over whatever ground the pane
    /// painted — but a tab *crossing another* with a translucent fill shows the crossed one
    /// through itself, which reads as a defect rather than a lift. Lifted, the same fill is
    /// flattened over the ground once (`composited(over:)`), so the traveller is opaque and
    /// nothing about its colour changes beyond no longer being see-through.
    var isLifted = false {
        didSet {
            guard isLifted != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Widest this tab may grow before its title truncates, stated as a number the tab **owns**
    /// rather than only as a constraint on it.
    ///
    /// A tab that is merely capped still reports the whole title's width as its intrinsic size,
    /// so it settles at exactly the cap — and then holds a slot its label cannot fill. Tail
    /// truncation lands on a character boundary, so the drawn line falls up to one character
    /// short of the room it was handed, and that remainder sits as dead air between the title
    /// and the ×, moving with the length of the name. Told its cap, the tab asks the label what
    /// it will really draw (`MorphingTitleLabel.width(fitting:)`) and sizes to that instead, so
    /// the gap after the title is the one the tokens state whether or not the title truncated.
    ///
    /// A host that also constrains the width should keep doing so: this makes the tab's own
    /// answer fit inside the cap, it does not enforce it.
    ///
    /// `PageTitleView` carries the same pair of properties, arrived at the same way.
    var maxWidth: CGFloat? {
        didSet {
            guard maxWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    private let placement: Placement
    private let iconView = GlyphView()
    private let titleLabel = MorphingTitleLabel()
    private let closeButton: ThemedIconButton
    /// Public component content rendered after the title but still inside this native control.
    /// Keeping the slot here means selection, hover, focus and close remain one host-owned tab.
    let extensionAccessoryStack = NSStackView()
    private lazy var content = NSStackView(
        views: [iconView, titleLabel, extensionAccessoryStack, closeButton]
    )
    private var contentTrailing: NSLayoutConstraint?
    private var isPressed = false { didSet { needsDisplay = true } }

    /// What the current title names, so a *rename* can be told from a tab being reused for
    /// something else. Only the first animates; see `update`.
    private var identity: AnyHashable?

    init(
        title: String,
        symbolName: String,
        placement: Placement,
        showsClose: Bool = false,
        inkSource: InkSource
    ) {
        self.placement = placement
        self.closeButton = ThemedIconButton(
            symbolName: "xmark",
            accessibility: L10n.format("Close %@", title),
            target: .inline,
            inkSource: inkSource
        )
        super.init(frame: .zero, inkSource: inkSource)
        setup(title: title, symbolName: symbolName, showsClose: showsClose)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(title: String, symbolName: String, showsClose: Bool) {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = Design.Symbol.image(
            symbolName,
            slot: Design.Size.tabIconSlot,
            pointSize: Design.Symbol.control
        )
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.applyFont(Self.role(isSelected: isSelected))
        titleLabel.setStringValue(title, animated: false)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        closeButton.onPress = { [weak self] in self?.onClose?() }
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !showsClose

        extensionAccessoryStack.orientation = .horizontal
        extensionAccessoryStack.alignment = .centerY
        extensionAccessoryStack.spacing = Design.Spacing.tight
        extensionAccessoryStack.translatesAutoresizingMaskIntoConstraints = false
        extensionAccessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        extensionAccessoryStack.isHidden = true

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        // **The title takes any room the tab has spare, so the × keeps the trailing inset.**
        // A tab is not always free to be as wide as its content — a host may hold it to a floor
        // so its strip does not resize itself around every name, as the window's header once did
        // for the page tab. Under the stack's default `.gravityAreas` that extra width went
        // *after* the last view — a short name left the × sitting 43pt inboard of a tab whose
        // fill ran to the edge, which reads as a tab with its contents shoved left. Filling puts
        // the slack in the one view that can absorb it without moving anything: the title, whose
        // line is drawn from its leading edge either way.
        content.distribution = .fill
        titleLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        applyCloseSpacing()

        // Breakable, alone among these. A tab strip that collapses to nothing — the display pane
        // hides its own until two surfaces coexist — otherwise leaves every tab inside it stating
        // a height its host has just contradicted, which AppKit reports as a conflict and
        // resolves by breaking one of them anyway.
        let height = heightAnchor.constraint(equalToConstant: placement.height)
        height.priority = .required - 1

        let trailing = content.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -trailingContentInset
        )
        contentTrailing = trailing

        NSLayoutConstraint.activate([
            height,
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: placement.horizontalInset
            ),
            trailing,
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Design.Size.tabIconSlot)
        ])
    }

    // MARK: - Close Button Geometry

    /// The padding `ThemedIconButton` holds around the × — click target, not ink.
    ///
    /// Spacing that ignores it puts the visible glyph that much further out on **both** sides:
    /// with a 20pt target around a 12pt glyph, the stated "10pt after the title" reads as 14 and
    /// the "12pt from the tab's edge" as 16, while the leading icon — a 14pt symbol in a 16pt
    /// slot — sits on the 12 it was given. That is the difference the eye reads as a tab whose
    /// contents are shoved left. Every other container that places one of these already
    /// subtracts it — `PaneHeaderView`, `PaneFooterView`, both sidebar rows — via
    /// `OpticalInsetProviding`; the tab was the one that did not, and it shows it most, having a
    /// control at one end of a short row and a title at the other.
    private var closeOpticalInset: CGFloat {
        closeButton.isHidden ? 0 : closeButton.opticalHorizontalInset
    }

    /// The trailing inset applied to the content, measured so that whatever ends the row lands
    /// its *ink* on `placement.horizontalInset`.
    private var trailingContentInset: CGFloat {
        placement.horizontalInset - closeOpticalInset
    }

    /// The gap before the close button: `Design.Spacing.medium` to its glyph.
    ///
    /// The close button stands a step further off than the strip's own rhythm — at the strip
    /// spacing it crowded the title on one side and the tab's edge on the other — and that step
    /// is now stated where it is seen. Matched in `intrinsicContentSize`.
    private var spacingBeforeClose: CGFloat {
        Design.Spacing.medium - closeOpticalInset
    }

    /// Restates the spacing that depends on which of the trailing views are showing. The stack
    /// gives a hidden arranged view no room, so the gap "after the title" is the gap to the
    /// accessory slot or to the × depending on what survives.
    private func applyCloseSpacing() {
        content.setCustomSpacing(
            extensionAccessoryStack.isHidden ? spacingBeforeClose : Design.Spacing.medium,
            after: titleLabel
        )
        content.setCustomSpacing(spacingBeforeClose, after: extensionAccessoryStack)
        contentTrailing?.constant = -trailingContentInset
    }

    // MARK: - Content

    /// Re-points an existing tab at something else, or renames what it already shows.
    ///
    /// `identity` is what tells those apart. A title that changed while the identity stayed put is
    /// a rename and morphs; a tab handed a new identity is showing a different thing and lands its
    /// title directly, because animating between two unrelated names reads as a glitch rather than
    /// as a change. The display pane builds a fresh tab per update and passes none; the toolbar
    /// keeps one instance for the life of the window and passes the session's id.
    func update(
        title: String,
        symbolName: String,
        showsClose: Bool,
        identity: AnyHashable? = nil
    ) {
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
        closeButton.isHidden = !showsClose
        closeButton.setAccessibilityTitle(L10n.format("Close %@", title))

        // A tab that gained or lost its × changed where the row ends, and the compensation for
        // the button's own padding goes with it.
        applyCloseSpacing()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Shows a template image in the icon slot — an agent's own mark, where a symbol name cannot
    /// name what belongs there. Capped to the slot, because the artwork's natural size is the
    /// artist's rather than the tab's.
    func setIcon(_ image: NSImage?) {
        iconView.slot = NSSize(width: Design.Size.tabIconSlot, height: Design.Size.tabIconSlot)
        iconView.image = image
    }

    var title: String { titleLabel.stringValue }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        let width = everythingButTheTitle + ceil(titleWidth)
        return NSSize(
            width: maxWidth.map { min(width, $0) } ?? width,
            height: placement.height
        )
    }

    /// Every fixed part of the row, in the order it is laid out: the two insets, the icon slot
    /// and its gap, the accessory slot and its gap, the × and its gap.
    private var everythingButTheTitle: CGFloat {
        let closeWidth = closeButton.isHidden
            ? 0
            : spacingBeforeClose + Design.Size.inlineButtonTarget
        let accessoryWidth = extensionAccessoryStack.isHidden
            ? 0
            : Design.Spacing.medium + ceil(extensionAccessoryStack.fittingSize.width)
        return placement.horizontalInset
            + trailingContentInset
            + Design.Size.tabIconSlot
            + Design.Spacing.small
            + accessoryWidth
            + closeWidth
    }

    /// What the title contributes: the width it *wants* where the tab is free to grow, and the
    /// width it will actually **draw** where the tab is capped — see `maxWidth`.
    private var titleWidth: CGFloat {
        guard let maxWidth else { return titleLabel.intrinsicContentSize.width }
        return titleLabel.width(fitting: max(0, maxWidth - everythingButTheTitle))
    }

    // MARK: - Drawing

    /// The label and the mark, from the ink this tab was told to read.
    ///
    /// `draw(_:)` sets these too, because the ink can move without the view being re-inked — a
    /// hover changes which tier the label should be. This is the ground-change path.
    override func applyInk(_ ink: Design.Ink) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let foreground: NSColor
        var fill: NSColor

        if isSelected {
            foreground = ink.label
            // The resting weight, not the hover one. A selected tab is a *place*, not a control
            // being pressed: at the hover weight it read as the loudest thing in the pane and its
            // own label had to compete with it.
            fill = isHovered ? ink.surfaceHover : ink.surface
        } else if isPressed || isHovered || hasKeyboardFocus {
            foreground = ink.label
            fill = ink.surface
        } else {
            foreground = ink.secondary
            fill = .clear
        }

        if isLifted {
            fill = fill.composited(over: inkSource.ground)
        }

        // No border in any state. The fill and the label weight already carry selection, and a
        // stroked rounded rect made the selected tab the one outlined control in its row — a
        // hard edge the close button then sat visibly tight against. Selection here follows the
        // app's other resting surfaces: a quiet fill, not a frame.
        let shape = ThemedSurface.draw(
            bounds,
            fill: fill,
            border: nil,
            radius: Self.radius
        )
        drawKeyboardFocus(around: shape)

        titleLabel.textColor = foreground
        // The icon follows its label rather than taking the accent. The accent means "this needs
        // you" everywhere else in the app — the sidebar's attention dot is the same colour — and
        // spending it on whichever tab happens to be open says that about nothing.
        iconView.tint = foreground
        closeButton.alphaValue = isSelected || isHovered ? 1 : 0
    }

    // MARK: - Interaction

    /// Where the press landed, kept so a drag can be told from a press with a wobble.
    private var dragOrigin: NSPoint?
    private var isDragging = false
    private var isTrackingMiddleClose = false
    private var isMiddleCloseInside = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        dragOrigin = event.locationInWindow
        window?.makeFirstResponder(self)
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, onDrag != nil, let origin = dragOrigin else { return }
        if isDragging {
            onDrag?(.changed, event)
            return
        }
        // A slop before the drag begins, so selecting a tab with an unsteady hand stays a
        // selection rather than a one-point reorder.
        let moved = max(
            abs(event.locationInWindow.x - origin.x),
            abs(event.locationInWindow.y - origin.y)
        )
        guard moved > Design.Spacing.tight else { return }
        isDragging = true
        onDrag?(.began, event)
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        dragOrigin = nil
        if isDragging {
            isDragging = false
            onDrag?(.ended, event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled, let onContextMenu else {
            super.rightMouseDown(with: event)
            return
        }
        _ = onContextMenu(.pointer(event.locationInWindow))
    }

    /// The standard tab gesture: a middle-button click closes without selecting first.
    ///
    /// Like the tab's visible close button, this is an action and therefore fires on release.
    /// Tracking the pointer also preserves the platform's change-your-mind affordance: dragging
    /// away before releasing cancels the close.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == Self.middleMouseButtonNumber,
              isEnabled,
              onClose != nil
        else {
            super.otherMouseDown(with: event)
            return
        }

        isTrackingMiddleClose = true
        isMiddleCloseInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == Self.middleMouseButtonNumber,
              isTrackingMiddleClose
        else {
            super.otherMouseDragged(with: event)
            return
        }

        isMiddleCloseInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == Self.middleMouseButtonNumber,
              isTrackingMiddleClose
        else {
            super.otherMouseUp(with: event)
            return
        }

        let shouldClose = isEnabled
            && isMiddleCloseInside
            && bounds.contains(convert(event.locationInWindow, from: nil))
        isTrackingMiddleClose = false
        isMiddleCloseInside = false
        if shouldClose { onClose?() }
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        onSelect?()
        return true
    }

    /// Labels make no claim on the pointer; the close button is the one intentional child target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies `point` in the superview's coordinate space. The tab can sit anywhere
        // in a stack or toolbar, so comparing that point directly with our zero-based bounds
        // makes every offset tab miss.
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        let closePoint = closeButton.convert(localPoint, from: self)
        if !closeButton.isHidden, closeButton.bounds.contains(closePoint) {
            return closeButton
        }
        return self
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityTitle() -> String? { titleLabel.stringValue }
    override func accessibilityValue() -> Any? { isSelected }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    /// The same menu the secondary click opens, so everything a pointer can do to a tab —
    /// reorder it, move it — is reachable without one.
    override func accessibilityPerformShowMenu() -> Bool {
        onContextMenu?(.control) ?? false
    }
}
