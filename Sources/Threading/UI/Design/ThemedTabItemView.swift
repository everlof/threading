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
    var onContextMenu: (() -> Bool)?

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

    private let placement: Placement
    private let iconView = NSImageView()
    private let titleLabel = MorphingTitleLabel()
    private let closeButton: ThemedIconButton
    /// Public component content rendered after the title but still inside this native control.
    /// Keeping the slot here means selection, hover, focus and close remain one host-owned tab.
    let extensionAccessoryStack = NSStackView()
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

        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        iconView.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        iconView.translatesAutoresizingMaskIntoConstraints = false
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

        let content = NSStackView(
            views: [iconView, titleLabel, extensionAccessoryStack, closeButton]
        )
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        // The close button stands a step further off than the strip's own rhythm: at the strip
        // spacing it crowded the title on one side and the tab's edge on the other, since its
        // target already hugs the trailing inset. Matched in `intrinsicContentSize`.
        content.setCustomSpacing(Design.Spacing.medium, after: titleLabel)
        content.setCustomSpacing(Design.Spacing.medium, after: extensionAccessoryStack)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // Breakable, alone among these. A tab strip that collapses to nothing — the display pane
        // hides its own until two surfaces coexist — otherwise leaves every tab inside it stating
        // a height its host has just contradicted, which AppKit reports as a conflict and
        // resolves by breaking one of them anyway.
        let height = heightAnchor.constraint(equalToConstant: placement.height)
        height.priority = .required - 1

        NSLayoutConstraint.activate([
            height,
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: placement.horizontalInset
            ),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -placement.horizontalInset
            ),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Design.Size.tabIconSlot)
        ])
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

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        titleLabel.setStringValue(title, animated: isRename)
        closeButton.isHidden = !showsClose
        closeButton.setAccessibilityTitle(L10n.format("Close %@", title))

        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Shows a template image in the icon slot — an agent's own mark, where a symbol name cannot
    /// name what belongs there.
    func setIcon(_ image: NSImage?) {
        iconView.image = image
    }

    var title: String { titleLabel.stringValue }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        let closeWidth = closeButton.isHidden
            ? 0
            : Design.Spacing.medium + Design.Size.inlineButtonTarget
        let accessoryWidth = extensionAccessoryStack.isHidden
            ? 0
            : Design.Spacing.medium + ceil(extensionAccessoryStack.fittingSize.width)
        let width = placement.horizontalInset * 2
            + Design.Size.tabIconSlot
            + Design.Spacing.small
            + ceil(titleLabel.intrinsicContentSize.width)
            + accessoryWidth
            + closeWidth
        return NSSize(width: width, height: placement.height)
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
        iconView.contentTintColor = foreground
        closeButton.alphaValue = isSelected || isHovered ? 1 : 0
    }

    // MARK: - Interaction

    /// Where the press landed, kept so a drag can be told from a press with a wobble.
    private var dragOrigin: NSPoint?
    private var isDragging = false

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
        _ = onContextMenu()
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
        onContextMenu?() ?? false
    }
}
