import AppKit

/// The title band a chrome-takeover theme draws across the window's top: gradient, title, the
/// window identity, and the window's own buttons. Application commands live in the command
/// band below it; title-bar geometry should never depend on toolbar-sized controls.
///
/// This is the app-drawn half of what `.titled` provided. The behaviours a titlebar owes its
/// window are re-stated here one for one — a press drags the window, a double-click performs
/// the user's own System Settings choice (`TitlebarDoubleClick`, the same reading
/// `TitlebarActionWindow` does in native dress), and the band dims when the window is not key,
/// which is how a window has said "not me" since windows could overlap.
///
/// The gradient is drawn in `draw(_:)` rather than laid into a layer, the `ThemedControl`
/// lesson: a live theme switch repaints it with nothing to re-freeze. The title follows
/// `window.title` by observation, so whatever names the window names the band.
final class WindowTitleBandView: NSView, ThemedComponent {

    /// What a double-click performs — a closure for the same reason `TitlebarActionWindow`
    /// holds one: the gesture is only worth asserting against a known answer.
    var doubleClickAction: () -> TitlebarDoubleClick.Action = { TitlebarDoubleClick.preferredAction }

    /// A style stated by a fixture instead of resolved from the active theme; handed on to
    /// the band's own buttons so the cluster previews as one piece.
    var fixtureStyle: WindowChromeAppearance.Resolved? {
        didSet {
            [menuButton, minimizeButton, zoomButton, closeButton, depthButton].forEach {
                $0.fixtureStyle = fixtureStyle
            }
            apply()
        }
    }

    /// Key-state stated by a fixture, for the same reason: an unshown render window is never
    /// key, so without this the band's hero form — the active gradient — is unrenderable.
    var fixtureIsKey: Bool? {
        didSet {
            [menuButton, minimizeButton, zoomButton, closeButton, depthButton].forEach {
                $0.fixtureIsKey = fixtureIsKey
            }
            apply()
        }
    }

    private var resolvedStyle: WindowChromeAppearance.Resolved? {
        fixtureStyle ?? WindowChromeAppearance.resolve()
    }

    private var drawsAsKey: Bool {
        fixtureIsKey ?? (window == nil || window?.isKeyWindow == true)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let appIcon = NSImageView()
    private let leftStack = NSStackView()
    private let leadingButtonStack = NSStackView()
    private let leadingStack = NSStackView()
    private let buttonStack = NSStackView()
    private let contentGuide = NSLayoutGuide()
    private(set) lazy var menuButton = WindowChromeButton(role: .windowMenu)
    private(set) lazy var minimizeButton = WindowChromeButton(role: .minimize)
    private(set) lazy var zoomButton = WindowChromeButton(role: .zoom)
    private(set) lazy var closeButton = WindowChromeButton(role: .close)
    private(set) lazy var depthButton = WindowChromeButton(role: .depth)

    private let appEvents = AppEventObservations()
    nonisolated(unsafe) private var windowStateObservations: [NSObjectProtocol] = []
    private var centeredTitleConstraint: NSLayoutConstraint?
    private var leadingTitleConstraint: NSLayoutConstraint?
    private var fullWidthContentConstraint: NSLayoutConstraint?
    private var tabWidthContentConstraint: NSLayoutConstraint?

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        windowStateObservations.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Contents

    /// What the band is currently titling the window, for a test to hold against what was
    /// set without reaching into the label.
    var displayedTitle: String { titleLabel.stringValue }

    /// The resolved regional layout, exposed semantically for component tests. The stacks
    /// remain private implementation details; callers can only ask which window operations
    /// the title band placed on either side and whether it retained the identity icon.
    var leadingWindowButtonRoles: [WindowChromeButton.Role] {
        leadingButtonStack.arrangedSubviews.compactMap {
            ($0 as? WindowChromeButton)?.role
        }
    }

    var trailingWindowButtonRoles: [WindowChromeButton.Role] {
        buttonStack.arrangedSubviews.compactMap {
            ($0 as? WindowChromeButton)?.role
        }
    }

    var showsApplicationIcon: Bool { !appIcon.isHidden }

    /// Width occupied by the current title shape. Exposed as geometry rather than a private
    /// guide so tests can distinguish a genuine BeOS tab from a full-width yellow strip.
    var occupiedTitleWidth: CGFloat {
        switch resolvedStyle?.shape ?? .fullWidth {
        case .fullWidth: bounds.width
        case .leadingTab: min(resolvedStyle?.tabWidth ?? 0, bounds.width)
        }
    }

    /// The window controller pushes the title — it owns `updateWindowTitle` and is the one
    /// place the name is decided. Deliberately not KVO on `window.title`: the band lives in
    /// the window's own view tree, so on window dealloc an observation would unregister
    /// against an object mid-teardown, which is the deferred-detonation shape this feature
    /// already met once in `_NSWindowTransformAnimation`.
    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    /// An optional title-bar leading slot retained for authored previews and future identity
    /// furniture. Its guests keep their own semantic size; forcing toolbar controls down to the
    /// caption-button height created two conflicting required constraints.
    func setLeadingControls(_ views: [NSView]) {
        leadingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            leadingStack.addArrangedSubview(view)
        }
    }

    // MARK: - Setup

    private func setup() {
        addLayoutGuide(contentGuide)
        appIcon.image = NSApplication.shared.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appIcon.setAccessibilityElement(false)

        leadingButtonStack.orientation = .horizontal
        leadingButtonStack.alignment = .centerY
        leadingButtonStack.spacing = Design.Spacing.hairline

        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = Design.Spacing.tight

        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = Design.Spacing.hairline
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        [leadingButtonStack, appIcon, leadingStack].forEach(leftStack.addArrangedSubview)
        addSubview(leftStack)

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = Design.Spacing.hairline
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        [minimizeButton, zoomButton, closeButton, depthButton].forEach(buttonStack.addArrangedSubview)
        addSubview(buttonStack)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.applyFont(.detail(weight: .bold))
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        let leadingTitle = titleLabel.leadingAnchor.constraint(
            equalTo: leftStack.trailingAnchor,
            constant: Design.Spacing.medium
        )
        leadingTitleConstraint = leadingTitle
        centeredTitleConstraint = titleLabel.centerXAnchor.constraint(
            equalTo: contentGuide.centerXAnchor
        )

        let fullWidthContent = contentGuide.trailingAnchor.constraint(equalTo: trailingAnchor)
        let tabWidthContent = contentGuide.widthAnchor.constraint(
            equalToConstant: WindowChromeStyleLimits.defaultTabWidth
        )
        fullWidthContentConstraint = fullWidthContent
        tabWidthContentConstraint = tabWidthContent

        NSLayoutConstraint.activate([
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 14),
            appIcon.heightAnchor.constraint(equalToConstant: 14),

            contentGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentGuide.topAnchor.constraint(equalTo: topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentGuide.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            fullWidthContent,

            leftStack.leadingAnchor.constraint(
                equalTo: contentGuide.leadingAnchor,
                constant: Design.Spacing.tight
            ),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            buttonStack.trailingAnchor.constraint(
                equalTo: contentGuide.trailingAnchor,
                constant: -Design.Spacing.tight
            ),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingTitle,
            titleLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftStack.trailingAnchor,
                constant: Design.Spacing.tight
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: buttonStack.leadingAnchor,
                constant: -Design.Spacing.medium
            )
        ])
    }

    // MARK: - Resolution

    /// Re-reads the resolved chrome: title ink for the current key state, alignment, and the
    /// gradient the next draw uses.
    private func apply() {
        let resolved = resolvedStyle
        let isKey = drawsAsKey
        [menuButton, minimizeButton, zoomButton, closeButton, depthButton].forEach {
            $0.invalidateIntrinsicContentSize()
        }
        titleLabel.textColor = isKey
            ? resolved?.ink ?? .white
            : resolved?.inactiveInk ?? .white
        let titleFont = Design.Typography.detail(weight: .bold)
        titleLabel.font = resolved?.titleFontStyle == .italic
            ? NSFontManager.shared.convert(titleFont, toHaveTrait: .italicFontMask)
            : titleFont

        let centered = resolved?.titleAlignment == .center
        centeredTitleConstraint?.isActive = centered
        leadingTitleConstraint?.isActive = !centered
        if !centered {
            leadingTitleConstraint?.isActive = true
        }

        appIcon.isHidden = resolved?.showsAppIcon == false
        applyButtonPlacement(
            resolved?.buttonPlacement ?? .trailing,
            visible: resolved?.visibleButtons
                ?? WindowChromeStyle.TitleBar.ButtonRole.standardOperations
        )
        applyShape(resolved)

        needsDisplay = true
    }

    private func applyButtonPlacement(
        _ placement: WindowChromeStyle.TitleBar.ButtonPlacement,
        visible: [WindowChromeStyle.TitleBar.ButtonRole]
    ) {
        let visibleSet = Set(visible.map(\.rawValue))
        func shown(_ role: WindowChromeStyle.TitleBar.ButtonRole) -> WindowChromeButton? {
            guard visibleSet.contains(role.rawValue) else { return nil }
            switch role {
            case .windowMenu: return menuButton
            case .close: return closeButton
            case .minimize: return minimizeButton
            case .zoom: return zoomButton
            case .depth: return depthButton
            }
        }

        let leading: [WindowChromeButton]
        let trailing: [WindowChromeButton]
        switch placement {
        case .trailing:
            leading = []
            trailing = visible.compactMap(shown)
        case .split:
            leading = shown(.close).map { [$0] } ?? []
            trailing = visible.filter { $0 != .close }.compactMap(shown)
        case .bookends:
            leading = visible.first.flatMap(shown).map { [$0] } ?? []
            trailing = visible.dropFirst().compactMap(shown)
        }

        let currentLeading = leadingButtonStack.arrangedSubviews.compactMap {
            $0 as? WindowChromeButton
        }
        let currentTrailing = buttonStack.arrangedSubviews.compactMap {
            $0 as? WindowChromeButton
        }
        guard currentLeading != leading || currentTrailing != trailing else { return }

        leadingButtonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        leading.forEach(leadingButtonStack.addArrangedSubview)
        trailing.forEach(buttonStack.addArrangedSubview)
    }

    private func applyShape(_ resolved: WindowChromeAppearance.Resolved?) {
        let isTab = resolved?.shape == .leadingTab
        fullWidthContentConstraint?.isActive = !isTab
        tabWidthContentConstraint?.constant = resolved?.tabWidth
            ?? CGFloat(WindowChromeStyleLimits.defaultTabWidth)
        tabWidthContentConstraint?.isActive = isTab
    }

    // MARK: - Window Following

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowStateObservations.forEach(NotificationCenter.default.removeObserver)
        windowStateObservations = []

        guard let newWindow else { return }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ] {
            windowStateObservations.append(NotificationCenter.default.addObserver(
                forName: name,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
    }

    // MARK: - Titlebar Behaviours

    /// A press on the band's own ground moves the window; a double-click performs the user's
    /// System Settings choice. Clicks the controls claim never arrive — the responder chain
    /// asks them first, the same reasoning `TitlebarActionWindow.mouseDown` records.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < TitlebarDoubleClick.clickCount else {
            perform(doubleClickAction())
            return
        }
        window?.performDrag(with: event)
    }

    /// The direct operations rather than `perform*`, the `WindowChromeButton` rule: the
    /// perform forms animate a standard button a frameless window does not have, and refuse.
    private func perform(_ action: TitlebarDoubleClick.Action) {
        switch action {
        case .zoom: window?.zoom(nil)
        case .minimize: window?.miniaturize(nil)
        case .doNothing: break
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let resolved = resolvedStyle else { return }
        let gradient = drawsAsKey ? resolved.activeGradient : resolved.inactiveGradient
        let bandRect = titleBandRect(for: resolved)

        if resolved.shape == .leadingTab {
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
        }

        guard gradient.colors.count >= 2,
              let drawn = NSGradient(
                  colors: gradient.colors,
                  atLocations: gradient.locations,
                  colorSpace: .sRGB
              ) else {
            (gradient.colors.first ?? Design.Surface.ground).setFill()
            bandRect.fill()
            drawTexture(drawsAsKey ? resolved.activeTexture : resolved.inactiveTexture,
                        over: gradient,
                        in: bandRect)
            drawTabEdge(ifNeededFor: resolved, in: bandRect)
            return
        }

        // The document's angle is CSS's — degrees clockwise from "toward the top" —
        // and `NSGradient` wants degrees counterclockwise from "toward the trailing edge".
        drawn.draw(in: bandRect, angle: 90 - gradient.angleDegrees)
        drawTexture(
            drawsAsKey ? resolved.activeTexture : resolved.inactiveTexture,
            over: gradient,
            in: bandRect
        )
        drawTabEdge(ifNeededFor: resolved, in: bandRect)
    }

    private func titleBandRect(for resolved: WindowChromeAppearance.Resolved) -> NSRect {
        switch resolved.shape {
        case .fullWidth:
            return bounds
        case .leadingTab:
            return NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: min(resolved.tabWidth, bounds.width),
                height: bounds.height
            )
        }
    }

    private func drawTexture(
        _ texture: WindowChromeAppearance.Resolved.Texture?,
        over gradient: WindowChromeAppearance.Gradient,
        in rect: NSRect
    ) {
        guard let texture else { return }

        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false

        switch texture.kind {
        case .pinstripes:
            texture.color.setFill()
            var y = rect.minY + 1
            while y < rect.maxY - 1 {
                NSRect(x: rect.minX, y: y.rounded(), width: rect.width, height: 1).fill()
                y += texture.spacing
            }

            // Platinum interrupts the rules behind the title instead of laying type over
            // them. The fill is the band's own base, so the gap remains part of the bar.
            if resolvedStyle?.titleAlignment == .center, !titleLabel.frame.isEmpty {
                let backdrop = titleLabel.frame.insetBy(dx: -Design.Spacing.tight, dy: 0)
                (gradient.colors.first ?? Design.Surface.ground).setFill()
                backdrop.fill()
            }
        case .dither:
            texture.color.setFill()
            let step = max(2, texture.spacing.rounded())
            var y = rect.minY + 1
            var row = 0
            while y < rect.maxY - 1 {
                var x = rect.minX + 1 + (row.isMultiple(of: 2) ? 0 : step / 2)
                while x < rect.maxX - 1 {
                    NSRect(x: x.rounded(), y: y.rounded(), width: 1, height: 1).fill()
                    x += step
                }
                y += step / 2
                row += 1
            }
        }
    }

    private func drawTabEdge(
        ifNeededFor resolved: WindowChromeAppearance.Resolved,
        in rect: NSRect
    ) {
        guard resolved.shape == .leadingTab else { return }

        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false

        guard AppThemePalette.current.material.bevel != nil else {
            Design.Surface.border.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
            return
        }

        let colors = BevelArtwork.edgeColors(
            highlight: Design.Surface.bevelHighlight,
            shadow: Design.Surface.bevelShadow,
            sunken: false
        )
        func ring(_ box: NSRect, topLeft: NSColor, bottomRight: NSColor) {
            bottomRight.setFill()
            NSRect(x: box.maxX - 1, y: box.minY, width: 1, height: box.height).fill()
            NSRect(x: box.minX, y: box.minY, width: box.width, height: 1).fill()
            topLeft.setFill()
            NSRect(x: box.minX, y: box.maxY - 1, width: box.width - 1, height: 1).fill()
            NSRect(x: box.minX, y: box.minY + 1, width: 1, height: box.height - 1).fill()
        }
        ring(rect, topLeft: colors.topLeftOuter, bottomRight: colors.bottomRightOuter)
        ring(
            rect.insetBy(dx: 1, dy: 1),
            topLeft: colors.topLeftInner,
            bottomRight: colors.bottomRightInner
        )
    }

    // MARK: - Accessibility

    /// The band itself is furniture; its controls speak for themselves. Announced as a group
    /// so VoiceOver users hear the window's controls as one cluster, the way the titlebar was.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}
