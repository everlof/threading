import AppKit

/// Every icon-only button in the app: the toolbar's actions, a tab's close, a sidebar row's `⋯`.
///
/// **One component, because padding is a property of the system and not of a call site.** These
/// were three separate treatments — a toolbar button, a `ThemedButton` with `isBordered = false`
/// and a hand-set `hoverFill`, and a bare button squeezed into a row's fixed slot — each stating
/// its own target size, its own glyph size and therefore its own padding. The `⋯` in a sidebar row
/// and the `×` in a tab sat at visibly different insets for no reason anyone chose.
///
/// So a caller names the **role** (`Target`) rather than a size. There is no `NSSize` parameter:
/// that is the seam a fourth, slightly-different button would come in through.
///
/// It draws from an `InkSource` rather than the chrome roles, which is what lets the same button
/// serve the toolbar — floating over the terminal's own palette — and a tab inside the chrome.
final class ThemedIconButton: BackdropThemedControl, OpticalInsetProviding {

    /// What an icon button is for, which is what decides how big it is and how much air the glyph
    /// gets. Padding is the difference between the two, so stating both here is what makes it a
    /// system rule instead of arithmetic repeated at each call site.
    enum Target {

        /// A top-level action in the window's chrome.
        case toolbar

        /// Nested inside another control — a tab's close, a row's actions.
        case inline

        var size: NSSize {
            switch self {
            case .toolbar:
                NSSize(
                    width: Design.Size.toolbarButtonWidth,
                    height: Design.Size.toolbarButtonHeight
                )
            case .inline:
                NSSize(
                    width: Design.Size.inlineButtonTarget,
                    height: Design.Size.inlineButtonTarget
                )
            }
        }

        /// The glyph inside. The remainder is the padding, equal on every side.
        var glyph: CGFloat {
            switch self {
            case .toolbar: Design.Size.tabIconSlot
            case .inline: Design.Size.inlineButtonGlyph
            }
        }

        /// What the resting hover lifts to, which depends on what the button is sitting on.
        ///
        /// A toolbar button sits on the bare backdrop, so `surface` is a lift. An inline one sits
        /// on another control's fill — which is *already* `surface` — so the same value is
        /// invisible and it has to go a step further. This was previously a `hoverFill` set by
        /// hand at the one call site that had noticed; stating it per role is what stops the next
        /// nested button from being the one that did not.
        var hoverFill: KeyPath<Design.Ink, NSColor> {
            switch self {
            case .toolbar: \.surface
            case .inline: \.surfaceHover
            }
        }
    }

    var onPress: (() -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isSelected)
        }
    }

    private let iconView = NSImageView()
    private var accessibilityName: String
    private let isEmphasized: Bool
    private let actionTarget: Target
    private var isPressed = false { didSet { needsDisplay = true } }

    init(
        symbolName: String,
        accessibility: String,
        target: Target = .toolbar,
        isEmphasized: Bool = false,
        inkSource: InkSource = .backdrop
    ) {
        self.accessibilityName = accessibility
        self.isEmphasized = isEmphasized
        self.actionTarget = target
        super.init(frame: .zero, inkSource: inkSource)
        setup(symbolName: symbolName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(symbolName: String) {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        iconView.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // The glyph is centred and the target states its own size, so the padding is whatever is
        // left over — equal on all four sides, by construction rather than by a caller's
        // arithmetic. Nothing here takes a size from outside.
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: actionTarget.size.width),
            heightAnchor.constraint(equalToConstant: actionTarget.size.height),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: actionTarget.glyph),
            iconView.heightAnchor.constraint(equalToConstant: actionTarget.glyph)
        ])
    }

    override var intrinsicContentSize: NSSize { actionTarget.size }

    /// The padding the role holds around its glyph — `(target − glyph) / 2`, stated by the
    /// role by construction. What `PaneFooterView` subtracts to put the ink on a margin.
    var opticalHorizontalInset: CGFloat {
        (actionTarget.size.width - actionTarget.glyph) / 2
    }

    /// Re-points the button at a different action, keeping its size and padding.
    ///
    /// One slot, two roles: a project row's `⋯` and a branch heading's gear are the same control
    /// in the same place, and swapping the glyph is the whole difference between them.
    func setSymbol(_ symbolName: String, accessibility: String) {
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        accessibilityName = accessibility
        setAccessibilityTitle(accessibility)
    }

    override func applyInk(_ ink: Design.Ink) {
        iconView.contentTintColor = isEnabled ? ink.secondary : ink.quaternary
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = isSelected || isEmphasized
        let fill: NSColor
        if isPressed {
            fill = ink.surfaceHover
        } else if active {
            fill = isHovered ? ink.surfaceHover : ink.surface
        } else {
            fill = isHovered ? ink[keyPath: actionTarget.hoverFill] : .clear
        }

        let border = active ? ink.border : nil
        // A rounded rect, not a pill. These are square, so a pill radius is a *circle*, and a row
        // of circles beside the rounded tabs and chips they sit with reads as a second silhouette
        // in one strip of chrome. `Design.Radius.control` is the one a theme states for exactly
        // this: small things nested in the window's own furniture.
        let path = ThemedSurface.draw(
            bounds,
            fill: fill,
            border: border,
            radius: Design.Radius.control(fitting: bounds.size)
        )

        if window?.firstResponder === self {
            ink.label.setStroke()
            path.lineWidth = Design.Accessibility.focusRingWidth
            path.stroke()
        }

        iconView.contentTintColor = isEnabled
            ? (isSelected || isHovered ? ink.label : ink.secondary)
            : ink.quaternary
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFire = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldFire { performPress() }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool {
        performPress()
    }

    override func performPrimaryAction() -> Bool {
        performPress()
    }

    @discardableResult
    private func performPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}
