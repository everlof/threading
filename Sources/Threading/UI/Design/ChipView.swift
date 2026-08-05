import AppKit

/// A flat pill that opens a menu.
///
/// The app's standard way to offer a choice. `NSPopUpButton` was the obvious control and
/// looks wrong beside this design: its bezel and full-size chevron read as a form field,
/// where a chip is meant to sit quietly next to the content it modifies.
///
/// See `Design` for the vocabulary this belongs to.
final class ChipView: ThemedControl {

    private enum ClassicLayout {
        static let edge: CGFloat = 2
        static let arrowWidth: CGFloat = 18
        static let textInset: CGFloat = 5
        static let triangleWidth: CGFloat = 7
        static let triangleHeight: CGFloat = 4
    }

    enum HeightStyle {
        /// A compact chooser among other compact controls.
        case compact
        /// A chooser sharing a row with a single-line text field.
        case field

        fileprivate var value: CGFloat {
            switch self {
            case .compact: return Design.Size.chipHeight
            case .field: return Design.Size.fieldHeight
            }
        }
    }

    // MARK: - Properties

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let contentStack = NSStackView()
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var contentTrailingConstraint: NSLayoutConstraint?
    private var configuredIcon: NSImage?
    private var appliedChoiceStyle: AppTheme.Material.ChoiceStyle?

    private var isPresentingMenu = false {
        didSet {
            updateBackground()
            needsDisplay = true
        }
    }
    private var menuSession: AnyObject?
    private var heightConstraint: NSLayoutConstraint?

    var heightStyle: HeightStyle = .compact {
        didSet {
            guard heightStyle != oldValue else { return }
            heightConstraint?.constant = heightStyle.value
            invalidateIntrinsicContentSize()
            updateBackground()
        }
    }

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
        NSSize(width: NSView.noIntrinsicMetric, height: heightStyle.value)
    }

    /// A neighbouring reading can align to the title's ink rather than the pill's geometric
    /// centre. The icon and chevron do not define a text baseline.
    var contentFirstBaselineAnchor: NSLayoutYAxisAnchor { titleLabel.firstBaselineAnchor }

    override var isEnabled: Bool {
        didSet { updateBackground() }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    /// ThemeRedraw invalidates drawing, while a chooser style also changes which children take
    /// part and how much trailing room the independent arrow button owns.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        needsLayout = true
    }

    override func layout() {
        updateChoiceStyleIfNeeded()
        super.layout()
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
            radius: .pill(height: heightStyle.value),
            controlGlow: true
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

        for view in [iconView, titleLabel, chevronView] {
            contentStack.addArrangedSubview(view)
        }
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = Design.Spacing.tight + 1
        contentStack.setCustomSpacing(Design.Spacing.tight, after: titleLabel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)

        let heightConstraint = heightAnchor.constraint(equalToConstant: heightStyle.value)
        self.heightConstraint = heightConstraint
        let leading = contentStack.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Design.Spacing.medium
        )
        let trailing = contentStack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Design.Spacing.medium
        )
        contentLeadingConstraint = leading
        contentTrailingConstraint = trailing
        NSLayoutConstraint.activate([
            leading,
            trailing,
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightConstraint,
            iconView.widthAnchor.constraint(equalToConstant: Design.Symbol.control),
            iconView.heightAnchor.constraint(equalToConstant: Design.Symbol.control)
        ])

        updateChoiceStyleIfNeeded()
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
        configuredIcon = icon
        iconView.image = icon
        iconView.isHidden = icon == nil || choiceStyle == .dropdown
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
        updateChoiceStyleIfNeeded()
        let focused = explicitFocus ?? (window?.firstResponder === self)
        switch choiceStyle {
        case .chip:
            applySurface(
                fill: isHovered || isPresentingMenu
                    ? Design.Surface.controlHover
                    : Design.Surface.controlResting,
                radius: .pill(height: heightStyle.value),
                border: focused ? Design.Surface.accent : nil,
                controlGlow: true
            )
        case .dropdown:
            // The editable/value half of a Win32 combo is a white sunken well. The arrow is a
            // separate raised button drawn below, not a modern glyph floating in a gray pill.
            applySurface(
                fill: Design.Surface.field,
                radius: .fixed(0),
                bevel: .sunken
            )
        }
        alphaValue = isEnabled ? 1 : 0.5
        needsDisplay = true
    }

    private var choiceStyle: AppTheme.Material.ChoiceStyle {
        AppThemePalette.current.material(for: effectiveAppearance).choiceStyle
    }

    private func updateChoiceStyleIfNeeded() {
        let style = choiceStyle
        guard style != appliedChoiceStyle else { return }
        appliedChoiceStyle = style

        switch style {
        case .chip:
            titleLabel.applyFont(.control)
            iconView.isHidden = configuredIcon == nil
            chevronView.isHidden = false
            contentLeadingConstraint?.constant = Design.Spacing.medium
            contentTrailingConstraint?.constant = -Design.Spacing.medium
        case .dropdown:
            titleLabel.applyFont(.controlRegular)
            // SF Symbols are a modern platform vocabulary. The native combo carries only its
            // value and the small filled arrow; the menu rows remain free to carry their marks.
            iconView.isHidden = true
            chevronView.isHidden = true
            contentLeadingConstraint?.constant = ClassicLayout.textInset
            contentTrailingConstraint?.constant = -(
                ClassicLayout.arrowWidth + ClassicLayout.textInset
            )
        }
        invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard choiceStyle == .dropdown else { return }

        let arrowRect = NSRect(
            x: bounds.maxX - ClassicLayout.edge - ClassicLayout.arrowWidth,
            y: ClassicLayout.edge,
            width: ClassicLayout.arrowWidth,
            height: max(0, bounds.height - ClassicLayout.edge * 2)
        )
        _ = ThemedSurface.draw(
            arrowRect,
            fill: Design.Surface.controlResting,
            radius: 0,
            bevel: isPresentingMenu ? .sunken : .automatic
        )

        let centre = NSPoint(x: arrowRect.midX, y: arrowRect.midY - 1)
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(
            x: centre.x - ClassicLayout.triangleWidth / 2,
            y: centre.y + ClassicLayout.triangleHeight / 2
        ))
        triangle.line(to: NSPoint(
            x: centre.x + ClassicLayout.triangleWidth / 2,
            y: centre.y + ClassicLayout.triangleHeight / 2
        ))
        triangle.line(to: NSPoint(x: centre.x, y: centre.y - ClassicLayout.triangleHeight / 2))
        triangle.close()
        Design.Text.label.setFill()
        triangle.fill()

        guard window?.firstResponder === self else { return }
        let valueRect = NSRect(
            x: ClassicLayout.textInset - 1,
            y: ClassicLayout.edge + 2,
            width: max(
                0,
                arrowRect.minX - ClassicLayout.textInset * 2
            ),
            height: max(0, bounds.height - ClassicLayout.edge * 2 - 4)
        )
        let focus = NSBezierPath(rect: valueRect)
        focus.lineWidth = 1
        focus.setLineDash([1, 1], count: 2, phase: 0)
        Design.Text.label.setStroke()
        focus.stroke()
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
    /// Entering annotation mode on a browser page, and being in it.
    static let annotate = "plus.bubble"
    static let annotating = "checkmark.bubble.fill"
    /// How a report ended: filed, or refused. Beside wording that already says which, so the
    /// pair carries the outcome without relying on the colour they are tinted.
    static let reportFiled = "checkmark.circle"
    static let reportRefused = "exclamationmark.triangle"
}
