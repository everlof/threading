import AppKit

/// A flat pill that opens a menu.
///
/// The app's standard way to offer a choice. `NSPopUpButton` was the obvious control and
/// looks wrong beside this design: its bezel and full-size chevron read as a form field,
/// where a chip is meant to sit quietly next to the content it modifies.
///
/// See `Design` for the vocabulary this belongs to.
final class ChipView: ThemedControl {

    // MARK: - Properties

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()

    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { updateHoverState() } }
    private var isPresentingMenu = false { didSet { updateBackground() } }

    /// Widens the chip to its full contents while hovered, so a label truncated to fit the row
    /// (`Default m…`) becomes readable. Held so it can be removed on exit.
    private var hoverWidthConstraint: NSLayoutConstraint?

    /// Items to offer, rebuilt each time so the menu always reflects current state.
    var menuProvider: (() -> NSMenu)?

    /// The item currently represented, so callers can read the selection back.
    private(set) var selectedItem: NSMenuItem?

    /// Called after a menu item is chosen.
    var onSelect: ((NSMenuItem) -> Void)?

    /// Replaces AppKit presentation in behavior tests. Production leaves this nil.
    var menuPresentationOverride: ((NSMenu) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Design.Size.chipHeight)
    }

    override var isEnabled: Bool {
        didSet { updateBackground() }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        applySurface(
            fill: Design.Surface.controlResting,
            radius: .pill(height: Design.Size.chipHeight)
        )

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Design.Text.secondary
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Design.Typography.control()
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingTail

        chevronView.image = NSImage(
            systemSymbolName: DesignSymbols.chevron,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.chevron, weight: .semibold))
        chevronView.contentTintColor = Design.Text.tertiary
        chevronView.translatesAutoresizingMaskIntoConstraints = false

        // The chip is the accessibility element; exposing its decorative children too would
        // make VoiceOver announce one control as three unrelated objects.
        iconView.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        chevronView.setAccessibilityElement(false)

        let stack = NSStackView(views: [iconView, titleLabel, chevronView])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.tight + 1
        stack.setCustomSpacing(Design.Spacing.tight, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Design.Size.chipHeight),
            iconView.widthAnchor.constraint(equalToConstant: Design.Symbol.control),
            iconView.heightAnchor.constraint(equalToConstant: Design.Symbol.control)
        ])

        updateBackground()
    }

    // MARK: - Public Methods

    /// Sets what the chip currently shows.
    func configure(symbolName: String?, title: String) {
        configure(
            icon: symbolName.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                    .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
            },
            title: title
        )
    }

    /// The image variant, for marks that are not SF Symbols — an agent's brand icon.
    func configure(icon: NSImage?, title: String) {
        iconView.image = icon
        iconView.isHidden = icon == nil
        titleLabel.stringValue = title
        toolTip = title
    }

    /// Selects an item by its represented value, so a rebuilt menu keeps its choice.
    func select(_ item: NSMenuItem?) {
        selectedItem = item
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        _ = presentMenu()
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { updateBackground(focused: true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { updateBackground(focused: false) }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }

        switch event.charactersIgnoringModifiers {
        case " ", "\r":
            _ = presentMenu()
        default:
            super.keyDown(with: event)
        }
    }

    /// Builds the menu and claims it, separately from showing it.
    ///
    /// Split out because `popUp` runs a modal event loop: the routing rule below — which items
    /// the chip takes over and which it leaves alone — is the part most likely to break, and
    /// inside `mouseDown` it was reachable only by opening a real menu and never tested.
    func preparedMenu() -> NSMenu? {
        guard let menu = menuProvider?() else { return nil }

        for item in menu.items where item.action == nil && !item.isSeparatorItem {
            item.target = self
            item.action = #selector(menuItemChosen(_:))
        }

        menu.minimumWidth = bounds.width
        return menu
    }

    @discardableResult
    private func presentMenu() -> Bool {
        guard isEnabled, let menu = preparedMenu() else { return false }

        isPresentingMenu = true
        defer { isPresentingMenu = false }

        if let menuPresentationOverride {
            menuPresentationOverride(menu)
        } else {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: bounds.height + Design.Spacing.tight),
                in: self
            )
        }
        return true
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        selectedItem = sender
        onSelect?(sender)
    }

    // MARK: - Private Methods

    private func updateHoverState() {
        updateBackground()
        updateHoverWidth()
    }

    /// Goes through `applySurface` rather than setting the layer's colour directly, so the fill
    /// the chip is *currently* wearing is the one recorded for `AppThemeRefresh`'s sweep. Setting
    /// it directly left the resting fill recorded forever, and a chip hovered while the theme
    /// changed was swept back to resting under the pointer until the mouse moved again.
    private func updateBackground(focused explicitFocus: Bool? = nil) {
        let focused = explicitFocus ?? (window?.firstResponder === self)
        applySurface(
            fill: isHovered || isPresentingMenu
                ? Design.Surface.controlHover
                : Design.Surface.controlResting,
            radius: .pill(height: Design.Size.chipHeight),
            border: focused ? Design.Surface.accent : nil
        )
        alphaValue = isEnabled ? 1 : 0.5
    }

    /// Pins the chip to its full contents while hovered, so a label the row squeezed into an
    /// ellipsis becomes readable. Priority sits just below required so the neighbouring chips
    /// yield their shared space to it rather than the layout breaking.
    private func updateHoverWidth() {
        hoverWidthConstraint?.isActive = false
        hoverWidthConstraint = nil

        if isHovered {
            // `fittingSize` measures the chip at its label's full, untruncated width, because
            // truncation is a drawing behaviour and does not shrink the intrinsic size.
            let fullWidth = fittingSize.width
            let constraint = widthAnchor.constraint(equalToConstant: fullWidth)
            constraint.priority = .required - 1
            constraint.isActive = true
            hoverWidthConstraint = constraint
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            context.allowsImplicitAnimation = true
            superview?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityTitle() -> String? { titleLabel.stringValue }
    override func accessibilityValue() -> Any? { selectedItem?.title ?? titleLabel.stringValue }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool { presentMenu() }
    override func accessibilityPerformShowMenu() -> Bool { presentMenu() }
}

// MARK: - Design Symbols

/// Symbols the design system uses itself, as opposed to ones a feature chooses.
enum DesignSymbols {
    static let chevron = "chevron.down"
    static let submit = "return"
    static let search = "magnifyingglass"
}
