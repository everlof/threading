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

    private var isPresentingMenu = false { didSet { updateBackground() } }
    private var menuSession: AnyObject?

    /// Widens the chip to its full contents while hovered, so a label truncated to fit the row
    /// (`Default m…`) becomes readable. Held so it can be removed on exit.
    private var hoverWidthConstraint: NSLayoutConstraint?

    /// Choices to offer, rebuilt each time so the menu always reflects current state.
    var itemsProvider: (() -> [ThemedMenuEntry])?

    /// The item currently represented, so callers can read the selection back.
    private(set) var selectedItem: ThemedMenuItem?

    /// Called after a menu item is chosen.
    var onSelect: ((ThemedMenuItem) -> Void)?

    /// Replaces AppKit presentation in behavior tests. Returning a choice simulates selecting it.
    /// Production leaves this nil.
    var menuPresentationOverride: ((ThemedMenuPresentation) -> ThemedMenuItem?)?

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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            ThemedMenuPresenter.dismiss(menuSession)
        }
        super.viewWillMove(toWindow: newWindow)
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

        titleLabel.applyFont(.control)
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
    func select(_ item: ThemedMenuItem?) {
        selectedItem = item
    }

    // MARK: - Interaction

    /// The chip's hover is a fill *and* a width, so it answers the base's hook rather than
    /// redrawing: see `updateHoverWidth`.
    override func hoverDidChange() {
        super.hoverDidChange()
        updateHoverState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        _ = presentMenu()
    }

    // The press that opened the menu may still be held. AppKit keeps routing its drag and
    // release here — the mouse-down view — so both are forwarded to the menu, which is what
    // makes press-drag-release choose a row the way every platform menu does.
    override func mouseDragged(with event: NSEvent) {
        guard let menuSession else { return }
        ThemedMenuPresenter.dragUpdated(menuSession, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let menuSession else { return }
        ThemedMenuPresenter.dragEnded(menuSession, event: event)
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

    /// Builds the semantic presentation separately from showing it. Kept internal for behavior
    /// tests without exposing the contained AppKit menu.
    func preparedPresentation() -> ThemedMenuPresentation? {
        guard let entries = itemsProvider?(),
              entries.contains(where: {
                  if case .item = $0 { return true }
                  return false
              })
        else { return nil }

        return ThemedMenuPresentation(entries: entries, minimumWidth: bounds.width)
    }

    @discardableResult
    private func presentMenu() -> Bool {
        guard isEnabled, menuSession == nil, let presentation = preparedPresentation() else {
            return false
        }

        if let menuPresentationOverride {
            isPresentingMenu = true
            defer { isPresentingMenu = false }
            if let selected = menuPresentationOverride(presentation) {
                choose(selected)
            }
        } else {
            let selectedIndex = presentation.entries.firstIndex { entry in
                guard case .item(let item) = entry else { return false }
                return item.isSelected
            }
            isPresentingMenu = true
            menuSession = ThemedMenuPresenter.present(
                presentation,
                from: self,
                selectedEntryIndex: selectedIndex,
                onChoose: { [weak self] _, item in self?.choose(item) },
                onDismiss: { [weak self] in
                    self?.menuSession = nil
                    self?.isPresentingMenu = false
                }
            )
            if menuSession == nil {
                isPresentingMenu = false
                return false
            }
        }
        return true
    }

    private func choose(_ item: ThemedMenuItem) {
        selectedItem = item
        item.onChoose?()
        onSelect?(item)
        NSAccessibility.post(element: self, notification: .valueChanged)
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
    static let removeAttachment = "xmark"
}
