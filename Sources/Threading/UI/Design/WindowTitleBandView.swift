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

    private var usesPlatinumBitmapTitle: Bool {
        resolvedStyle?.glyphStyle == .platinum
            && AppSettings.chromeFontFamily == nil
            && titleLabel.font?.familyName?.caseInsensitiveCompare("Charcoal") != .orderedSame
            && PlatinumBitmapFont.advance(of: titleLabel.stringValue) != nil
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
    private let windowStateObservations = AppEventObservations()
    private let appIconProvider: () -> NSImage?
    private var centeredTitleConstraint: NSLayoutConstraint?
    private var leadingTitleConstraint: NSLayoutConstraint?
    private var titleContentWidthConstraint: NSLayoutConstraint?
    private var fullWidthContentConstraint: NSLayoutConstraint?
    private var tabWidthContentConstraint: NSLayoutConstraint?
    private var leadingButtonsCenterYConstraint: NSLayoutConstraint?
    private var trailingButtonsCenterYConstraint: NSLayoutConstraint?
    private var leadingClusterEdgeConstraint: NSLayoutConstraint?
    private var trailingClusterEdgeConstraint: NSLayoutConstraint?
    private var titleCenterYConstraint: NSLayoutConstraint?

    // MARK: - Initialization

    init(appIconProvider: @escaping () -> NSImage? = {
        NSApplication.shared.applicationIconImage
    }) {
        self.appIconProvider = appIconProvider
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        updateTitleRenderingMode()
        applyTitleAttributes()
        titleLabel.invalidateIntrinsicContentSize()
        refreshTitleContentWidth()
        needsLayout = true
    }

    /// The band's leading application slot: the window's own commands when the theme states
    /// `commands: in_title_bar`, and nothing at all otherwise.
    ///
    /// Its guests keep their own semantic size — forcing toolbar controls down to the caption
    /// buttons' height created two conflicting required constraints, which is why a band
    /// shorter than `WindowChromeStyleLimits.commandsInTitleBarMinimumHeight` may not ask for
    /// them. What the band does own is the ground underneath: these controls were built for the
    /// chrome's roles and are now over the band's gradient, so they are told whose ground they
    /// are on (`hostGround`) rather than left measuring their ink against a surface that is no
    /// longer there.
    func setLeadingControls(_ views: [NSView]) {
        for case let control as BackdropThemedControl in leadingStack.arrangedSubviews {
            control.hostGround = nil
        }
        leadingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            (view as? BackdropThemedControl)?.hostGround = .titleBand
            leadingStack.addArrangedSubview(view)
        }
        apply()
    }

    // MARK: - Setup

    private func setup() {
        addLayoutGuide(contentGuide)
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
        // Preserve the native caption whenever the two operation clusters leave room for it.
        // `.defaultLow` let Auto Layout shorten even tiny period titles ("Charts" became
        // "Cha…" and "Appearance" became "Appearan…") despite dozens of unused pixels.
        // Required boundary inequalities still win for genuinely long window titles.
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(titleLabel)

        let leadingTitle = titleLabel.leadingAnchor.constraint(
            equalTo: leftStack.trailingAnchor,
            constant: Design.Spacing.medium
        )
        leadingTitleConstraint = leadingTitle
        centeredTitleConstraint = titleLabel.centerXAnchor.constraint(
            equalTo: contentGuide.centerXAnchor
        )
        let titleContentWidth = titleLabel.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 0
        )
        titleContentWidth.priority = .defaultHigh
        titleContentWidthConstraint = titleContentWidth

        let fullWidthContent = contentGuide.trailingAnchor.constraint(equalTo: trailingAnchor)
        let tabWidthContent = contentGuide.widthAnchor.constraint(
            equalToConstant: WindowChromeStyleLimits.defaultTabWidth
        )
        // A native-sized evidence crop may be narrower than the theme's preferred BeOS tab.
        // Keep the preferred width when it fits, but let the required `<= widthAnchor`
        // boundary clamp it instead of breaking constraints and clipping the trailing box.
        tabWidthContent.priority = .defaultHigh
        fullWidthContentConstraint = fullWidthContent
        tabWidthContentConstraint = tabWidthContent

        let leadingButtonsCenterY = leftStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        let trailingButtonsCenterY = buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        let leadingClusterEdge = leftStack.leadingAnchor.constraint(
            equalTo: contentGuide.leadingAnchor,
            constant: Design.Spacing.tight
        )
        let trailingClusterEdge = buttonStack.trailingAnchor.constraint(
            equalTo: contentGuide.trailingAnchor,
            constant: -Design.Spacing.tight
        )
        leadingButtonsCenterYConstraint = leadingButtonsCenterY
        trailingButtonsCenterYConstraint = trailingButtonsCenterY
        leadingClusterEdgeConstraint = leadingClusterEdge
        trailingClusterEdgeConstraint = trailingClusterEdge
        let titleCenterY = titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleCenterYConstraint = titleCenterY

        NSLayoutConstraint.activate([
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 14),
            appIcon.heightAnchor.constraint(equalToConstant: 14),

            contentGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentGuide.topAnchor.constraint(equalTo: topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentGuide.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            fullWidthContent,

            leadingClusterEdge,
            leadingButtonsCenterY,

            trailingClusterEdge,
            trailingButtonsCenterY,

            titleCenterY,
            titleContentWidth,
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
        let anatomy = WindowChromeCaptionAnatomy.of(resolved?.glyphStyle)
        leadingButtonStack.spacing = anatomy.clusterSpacing
        buttonStack.spacing = anatomy.clusterSpacing
        leadingButtonsCenterYConstraint?.constant = anatomy.clusterVerticalOffset
        trailingButtonsCenterYConstraint?.constant = anatomy.clusterVerticalOffset
        trailingClusterEdgeConstraint?.constant = -anatomy.trailingEdgeInset
        titleCenterYConstraint?.constant = anatomy.titleVerticalOffset
        centeredTitleConstraint?.constant = anatomy.titleHorizontalOffset
        leadingTitleConstraint?.constant = anatomy.titleGap + anatomy.titleHorizontalOffset
        titleLabel.textColor = isKey
            ? resolved?.ink ?? .white
            : resolved?.inactiveInk ?? .white
        // BeOS's Swis721 title is a tracked regular raster. Asking a modern fallback for
        // Bold creates a much denser word even when its point size and baseline are exact;
        // the one-pixel tracking below restores the original face's wider advance. The
        // text-mode family joins them for a different reason with the same answer: its
        // caption is set in the theme's own monospaced face, where Bold is a second weight
        // the grid it imitates never had.
        let usesRegularBitmapTitle = resolved?.glyphStyle == .beOS
            || resolved?.glyphStyle == .amiga
            || resolved?.glyphStyle == .tui
        let semanticTitleFont = Design.Typography.detail(
            weight: usesRegularBitmapTitle ? .regular : .bold
        )
        let sizedTitleFont = resolved?.titleFontSize.flatMap {
            NSFont(descriptor: semanticTitleFont.fontDescriptor, size: $0)
        } ?? semanticTitleFont
        titleLabel.font = resolved?.titleFontStyle == .italic
            ? NSFontManager.shared.convert(sizedTitleFont, toHaveTrait: .italicFontMask)
            : sizedTitleFont
        // OPENSTEP's title is a one-bit caption raster. Its label still participates in
        // layout and accessibility, but the band paints the visible glyphs with font
        // smoothing disabled so modern AppKit cannot turn the four-colour frame into a
        // cloud of intermediate grays.
        updateTitleRenderingMode()
        applyTitleAttributes()
        refreshTitleContentWidth()

        let centered = resolved?.titleAlignment == .center
        centeredTitleConstraint?.isActive = centered
        leadingTitleConstraint?.isActive = !centered
        if !centered {
            leadingTitleConstraint?.isActive = true
        }

        let showsAppIcon = resolved?.showsAppIcon == true
        appIcon.isHidden = !showsAppIcon
        if showsAppIcon, appIcon.image == nil {
            appIcon.image = appIconProvider()
        }
        applyButtonPlacement(
            resolved?.buttonPlacement ?? .trailing,
            visible: resolved?.visibleButtons
                ?? WindowChromeStyle.TitleBar.ButtonRole.standardOperations
        )
        applyLeadingColumn(anatomy, commands: resolved?.commands ?? .ownRow)
        // `NSStackView.spacing` cannot state the Win98 caption's two operation groups. Reset
        // the per-view override on every application so a live theme switch never carries
        // that Windows break into another family.
        if buttonStack.arrangedSubviews.contains(zoomButton) {
            buttonStack.setCustomSpacing(
                anatomy.closeGroupSpacing ?? anatomy.clusterSpacing,
                after: zoomButton
            )
        }
        applyShape(resolved)

        needsDisplay = true
    }

    private func updateTitleRenderingMode() {
        titleLabel.isHidden = resolvedStyle?.glyphStyle == .openStep
            || (resolvedStyle?.glyphStyle == .irix && drawsAsKey)
            || resolvedStyle?.glyphStyle == .amiga
            || resolvedStyle?.classicSkin != nil
            || usesPlatinumBitmapTitle
    }

    /// Workbench's Topaz caption is a one-bit ROM strike. Letting a regular NSTextField paint
    /// it through CoreText introduces blended blue/black edge pixels even when the font itself
    /// has the right monospaced glyphs. The label remains in the hierarchy for layout and
    /// accessibility; the visible caption is drawn here with the same hard-raster switches as
    /// historical text fields.
    private func drawAmigaTitleIfNeeded() {
        guard resolvedStyle?.glyphStyle == .amiga,
              !titleLabel.stringValue.isEmpty,
              !titleLabel.frame.isEmpty else { return }

        let title = titleLabel.attributedStringValue
        let measured = title.size()
        let frame = titleLabel.frame
        let origin = NSPoint(
            x: floor(frame.minX),
            y: floor(frame.midY - measured.height / 2)
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext.current else { return }
        // Topaz's ROM strike is a one-bit face. These switches prevent CoreText's usual font
        // smoothing on supported AppKit paths; the label itself remains hidden so only this
        // period-specific pass is visible.
        context.shouldAntialias = false
        context.cgContext.setShouldAntialias(false)
        context.cgContext.setAllowsAntialiasing(false)
        context.cgContext.setShouldSmoothFonts(false)
        context.cgContext.setAllowsFontSmoothing(false)
        NSBezierPath(rect: frame).addClip()
        title.draw(at: origin)
    }

    private func refreshTitleContentWidth() {
        guard titleLabel.font != nil else {
            titleContentWidthConstraint?.constant = 0
            return
        }
        // A truncating NSTextField intentionally reports only its minimum ellipsis width as
        // intrinsic content size. That is useful in toolbars and wrong for a period caption:
        // reserve the measured title while it fits, then let the required button boundaries
        // compress this high-priority constraint for genuinely long names.
        let measured = titleLabel.attributedStringValue.size().width
        titleContentWidthConstraint?.constant = ceil(measured) + 2
    }

    private func applyTitleAttributes() {
        guard let font = titleLabel.font else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: titleLabel.textColor ?? Design.Text.label
        ]
        if resolvedStyle?.glyphStyle == .platinum {
            // Charcoal is no longer distributed with macOS. Geneva is the native fallback,
            // but its 12px “Appearance” is eight pixels narrower; Charcoal's one-pixel
            // tracking restores the measured caption width without inflating its vertical em.
            attributes[.kern] = CGFloat(1)
        } else if resolvedStyle?.glyphStyle == .beOS {
            attributes[.kern] = CGFloat(0.5)
        }
        titleLabel.attributedStringValue = NSAttributedString(
            string: titleLabel.stringValue,
            attributes: attributes
        )
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
        case .leading:
            leading = visible.compactMap(shown)
            trailing = []
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

    /// Where the band's leading run starts, and how its members are spaced.
    ///
    /// A caption band inset its leading cluster by the family's own measured edge, which is
    /// what every reconstruction here was tuned against. A band carrying the window's commands
    /// is additionally a *pane band* — it is the top row of an application whose next row down
    /// is the sidebar's brand and the content pane's header — so its first control's ink starts
    /// on the column those bands start on, and its siblings take their item spacing. Both are
    /// `PaneHeaderView`'s statement of the same two rules, read from there rather than restated,
    /// which is the drift `WindowCommandBandView` was already caught in once.
    ///
    /// The two optional groups ahead of the commands collapse in that mode. An empty
    /// `NSStackView` is still an arranged subview and still takes the spacing around it, and
    /// that phantom is baked into every family's measured `leadingEdgeInset` — so it is left
    /// alone where a reconstruction depends on it and removed where an exact column is the
    /// point.
    private func applyLeadingColumn(
        _ anatomy: WindowChromeCaptionAnatomy,
        commands: WindowChromeStyle.TitleBar.CommandPlacement
    ) {
        guard commands == .inTitleBar else {
            leadingButtonStack.isHidden = false
            leadingStack.isHidden = false
            leadingStack.spacing = Design.Spacing.tight
            leadingClusterEdgeConstraint?.constant = anatomy.leadingEdgeInset
            return
        }

        leadingButtonStack.isHidden = leadingButtonStack.arrangedSubviews.isEmpty
        leadingStack.isHidden = leadingStack.arrangedSubviews.isEmpty
        leadingStack.spacing = PaneHeaderView.itemSpacing
        leadingClusterEdgeConstraint?.constant =
            PaneHeaderView.contentInset - opticalInset(of: firstLeadingInk)
    }

    /// The view whose ink the leading column is measured from: the first window operation when
    /// the theme leads with one, then the identity icon, then the commands.
    private var firstLeadingInk: NSView? {
        if let button = leadingButtonStack.arrangedSubviews.first { return button }
        if !appIcon.isHidden { return appIcon }
        return leadingStack.arrangedSubviews.first
    }

    private func opticalInset(of view: NSView?) -> CGFloat {
        (view as? OpticalInsetProviding)?.opticalHorizontalInset ?? 0
    }

    private func applyShape(_ resolved: WindowChromeAppearance.Resolved?) {
        let isTab = resolved?.shape == .leadingTab
        fullWidthContentConstraint?.isActive = !isTab
        let preferredWidth = resolved?.tabWidth
            ?? CGFloat(WindowChromeStyleLimits.defaultTabWidth)
        tabWidthContentConstraint?.constant = bounds.width > 0
            ? min(preferredWidth, bounds.width)
            : preferredWidth
        tabWidthContentConstraint?.isActive = isTab
    }

    override func layout() {
        if resolvedStyle?.shape == .leadingTab {
            let preferredWidth = resolvedStyle?.tabWidth
                ?? CGFloat(WindowChromeStyleLimits.defaultTabWidth)
            tabWidthContentConstraint?.constant = min(preferredWidth, bounds.width)
        }
        super.layout()
    }

    // MARK: - Window Following

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowStateObservations.removeAll()

        guard let newWindow else { return }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ] {
            windowStateObservations.observe(name, object: newWindow) { [weak self] in
                self?.apply()
            }
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
        if let skin = resolved.classicSkin,
           drawClassicPlayerBand(from: skin.titleBarImage, active: drawsAsKey, in: bounds) {
            return
        }
        if resolved.glyphStyle == .irix, drawsAsKey, bounds.height == 32 {
            drawIRIXActiveBand(in: bounds)
            drawIRIXTitle()
            return
        }
        if resolved.glyphStyle == .openStep, drawsAsKey {
            drawOpenStepActiveBand(in: bounds)
            drawOpenStepTitle()
            return
        }
        let gradient = drawsAsKey ? resolved.activeGradient : resolved.inactiveGradient
        let bandRect = titleBandRect(for: resolved)

        if resolved.shape == .leadingTab {
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
        }

        // Workbench's Intuition strip is a single indexed-palette blue (or gray while
        // inactive), not a continuous modern gradient. Filling it directly also preserves
        // the authored #6688BB/#AAAAAA sample in one-device-pixel fixtures; routing two equal
        // stops through NSGradient needlessly applies the display colour transform twice.
        if resolved.glyphStyle == .amiga,
           let solid = gradient.colors.first,
           gradient.colors.dropFirst().allSatisfy({ $0 == solid }) {
            solid.setFill()
            bandRect.fill()
            drawTexture(drawsAsKey ? resolved.activeTexture : resolved.inactiveTexture,
                        over: gradient,
                        in: bandRect)
            drawTabEdge(ifNeededFor: resolved, in: bandRect)
            drawAmigaTitleIfNeeded()
            return
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
            drawAmigaTitleIfNeeded()
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
        drawAmigaTitleIfNeeded()
    }

    /// A classic skin contains complete 275-by-14 active and inactive title bands. The
    /// hardware at either edge stays at native size; only the otherwise repeating centre
    /// groove grows with a modern resizable Threading window.
    @discardableResult
    private func drawClassicPlayerBand(
        from sheet: NSImage,
        active: Bool,
        in rect: NSRect
    ) -> Bool {
        let sourceTopY: CGFloat = active ? 0 : 15
        let sourceX: CGFloat = 27
        let sourceWidth: CGFloat = 275
        let sourceHeight: CGFloat = 14
        guard sheet.size.width >= sourceX + sourceWidth,
              sheet.size.height >= sourceTopY + sourceHeight,
              rect.width > 0,
              rect.height > 0 else { return false }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.imageInterpolation = .none

        let sourceY = sheet.size.height - sourceTopY - sourceHeight
        if rect.width < sourceWidth {
            sheet.draw(
                in: rect,
                from: NSRect(
                    x: sourceX,
                    y: sourceY,
                    width: sourceWidth,
                    height: sourceHeight
                ),
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
            return true
        }

        let leftWidth: CGFloat = 238
        let rightWidth = sourceWidth - leftWidth
        let leftDestination = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: leftWidth,
            height: rect.height
        )
        let rightDestination = NSRect(
            x: rect.maxX - rightWidth,
            y: rect.minY,
            width: rightWidth,
            height: rect.height
        )
        let middleDestination = NSRect(
            x: leftDestination.maxX,
            y: rect.minY,
            width: max(0, rightDestination.minX - leftDestination.maxX),
            height: rect.height
        )

        sheet.draw(
            in: leftDestination,
            from: NSRect(x: sourceX, y: sourceY, width: leftWidth, height: sourceHeight),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
        if middleDestination.width > 0 {
            sheet.draw(
                in: middleDestination,
                from: NSRect(
                    x: sourceX + leftWidth - 2,
                    y: sourceY,
                    width: 2,
                    height: sourceHeight
                ),
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }
        sheet.draw(
            in: rightDestination,
            from: NSRect(
                x: sourceX + leftWidth,
                y: sourceY,
                width: rightWidth,
                height: sourceHeight
            ),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
        return true
    }

    /// The 4Dwm title is a single indexed-palette assembly. Its menu plate, centre field,
    /// caption plates, and seven-row outer frame share one dither phase, so composing three
    /// generic raised buttons over a gradient cannot reproduce the native joins. These are
    /// symbolic palette rows: the centre tiles with the window width while the two measured
    /// mechanical end caps remain fixed.
    private func drawIRIXActiveBand(in rect: NSRect) {
        guard rect.width >= 90, rect.height == 32 else { return }
        let center = NSRect(
            x: rect.minX + 32,
            y: rect.minY,
            width: rect.width - 90,
            height: 32
        )
        drawIRIXCenterRows(in: center)
        drawIRIXPaletteRows(
            Self.irixLeftEndRows,
            in: NSRect(x: rect.minX, y: rect.minY, width: 32, height: 32)
        )
        drawIRIXPaletteRows(
            Self.irixRightEndRows,
            in: NSRect(x: rect.maxX - 58, y: rect.minY, width: 58, height: 32)
        )
        // These three join columns are part of the asymmetric inner frame rather than the
        // repeating centre tile or either fixed end cap.
        drawIRIXPaletteRows(
            Self.irixLeftJoinRows,
            in: NSRect(x: rect.minX + 32, y: rect.minY, width: 2, height: 32)
        )
        drawIRIXPaletteRows(
            Self.irixRightJoinRows,
            in: NSRect(x: rect.maxX - 59, y: rect.minY, width: 1, height: 32)
        )
    }

    private func drawIRIXTitle() {
        guard !titleLabel.stringValue.isEmpty, bounds.width > 102 else { return }
        let clip = NSRect(
            x: bounds.minX + 32,
            y: bounds.minY,
            width: max(0, bounds.width - 90),
            height: bounds.height
        )
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clip).addClip()
        if AppSettings.chromeFontFamily == nil,
           IRIXBitmapCaptionFont.draw(
               titleLabel.stringValue,
               penX: bounds.minX + 44,
               baselineFromTop: 23,
               in: bounds,
               ink: .black
           ) {
            return
        }

        let title = titleLabel.attributedStringValue
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        title.draw(at: NSPoint(x: bounds.minX + 44, y: bounds.minY + 7))
    }

    private func drawIRIXCenterRows(in rect: NSRect) {
        let palette = Self.irixPalette
        let visualY: (Int) -> CGFloat = { row in
            (NSGraphicsContext.current?.isFlipped ?? false)
                ? rect.minY + CGFloat(row)
                : rect.maxY - CGFloat(row) - 1
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        for (row, pair) in Self.irixCenterRows.enumerated() {
            let colors = Array(pair)
            guard colors.count == 2,
                  let even = palette[colors[0]],
                  let odd = palette[colors[1]] else { continue }
            even.setFill()
            NSRect(x: rect.minX, y: visualY(row), width: rect.width, height: 1).fill()
            guard colors[0] != colors[1] else { continue }
            odd.setFill()
            var x = rect.minX + 1
            while x < rect.maxX {
                NSRect(x: x, y: visualY(row), width: 1, height: 1).fill()
                x += 2
            }
        }
    }

    private func drawIRIXPaletteRows(_ rows: [String], in rect: NSRect) {
        let visualY: (Int) -> CGFloat = { row in
            (NSGraphicsContext.current?.isFlipped ?? false)
                ? rect.minY + CGFloat(row)
                : rect.maxY - CGFloat(row) - 1
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect).addClip()
        for (rowIndex, row) in rows.enumerated() {
            for (column, sample) in row.enumerated() {
                guard let color = Self.irixPalette[sample] else { continue }
                color.setFill()
                NSRect(
                    x: rect.minX + CGFloat(column),
                    y: visualY(rowIndex),
                    width: 1,
                    height: 1
                ).fill()
            }
        }
    }

    private static let irixPalette: [Character: NSColor] = [
        "K": .black,
        "D": NSColor(srgbRed: 66 / 255, green: 66 / 255, blue: 66 / 255, alpha: 1),
        "G": NSColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1),
        "L": NSColor(srgbRed: 198 / 255, green: 198 / 255, blue: 198 / 255, alpha: 1)
    ]

    private static let irixCenterRows = [
        "KK", "LL", "LG", "GG", "GG", "GD", "DG", "KK",
        "LL", "GL", "GG", "GG", "GG", "GG", "GG", "GG",
        "GG", "GG", "GG", "GG", "GG", "GG", "GG", "GG",
        "GG", "GG", "GG", "GG", "GG", "GD", "DD", "KK"
    ]

    private static let irixLeftJoinRows = [
        "KK", "LL", "LL", "LL", "LG", "GD", "DG", "KK",
        "LL", "LL", "LG", "LL", "LG", "LL", "LG", "LL",
        "LG", "LL", "LG", "LL", "LG", "LL", "LG", "LL",
        "LG", "LL", "LG", "LL", "LG", "LD", "GD", "KK"
    ]

    private static let irixRightJoinRows = [
        "K", "L", "G", "G", "G", "D", "G", "K",
        "L", "L", "G", "D", "G", "D", "G", "D",
        "G", "D", "G", "D", "G", "D", "G", "D",
        "G", "D", "G", "D", "G", "D", "D", "K"
    ]

    private static let irixLeftEndRows = [
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK",
        "KLLLLLLLLLLLLLLLLLLLLLLLLLLLLLGD",
        "KLLGLGLGLGLGLGLGLGLGLGLGLGLGLGDD",
        "KLGLGGGGGGGGGGGGGGGGGGGGGGGGGGGD",
        "KLLGGGGGGGGGGGGGGGGGGGGGGGGGGGGD",
        "KLGLGDGDGDGDGDGDGDGDGDGDGDGDGDGD",
        "KLLGGGDGDGDGDGDGDGDGDGDGDGDGDGDG",
        "KLGLGDGKKKKKKKKKKKKKKKKKKKKKKKKK",
        "KLLGGGDKLLLLLLLLLLLLLLLLLLLLLLLL",
        "KLGLGDGKLLGLGLGLGLGLGLGLGLGLGLGL",
        "KLLGGGDKLGGGGGGGGGGGGGGGGGGGGGGD",
        "KLGLGDGKLLGGGGGGGGGGGGGGGGGGGGGD",
        "KLLGGGDKLGGGGGGGGGGGGGGGGGGGGGDD",
        "KLGLGDGKLLGGGGGGGGGGGGGGGGGGGGGD",
        "KLLGGGDKLGGGGGGGGGGGGGGGGGGGGGDD",
        "KLGLGDGKLLGGGGGGGGGGGGGGGGGGGGGD",
        "KLLGGGDKLGGGGGGGGGGGGGGGGGGGGGDD",
        "KLGLGDGKLLGGKKKKKKKKKKKKKKKKGGGD",
        "KLLGGGDKLGGGKGGGGGGGGGGGGGGKGGDD",
        "KLGLGDGKLLGGKGGGGGGGGGGGGGGKKGGD",
        "KLLGGGDKLGGGKKKKKKKKKKKKKKKKKGDD",
        "KLGLGDGKLLGGGGKKKKKKKKKKKKKKKGGD",
        "KLLGGGDKLGGGGGGGGGGGGGGGGGGGGGDD",
        "KLGLGDGKLLGGGGGGGGGGGGGGGGGGGGGD",
        "KLLGGGDKLGGGGGGGGGGGGGGGGGGGGGDD",
        "KLGLGDGKLLGGGGGGGGGGGGGGGGGGGGGD",
        "KLLGGGDKLGGGGGGGGGGGGGGGGGGGGGDD",
        "KLGLGDGKLLGGGGGGGGGGGGGGGGGGGGGD",
        "KLLGGGDKLGGGGGGGGGGGGGGGGGGGGGDD",
        "KLGLGDGKLGGDGDGDGDGDGDGDGDGDGDGD",
        "KGDGGGDKGDDDDDDDDDDDDDDDDDDDDDDD",
        "KDDDDDGKKKKKKKKKKKKKKKKKKKKKKKKK"
    ]

    private static let irixRightEndRows = [
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK",
        "LLLLLLLLLLLLLLLLLLLLLLLLGDLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLGK",
        "LGLGLGLGLGLGLGLGLGLGLGLGDDLLLGLGLGLGLGLGLGLGLGLGLGLGLGLGDK",
        "GGGGGGGGGGGGGGGGGGGGGGGGGDLLGGGGGGGGGGGGGGGGGGGGGGGGGGGDGK",
        "GGGGGGGGGGGGGGGGGGGGGGGGGDLGGGGGGGGGGGGGGGGGGGGGGGGGGGGGDK",
        "GDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGLGDGK",
        "DGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGDGLGGGDK",
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKLGLGDGK",
        "LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLKLLGGGDK",
        "GLGLGLGLGLGLGLGLGLGLGLGLGGLLGLGLGLGLGLGLGLGLGLGLGLKLGLGDGK",
        "DLLGGGGGGGGGGGGGGGGGGGGGGDLGGGGGGGGGGGGGGGGGGGGGGDKLLGGGDK",
        "DLGGGGGGGGGGGGGGGGGGGGGGGDLLGGGKKKKKKKKKKKKKKGGGGDKLGLGDGK",
        "DLLGGGGGGGGGGGGGGGGGGGGGDDLGGGGKGGGGGGGGGGGGKGGGDDKLLGGGDK",
        "DLGGGGGGGGGGGGGGGGGGGGGGGDLLGGGKGGGGGGGGGGGGKKGGGDKLGLGDGK",
        "DLLGGGGGGGGGGGGGGGGGGGGGDDLGGGGKGGGGGGGGGGGGKKGGDDKLLGGGDK",
        "DLGGGGGGGGGGGGGGGGGGGGGGGDLLGGGKGGGGGGGGGGGGKKGGGDKLGLGDGK",
        "DLLGGGGGGGGGGGGGGGGGGGGGDDLGGGGKGGGGGGGGGGGGKKGGDDKLLGGGDK",
        "DLGGGGGGGGKKKKGGGGGGGGGGGDLLGGGKGGGGGGGGGGGGKKGGGDKLGLGDGK",
        "DLLGGGGGGGKGGKKGGGGGGGGGDDLGGGGKGGGGGGGGGGGGKKGGDDKLLGGGDK",
        "DLGGGGGGGGKGGKKGGGGGGGGGGDLLGGGKGGGGGGGGGGGGKKGGGDKLGLGDGK",
        "DLLGGGGGGGKKKKKGGGGGGGGGDDLGGGGKGGGGGGGGGGGGKKGGDDKLLGGGDK",
        "DLGGGGGGGGGKKKKGGGGGGGGGGDLLGGGKGGGGGGGGGGGGKKGGGDKLGLGDGK",
        "DLLGGGGGGGGGGGGGGGGGGGGGDDLGGGGKGGGGGGGGGGGGKKGGDDKLLGGGDK",
        "DLGGGGGGGGGGGGGGGGGGGGGGGDLLGGGKGGGGGGGGGGGGKKGGGDKLGLGDGK",
        "DLLGGGGGGGGGGGGGGGGGGGGGDDLGGGGKGGGGGGGGGGGGKKGGDDKLLGGGDK",
        "DLGGGGGGGGGGGGGGGGGGGGGGGDLLGGGKGGGGGGGGGGGGKKGGGDKLGLGDGK",
        "DLLGGGGGGGGGGGGGGGGGGGGGDDLGGGGKKKKKKKKKKKKKKKGGDDKLLGGGDK",
        "DLGGGGGGGGGGGGGGGGGGGGGGGDLLGGGGGKKKKKKKKKKKKKGGGDKLGLGDGK",
        "DLLGGGGGGGGGGGGGGGGGGGGGDDLGGGGGGGGGGGGGGGGGGGGGDDKLLGGGDK",
        "DLGDGDGDGDGDGDGDGDGDGDGDGDLDGDGDGDGDGDGDGDGDGDGDGDKLGLGDGK",
        "DGDDDDDDDDDDDDDDDDDDDDDDDDGDDDDDDDDDDDDDDDDDDDDDDDKLLGDGDK",
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKLGDDDDK"
    ]

    /// OPENSTEP's active title frame is an asymmetric four-tone indexed construction, not a
    /// black rectangle with a generic one-point outline. The rightmost #AAA continuation and
    /// the inner #555 bottom/trailing rails are visible even at native size and account for
    /// most of the old reproduction's silhouette mismatch.
    private func drawOpenStepActiveBand(in rect: NSRect) {
        guard rect.width >= 5, rect.height >= 5 else {
            NSColor.black.setFill()
            rect.fill()
            return
        }
        let gray = NSColor(srgbRed: 170 / 255, green: 170 / 255, blue: 170 / 255, alpha: 1)
        let dark = NSColor(srgbRed: 85 / 255, green: 85 / 255, blue: 85 / 255, alpha: 1)
        let visualRow: (CGFloat) -> CGFloat = { top in
            (NSGraphicsContext.current?.isFlipped ?? false)
                ? rect.minY + top
                : rect.maxY - top - 1
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor.black.setFill()
        rect.fill()

        gray.setFill()
        NSRect(x: rect.minX + 1, y: visualRow(1), width: rect.width - 2, height: 1).fill()
        NSRect(
            x: rect.minX + 1,
            y: min(visualRow(1), visualRow(rect.height - 2)),
            width: 1,
            height: rect.height - 2
        ).fill()

        dark.setFill()
        NSRect(
            x: rect.maxX - 2,
            y: min(visualRow(2), visualRow(rect.height - 3)),
            width: 1,
            height: rect.height - 4
        ).fill()
        NSRect(
            x: rect.minX + 2,
            y: visualRow(rect.height - 2),
            width: rect.width - 3,
            height: 1
        ).fill()
    }

    /// Draw the current, arbitrary window title through the theme's real font chain, but on
    /// OPENSTEP's hard pixel grid. The exact face is still selectable/overridable like every
    /// other theme; this only restores the period renderer's one-bit output.
    private func drawOpenStepTitle() {
        guard !titleLabel.stringValue.isEmpty else { return }
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        if AppSettings.chromeFontFamily == nil,
           material.fontFamilies.first?.caseInsensitiveCompare("Helvetica") == .orderedSame,
           OpenStepBitmapCaptionFont.draw(
               titleLabel.stringValue,
               centeredIn: bounds,
               ink: titleLabel.textColor ?? .white
           ) {
            return
        }
        let title = titleLabel.attributedStringValue
        let measured = title.size()
        let origin = NSPoint(
            x: floor(bounds.midX - measured.width / 2),
            y: floor(bounds.midY - measured.height / 2)
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        title.draw(at: origin)
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
            if resolvedStyle?.glyphStyle == .platinum {
                drawPlatinumPinstripes(in: rect)
                drawPlatinumTitle(in: rect)
            } else {
                texture.color.setFill()
                var y = rect.minY + 1
                while y < rect.maxY - 1 {
                    NSRect(x: rect.minX, y: y.rounded(), width: rect.width, height: 1).fill()
                    y += texture.spacing
                }

                // A centred striped family interrupts the rules behind its title instead of
                // laying type over them. The fill is the band's own base, so the gap remains
                // part of the bar.
                if resolvedStyle?.titleAlignment == .center, !titleLabel.frame.isEmpty {
                    let backdrop = titleLabel.frame.insetBy(dx: -Design.Spacing.tight, dy: 0)
                    (gradient.colors.first ?? Design.Surface.ground).setFill()
                    backdrop.fill()
                }
            }
        case .captionRails:
            drawCaptionRails(texture, in: rect)
        case .aquaPinstripes:
            // Cheetah's stripe is a four-row glass rib, not Platinum's hard line every other
            // pixel. Two neutral rows let the vertical silver gradient through; a faint dark
            // row gives the groove and a white row catches the light. The authored colour
            // controls the groove strength, so custom chromes retain the same vocabulary.
            let liftedColors = gradient.colors.map { color -> NSColor in
                let rgb = color.usingColorSpace(.sRGB) ?? color
                let lift: CGFloat = 14 / 255
                return NSColor(
                    srgbRed: min(1, rgb.redComponent + lift),
                    green: min(1, rgb.greenComponent + lift),
                    blue: min(1, rgb.blueComponent + lift),
                    alpha: rgb.alphaComponent
                )
            }
            let liftedGradient = NSGradient(
                colors: liftedColors,
                atLocations: gradient.locations,
                colorSpace: .sRGB
            )
            let cycle = max(2, Int(texture.spacing.rounded()))
            let reflectionRow = cycle / 2
            var y = rect.minY
            var row = 0
            while y < rect.maxY {
                let line = NSRect(
                    x: rect.minX,
                    y: y.rounded(),
                    width: rect.width,
                    height: 1
                )
                switch row % cycle {
                case 0:
                    texture.color.setFill()
                    line.fill()
                case reflectionRow:
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: line).addClip()
                    liftedGradient?.draw(in: rect, angle: 90 - gradient.angleDegrees)
                    NSGraphicsContext.restoreGraphicsState()
                default:
                    break
                }
                y += 1
                row += 1
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
        case .rule:
            // The band's closing edge, and the only texture that draws one line rather than a
            // field of them — so it ignores `spacing` entirely. Placed at whichever edge is
            // visually the bottom: `cacheDisplay` into a bitmap can hand this view a flipped
            // context, and a rule that followed `minY` blindly would move to the top there,
            // which is the seam the whole family is built around.
            let flipped = NSGraphicsContext.current?.isFlipped ?? false
            texture.color.setFill()
            NSRect(
                x: rect.minX,
                y: flipped ? rect.maxY - 1 : rect.minY,
                width: rect.width,
                height: 1
            ).fill()
        case .brushedMetal:
            // Tiger's metal is a restrained one-pixel horizontal grain, not a noise cloud.
            // Two interleaved strengths keep it legible at 1x without turning the title bar
            // into Cheetah/Platinum pinstripes; the gradient remains the dominant material.
            var y = rect.minY + 1
            var line = 0
            while y < rect.maxY - 1 {
                // Preserve the authored opacity. Replacing it with the grain strength made a
                // deliberately faint Tiger texture render as 34%-opaque Platinum-like rules.
                let grainStrength: CGFloat = line.isMultiple(of: 3) ? 0.34 : 0.17
                texture.color.withAlphaComponent(
                    texture.color.alphaComponent * grainStrength
                ).setFill()
                NSRect(x: rect.minX, y: y.rounded(), width: rect.width, height: 1).fill()
                y += texture.spacing
                line += 1
            }
        }
    }

    /// Two compact raised rails, used by small hardware-like caption bands. Their endpoints
    /// come from the live button stacks and title frame, so the texture remains authorable for
    /// other centred, bookended chromes rather than encoding one stock theme's pixel widths.
    private func drawCaptionRails(
        _ texture: WindowChromeAppearance.Resolved.Texture,
        in rect: NSRect
    ) {
        guard resolvedStyle?.titleAlignment == .center,
              !titleLabel.frame.isEmpty else { return }

        let hardwareGap = Design.Spacing.tight
        let titleGap = Design.Spacing.small
        let start = max(rect.minX + hardwareGap, ceil(leadingButtonStack.frame.maxX) + hardwareGap)
        let end = min(rect.maxX - hardwareGap, floor(buttonStack.frame.minX) - hardwareGap)
        let titleStart = floor(titleLabel.frame.minX) - titleGap
        let titleEnd = ceil(titleLabel.frame.maxX) + titleGap
        let segments: [(x: CGFloat, width: CGFloat)] = [
            (start, titleStart - start),
            (titleEnd, end - titleEnd)
        ].filter { $0.width >= Design.Spacing.small }
        guard !segments.isEmpty else { return }

        // Draw in top-down order even when a bitmap-cache context flips the view. A dark lip,
        // the authored face, and a light catch make a three-pixel moulding instead of three
        // unrelated rules.
        let shadow = texture.color.blended(withFraction: 0.58, of: .black) ?? texture.color
        let highlight = texture.color.blended(withFraction: 0.22, of: .white) ?? texture.color
        let rows: [NSColor] = [shadow, texture.color, highlight]
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        let firstTopDownRow = max(1, floor((rect.height - CGFloat(rows.count)) / 2))

        for (row, color) in rows.enumerated() {
            color.setFill()
            let topDown = firstTopDownRow + CGFloat(row)
            let y = isFlipped
                ? rect.minY + topDown
                : rect.maxY - topDown - 1
            for segment in segments {
                NSRect(
                    x: segment.x,
                    y: y,
                    width: segment.width,
                    height: 1
                ).fill()
            }
        }
    }

    /// Charcoal is not redistributable with the app. The independently authored OFL bitmap
    /// fallback retains Platinum's one-bit QuickDraw rhythm and metrics instead of smoothing
    /// modern Geneva into the otherwise indexed title band. Unsupported Unicode or an
    /// explicit user font stays on the ordinary label path.
    private func drawPlatinumTitle(in rect: NSRect) {
        guard usesPlatinumBitmapTitle,
              let advance = PlatinumBitmapFont.advance(of: titleLabel.stringValue),
              // Jarrah keeps the classic 15px line metrics; Charcoal's ink sat one row above
              // the geometric centre inside the 17px Platinum band.
              let baseline = PlatinumBitmapFont.centeredBaseline(in: rect, offset: -1) else {
            return
        }
        PlatinumBitmapFont.draw(
            titleLabel.stringValue,
            penX: floor(rect.midX - CGFloat(advance) / 2) - 1,
            baselineFromTop: baseline,
            in: rect,
            ink: titleLabel.textColor ?? .black
        )
    }

    /// Platinum's active caption is twelve consecutive scanlines, alternating white and
    /// #777, rather than one dark rule over a gray fill every other row. The fields stop four
    /// pixels after the close slot and before the zoom slot, and part around a five-pixel title
    /// apron. Odd scanlines shift one pixel right, preserving the native stair-step ends.
    private func drawPlatinumPinstripes(in rect: NSRect) {
        guard rect.height >= 13 else { return }
        let leftStart = ceil(leadingButtonStack.frame.maxX) + 4
        let rightEnd = floor(buttonStack.frame.minX) - 5
        let measuredTitleWidth = ceil(titleLabel.attributedStringValue.size().width)
        // The original Charcoal face leaves a four-pixel clear run on either side of its
        // raster. Geneva's measured advance includes less of that bearing, so add the full
        // five pixels here after the rounded fallback advance to retain the native 84px gap.
        let apronWidth = measuredTitleWidth + 5
        let apronCenter = floor(rect.midX) - 1
        let titleStart = floor(apronCenter - apronWidth / 2)
        let titleEnd = titleStart + apronWidth
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false

        for topDownRow in 1...12 {
            let phase = topDownRow.isMultiple(of: 2) ? CGFloat(1) : 0
            (topDownRow.isMultiple(of: 2)
                ? NSColor(srgbRed: 119 / 255, green: 119 / 255, blue: 119 / 255, alpha: 1)
                : NSColor.white).setFill()
            let y = isFlipped
                ? rect.minY + CGFloat(topDownRow)
                : rect.maxY - CGFloat(topDownRow + 1)
            let left = NSRect(
                x: leftStart + phase,
                y: y,
                width: max(0, titleStart - leftStart),
                height: 1
            )
            let right = NSRect(
                x: titleEnd + phase,
                y: y,
                width: max(0, rightEnd - titleEnd + 1),
                height: 1
            )
            left.fill()
            right.fill()
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

        if resolved.glyphStyle == .beOS {
            drawBeOSTabEdge(in: rect)
            return
        }

        guard AppThemePalette.current.material.bevel != nil else {
            Design.Surface.border.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
            return
        }

        WindowChromeBevelEdge.drawRaisedRings(around: rect)
    }

    /// R5's yellow tab owns a three-tone ochre edge rather than borrowing the application's
    /// white/gray control bevel. Its top and leading sides are lemon, with a brown inner rail
    /// and neutral #606060 outer rail at the trailing edge; there is no bottom rule in the
    /// title-tab control itself.
    private func drawBeOSTabEdge(in rect: NSRect) {
        let highlight = NSColor(
            srgbRed: 1, green: 1, blue: 80 / 255, alpha: 1
        )
        let innerShadow = NSColor(
            srgbRed: 175 / 255, green: 123 / 255, blue: 0, alpha: 1
        )
        let outerShadow = NSColor(
            srgbRed: 96 / 255, green: 96 / 255, blue: 96 / 255, alpha: 1
        )
        innerShadow.setFill()
        NSRect(x: rect.maxX - 2, y: rect.minY, width: 1, height: rect.height).fill()
        outerShadow.setFill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        highlight.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        NSRect(
            x: rect.minX,
            y: rect.maxY - 1,
            width: max(0, rect.width - 1),
            height: 1
        ).fill()
    }

    // MARK: - Accessibility

    /// The band itself is furniture; its controls speak for themselves. Announced as a group
    /// so VoiceOver users hear the window's controls as one cluster, the way the titlebar was.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}

/// Adobe's 12pt, 75dpi Helvetica Bold screen font—the one-bit glyphs in the OPENSTEP
/// reference—reduced to printable ASCII and a compact metric/row stream. This is a bitmap
/// renderer, not a bundled modern outline font: arbitrary non-ASCII titles and any explicit
/// user/theme font choice continue through AppKit above.
///
/// Source: X.Org `font-adobe-75dpi-1.0.4/helvB12.bdf`.
///
/// Copyright 1984-1989, 1994 Adobe Systems Incorporated.
/// Copyright 1988, 1994 Digital Equipment Corporation.
///
/// Permission to use, copy, modify, distribute and sell this software and its documentation
/// for any purpose and without fee is hereby granted, provided that the above copyright
/// notices and this permission notice appear in all copies and supporting documentation, and
/// that the names of Adobe Systems and Digital Equipment Corporation are not used in
/// advertising or publicity pertaining to distribution without specific written permission.
/// Adobe is a trademark of Adobe Systems Incorporated which may be registered in certain
/// jurisdictions. Permission to use these trademarks is granted only for identifying the
/// Adobe products described in this software. Adobe Systems Incorporated and Digital
/// Equipment Corporation make no representations about the suitability of this software for
/// any purpose. It is provided “as is” without express or implied warranty.
private enum OpenStepBitmapCaptionFont {
    private struct Glyph {
        let advance: Int
        let width: Int
        let height: Int
        let xOffset: Int
        let yOffset: Int
        let rows: [UInt16]
    }

    private struct Face {
        let ascent: Int
        let descent: Int
        let glyphs: [UInt16: Glyph]
    }

    /// Record: codepoint:u16, advance:u8, width:u8, height:u8, x/y offsets:i8,
    /// then one right-aligned u16 bitmap per top-to-bottom row. The three-byte header is
    /// record count, ascent, descent.
    private static let encoded = """
    XwsDACAEAQEAAAAAACEEAgkBAAADAAMAAwADAAMAAgAAAAMAAwAiBQMDAQYABQAFAAUAIwgHCAAAAAoACgA/ABQAFAB+ACgAKAAk
    BwYLAP4ABAAeADUANAAeAAcAJQA1AB4ABAAEACUMCwkAAAOIBtgG0AOgACAATgBbANsAjgAmCQkJAAAAcADYANgAcADyAZ4BjAGe
    APMAJwMBAwEGAAEAAQABACgGBAwB/QADAAYABgAMAAwADAAMAAwADAAGAAYAAwApBgQMAf0ADAAGAAYAAwADAAMAAwADAAMABgAG
    AAwAKgYFBAAFAAQAHwAOAAoAKwcGBQABAAwADAA/AAwADAAsBAIEAf4AAwADAAEAAgAtBQQBAAMADwAuBAICAQAAAwADAC8EBAkA
    AAADAAMAAgAGAAYABAAEAAwADAAwBwYJAAAAHgAzADMAMwAzADMAMwAzAB4AMQcECQAAAAMADwADAAMAAwADAAMAAwADADIHBgkA
    AAAeADMAAwAGAAwAGAAwADAAPwAzBwYJAAAAHgAzAAMADgADAAMAAwAzAB4ANAcHCQAAAAYADgAWABYAJgBGAH8ABgAGADUHBgkA
    AAAfABgAMAA+AAMAAwAzADMAHgA2BwYJAAAAHgAzADAAMAA+ADMAMwAzAB4ANwcGCQAAAD8AAwAGAAYADAAMAAwAGAAYADgHBgkA
    AAAeADMAMwAeADMAMwAzADMAHgA5BwYJAAAAHgAzADMAMwAfAAMAAwAzAB4AOgQCBwEAAAMAAwAAAAAAAAADAAMAOwQCCQH+AAMA
    AwAAAAAAAAADAAMAAQACADwHBQUBAQADAA4AGAAOAAMAPQcGAwACAD8AAAA/AD4HBQUBAQAYAA4AAwAOABgAPwgGCQEAAB4AMwAz
    AAYADAAMAAAADAAMAEAMCgoB/wB8AYIBAQI1AkkCiQKaAmwBAAD4AEEICAkAAAAYADwAJABmAGYAfgDDAMMAwwBCCQcJAQAAfgBj
    AGMAYwB+AGMAYwBjAH4AQwgHCQEAAB4AMwBgAGAAYABgAGAAMwAeAEQJBwkBAAB8AGYAYwBjAGMAYwBjAGYAfABFCAYJAQAAPwAw
    ADAAMAA/ADAAMAAwAD8ARgcGCQEAAD8AMAAwADAAPgAwADAAMAAwAEcKCAkBAAA+AGMAwADAAM8AwwDDAGMAPQBICQcJAQAAYwBj
    AGMAYwB/AGMAYwBjAGMASQQCCQEAAAMAAwADAAMAAwADAAMAAwADAEoHBgkAAAADAAMAAwADAAMAAwAzADMAHgBLCQgJAQAAxgDM
    ANgA8ADwANgAzADGAMMATAcGCQEAADAAMAAwADAAMAAwADAAMAA/AE0LCQkBAAGDAYMBxwHHAe8BqwG7AZMBkwBOCQcJAQAAYwBz
    AHMAawBrAGcAZwBjAGMATwoICQEAADwAZgDDAMMAwwDDAMMAZgA8AFAIBwkBAAB+AGMAYwBjAH4AYABgAGAAYABRCggJAQAAPABm
    AMMAwwDDAMsAzwBmAD8AUgkHCQEAAH4AYwBjAGMAfgBmAGMAYwBjAFMJBwkBAAA+AGMAYwA4AA4ABwBjAGMAPgBUCAgJAAAA/wAY
    ABgAGAAYABgAGAAYABgAVQkHCQEAAGMAYwBjAGMAYwBjAGMANgA+AFYICAkAAADDAMMAZgBmAGYAJAA8ABgAGABXCgoJAAADMwMz
    AzMBMgG2AbYAzADMAMwAWAgICQAAAMMAwwBmADwAGAA8AGYAwwDDAFkICAkAAADDAMMAZgBmADwAGAAYABgAGABaBwcJAAAAfwAD
    AAYADAAYABgAMABgAH8AWwQDDAH9AAcABgAGAAYABgAGAAYABgAGAAYABgAHAFwEBAkAAAAMAAwABAAGAAYAAgACAAMAAwBdBAMM
    AP0ABwADAAMAAwADAAMAAwADAAMAAwADAAcAXgcHBAAFAAgAHAA2AGMAXwcHAQD9AH8AYAQDAgAIAAYAAwBhBwcHAAAAPABmAAYA
    PgBmAGYAOwBiBwYJAAAAMAAwADYAOwAzADMAMwA7ADYAYwcGBwAAAB4AMwAwADAAMAAzAB4AZAcGCQAAAAMAAwAbADcAMwAzADMA
    NwAbAGUHBgcAAAAeADMAMwA/ADAAMwAeAGYFBQkAAAAHAAwAHgAMAAwADAAMAAwADABnBwYKAP0AGwA3ADMAMwAzADcAGwADADMA
    HgBoBwYJAAAAMAAwADYAOwAzADMAMwAzADMAaQMCCQAAAAMAAAADAAMAAwADAAMAAwADAGoDAwz//QADAAAAAwADAAMAAwADAAMA
    AwADAAMABgBrBwcJAAAAYABgAGYAbAB4AHgAbABmAGMAbAMCCQAAAAMAAwADAAMAAwADAAMAAwADAG0LCgcAAALuAzMDMwMzAzMD
    MwMzAG4HBgcAAAA2ADsAMwAzADMAMwAzAG8HBgcAAAAeADMAMwAzADMAMwAeAHAHBgoA/QA2ADsAMwAzADMAOwA2ADAAMAAwAHEH
    BgoA/QAdADcAMwAzADMANwAbAAMAAwADAHIFBQcAAAAbAB8AHAAYABgAGAAYAHMHBgcAAAAeADMAOAAOAAcAMwAeAHQFBQkAAAAM
    AAwAHgAMAAwADAAMAA0ABgB1BwYHAAAAMwAzADMAMwAzADcAGwB2CAcHAAAAYwBjADYANgAcABwACAB3CwoHAAADMwMzAbYBtgG2
    AMwAzAB4BwYHAAAAMwAzAB4ADAAeADMAMwB5CAcKAP0AYwBjADYANgAcABwADAAIABgAMAB6BgUHAAAAHwADAAYABAAMABgAHwB7
    BQQMAP0AAwAGAAYABgAGAAwABgAGAAYABgAGAAMAfAQCDAH9AAMAAwADAAMAAwADAAMAAwADAAMAAwADAH0FBAwA/QAMAAYABgAG
    AAYAAwAGAAYABgAGAAYADAB+BwcCAAMAOwBu
    """

    private static let face: Face? = {
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              data.count >= 3 else { return nil }
        var cursor = data.startIndex
        func byte() -> UInt8? {
            guard cursor < data.endIndex else { return nil }
            defer { cursor += 1 }
            return data[cursor]
        }
        guard let rawCount = byte(), let rawAscent = byte(), let rawDescent = byte() else {
            return nil
        }
        var glyphs: [UInt16: Glyph] = [:]
        for _ in 0..<Int(rawCount) {
            guard let high = byte(), let low = byte(),
                  let advance = byte(), let width = byte(), let height = byte(),
                  let xOffset = byte(), let yOffset = byte() else { return nil }
            var rows: [UInt16] = []
            rows.reserveCapacity(Int(height))
            for _ in 0..<Int(height) {
                guard let rowHigh = byte(), let rowLow = byte() else { return nil }
                rows.append((UInt16(rowHigh) << 8) | UInt16(rowLow))
            }
            glyphs[(UInt16(high) << 8) | UInt16(low)] = Glyph(
                advance: Int(advance),
                width: Int(width),
                height: Int(height),
                xOffset: Int(Int8(bitPattern: xOffset)),
                yOffset: Int(Int8(bitPattern: yOffset)),
                rows: rows
            )
        }
        return Face(ascent: Int(rawAscent), descent: Int(rawDescent), glyphs: glyphs)
    }()

    /// Returns false when the title contains a glyph outside the preserved printable-ASCII
    /// set, letting the caller render it through the user's normal AppKit font instead.
    static func draw(_ text: String, centeredIn rect: NSRect, ink: NSColor) -> Bool {
        guard let face else { return false }
        let codepoints = text.unicodeScalars.map(\.value)
        var glyphRun: [Glyph] = []
        glyphRun.reserveCapacity(codepoints.count)
        for codepoint in codepoints {
            guard codepoint <= UInt32(UInt16.max),
                  let glyph = face.glyphs[UInt16(codepoint)] else { return false }
            glyphRun.append(glyph)
        }

        let advance = glyphRun.reduce(0) { $0 + $1.advance }
        var penX = floor(rect.midX - CGFloat(advance) / 2)
        let lineHeight = face.ascent + face.descent
        let baselineFromTop = ceil((rect.height - CGFloat(lineHeight)) / 2)
            + CGFloat(face.ascent)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        ink.setFill()
        for glyph in glyphRun {
            let glyphTop = baselineFromTop - CGFloat(glyph.yOffset + glyph.height)
            for (rowIndex, bits) in glyph.rows.enumerated() {
                let visualY = glyphTop + CGFloat(rowIndex)
                let y = isFlipped
                    ? rect.minY + visualY
                    : rect.maxY - visualY - 1
                for column in 0..<glyph.width where
                    bits & (UInt16(1) << (glyph.width - column - 1)) != 0 {
                    NSRect(
                        x: penX + CGFloat(glyph.xOffset + column),
                        y: y,
                        width: 1,
                        height: 1
                    ).fill()
                }
            }
            penX += CGFloat(glyph.advance)
        }
        return true
    }
}

/// Adobe's 14pt, 75dpi Helvetica Bold Oblique X11 screen face, reduced to printable ASCII.
/// Six glyph cells carry the one-bit deltas measured in the native IRIX 5.3 Showcase title;
/// the resulting face reproduces that complete caption while remaining useful for arbitrary
/// ASCII window titles. An explicit user font selection continues through AppKit instead.
///
/// Source: X.Org `font-adobe-75dpi-1.0.4/helvBO14.bdf`.
///
/// Copyright 1984-1989, 1994 Adobe Systems Incorporated.
/// Copyright 1988, 1994 Digital Equipment Corporation.
///
/// Permission to use, copy, modify, distribute and sell this software and its documentation
/// for any purpose and without fee is hereby granted, provided that the above copyright
/// notices and this permission notice appear in all copies and supporting documentation, and
/// that the names of Adobe Systems and Digital Equipment Corporation are not used in
/// advertising or publicity pertaining to distribution without specific written permission.
/// Adobe is a trademark of Adobe Systems Incorporated which may be registered in certain
/// jurisdictions. Permission to use these trademarks is granted only for identifying the
/// Adobe products described in this software. Adobe Systems Incorporated and Digital
/// Equipment Corporation make no representations about the suitability of this software for
/// any purpose. It is provided “as is” without express or implied warranty.
private enum IRIXBitmapCaptionFont {
    private struct Glyph {
        let advance: Int
        let width: Int
        let height: Int
        let xOffset: Int
        let yOffset: Int
        let rows: [UInt16]
    }

    private static let encoded = """
    Xw0DACAEAAAAAAAhBQULAgAAAwADAAYABgAGAAwADAAIAAAAGAAYACIHBQMECAAbABsAEgAjCgoKAQAANgA2AGwB/wBsANgD/AGwA2ADYAAkCAgMAf8ABAA+
    AGsAaAA4ABwAFgAWAKYA7AB4AEAAJQ0LCgIAAcMDJgJsAdgAMABgANwBsgMmBhwAJgsKCgEAADgAbABMAFgA8wGbAw4DDAOeAfMAJwQCAwQIAAMAAwACACgF
    Bg4C/QADAAYADAAYABgAMAAwADAAMAAwADAAGAAYAAwAKQYGDgD9AAwABgAGAAMAAwADAAMAAwADAAYABgAMABgAMAAqBgUEAwcABAAfAAwAFAArCQcHAgEA
    DAAMAAwAfwAYABgAGAAsBAMEAP4AAwADAAEABgAtBQUBAQQAHwAuBAICAQAAAwADAC8EBwsAAAADAAIABgAEAAwACAAYABAAMAAgAGAAMAgICgEAAB4AMwBj
    AGMAMwDDAMYAxgDMAHgAMQgFCwMAAAMADwADAAYABgAGAAwADAAMABgAGAAyCAgKAQAAPgBjAGMABwAOADgAcADAAMAA/AAzCAgLAQAAHgAzADMAAwAGABwA
    BgAGAMYAzAB4ADQICAoBAAADAAcAGwAzAGYAxgD/AAwADAAMADUICAoBAAA/ADAAYAB8AA4ABgAGAMYAzAB4ADYICAoBAAAeADMAYABAANwA9gDGAMYAzAB4
    ADcIBwoCAAA/AAMABgAMABgAGAAwADAAYABgADgICAoBAAAeADMAYwBmADwAZgDGAMYAzAB4ADkICAoBAAAeADMAYwBjAGMAPgAGAMYAzAB4ADoFBAgCAAAD
    AAMAAAAAAAAAAAAMAAwAOwUFCgH+AAMAAwAAAAAAAAAAAAwADAAEABgAPAgIBQECAAcAPADgADgADgA9CQgDAgMAfwAAAP4APgkIBQECAHAAHAAHADwA4AA/
    CQgLAwAAPgBjAGMABgAcADAAYABgAAAAwADAAEAODQ0C/gD8A4YGAwxpCZkZMxIyEmYTbBm4CAAOOAPgAEEJCQsAAAAGAA4AGwAbADMAMwBjAP8AwwGDAYMA
    QgoKCwEAAH4AYwBjAMMAxgD8AYYBhgGGAwwD+ABDCwoLAgAAHgBzAMMBgAGAAwADAAMAAwYBnADwAEQLCwsBAAD8AMYAwwGDAYMBgwMGAwYDDAY4B+AARQkK
    CwEAAH8AYABgAMAAwAD+AYABgAGAAwAD+ABGCAoLAQAAfwBgAGAAwADAAPwBgAGAAYADAAMAAEcLCgsCAAAeAHMAwwGAAYADDwMGAwYDDAGcAPQASAoLCwEA
    AMMAwwDDAYYBhgH+AwwDDAMMBhgGGABJBAULAQAAAwADAAMABgAGAAYADAAMAAwAGAAYAEoICQsBAAADAAMAAwAGAAYABgAMAYwBjAHYAPAASwoLCwEAAMMA
    xgDMAZgBsAHgA7ADMAMYBhgGDABMCAcLAQAADAAMAAwAGAAYABgAMAAwADAAYAB/AE0NDgsBAAYDBgcGDw8aDTYNJhlsGcwZzDGYMZgATgsMCwEAAYMBgwHD
    A8YDZgNmBmwGLAY8DBgMGABPDAsLAgAAPADmAYMDAwMDBgMGBgYGBgwDOAHgAFAKCgsBAAB+AGMAYwDDAMYA/AGAAYABgAMAAwAAUQwLCwIAADwA5gGDAwMD
    AwYDBgYGNgYcAzgB7ABSCgoLAQAAfgBjAGMAwwDGAPwBhgGGAYYDDAMMAFMKCgsBAAA+AGMAwwDgAHgAHAAOAAYDBgMMAfgAVAgICwMAAP8AGAAYADAAMAAw
    AGAAYABgAMAAwABVCwsLAgABgwGDAYMDBgMGAwYGDAYMBgwGGAPwAFYKCQsDAAGDAYMBhgGGAYwBjAGYAZgAsADgAMAAVw4NCwMAGMMYwxjGGcYZzBlMG1ga
    WA5wDHAMYABYCQwLAAABgwGGAMwA2ABwAGAA4AGwAzAGGAwYAFkKCgsDAAMDAwYDDAGYAbAB4ADAAMABgAGAAYAAWgkLCwAAAP8ABgAMABgAMABgAMABgAMA
    BgAH+ABbBQgOAP0ADwAMAAwAGAAYABgAMAAwADAAYABgAMAAwADwAFwGAwsDAAAGAAYABgACAAIAAgACAAMAAwADAAMAXQUIDv/9AA8AAwADAAYABgAGAAwA
    DAAMABgAGAAwADAA8ABeCAYGAwUABgAOABsAGwAzADMAXwgIAf/9AP8AYAUDAgQJAAYAAwBhCAgIAQAAHgAzAAMAPgBmAMYAzAB2AGIJCQsBAAAwADAAYABu
    AHMAYwDGAMYBhgHMAbgAYwgICAEAAB4AMwBjAGAAwADGAMwAeABkCQoLAQAAAwADAAYAdgDOAYYBjAMMAwwDOAHYAGUICAgBAAAeADMAYwB+AMAAwADMAHgA
    ZgUHCwEAAAcADAAMAD4AGAAYADAAMAAwAGAAYABnCQoLAP0AOwBnAMMAxgGGAYYBnADsAAwDGAHwAGgJCQsBAAAwADAAYABuAHcAYwDGAMYAxgGMAYwAaQQF
    CwEAAAMAAwAAAAYABgAGAAwADAAMABgAGABqBAcO//0AAwADAAAABgAGAAYADAAMAAwAGAAYABgAcABgAGsICAsBAAAYABgAMAAzADYAPAB4AGwAbADMAMwA
    bAQFCwEAAAMAAwAGAAYABgAMAAwADAAMABgAGABtDAwIAQADbgO7AzMGZgZmBmYMzAzMAG4JCQgBAABuAHMAYwDGAMYAxgGMAYwAbwgICAEAAB4AMwBjAGMA
    xgDGAMwAeABwCQoLAP0AbgBzAOMAwwDGAMYB7AG4AYADAAMAAHEJCQsB/QA7AGcAwwDGAYYBhgGcAOwADAAYABgAcgYHCAEAABsAHwAYADAAMAAwAGAAYABz
    CAgIAQAAHgAzADAAHAAGAMYAzAB4AHQFBgoBAAAGAAYAHwAMAAwAGAAYADAAMAAYAHUJCQgBAABjAGMAwwDGAMYBjAGcAOwAdggICAIAAMMAwwDGAMwAzABY
    AHAAYAB3CwoIAgADMwMzAzMDdgNWA9wBmAGYAHgHCQgAAABjAGYALAA4ADgAaADMAYwAeQcJCwD9AGMAYwBmAGYAbABsADgAMABgAMABgAB6BggIAAAAPwAG
    AAwAGAAwAGAAwAD8AHsGBw4B/QADAAYADAAMAAwAGABgADAAMAAwAGAAYABgADAAfAQGDgD9AAMAAwADAAIABgAGAAQADAAMAAgAGAAYABAAMAB9BgcOAP0A
    BgADAAMAAwAGAAYAAwAMAAwAGAAYABgAMABgAH4JCAMCAwBxANsAjg==
    """

    private static let glyphs: [UInt16: Glyph]? = {
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              data.count >= 3 else { return nil }
        var cursor = data.startIndex
        func byte() -> UInt8? {
            guard cursor < data.endIndex else { return nil }
            defer { cursor += 1 }
            return data[cursor]
        }
        guard let rawCount = byte(), byte() != nil, byte() != nil else { return nil }
        var result: [UInt16: Glyph] = [:]
        for _ in 0..<Int(rawCount) {
            guard let high = byte(), let low = byte(),
                  let advance = byte(), let width = byte(), let height = byte(),
                  let xOffset = byte(), let yOffset = byte() else { return nil }
            var rows: [UInt16] = []
            rows.reserveCapacity(Int(height))
            for _ in 0..<Int(height) {
                guard let rowHigh = byte(), let rowLow = byte() else { return nil }
                rows.append((UInt16(rowHigh) << 8) | UInt16(rowLow))
            }
            result[(UInt16(high) << 8) | UInt16(low)] = Glyph(
                advance: Int(advance),
                width: Int(width),
                height: Int(height),
                xOffset: Int(Int8(bitPattern: xOffset)),
                yOffset: Int(Int8(bitPattern: yOffset)),
                rows: rows
            )
        }
        return result
    }()

    static func draw(
        _ text: String,
        penX: CGFloat,
        baselineFromTop: CGFloat,
        in rect: NSRect,
        ink: NSColor
    ) -> Bool {
        guard let glyphs else { return false }
        var run: [Glyph] = []
        run.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            guard scalar.value <= UInt32(UInt16.max),
                  let glyph = glyphs[UInt16(scalar.value)] else { return false }
            run.append(glyph)
        }

        var x = penX
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        ink.setFill()
        for glyph in run {
            let glyphTop = baselineFromTop - CGFloat(glyph.yOffset + glyph.height)
            for (rowIndex, bits) in glyph.rows.enumerated() {
                let visualY = glyphTop + CGFloat(rowIndex)
                let y = isFlipped
                    ? rect.minY + visualY
                    : rect.maxY - visualY - 1
                for column in 0..<glyph.width where
                    bits & (UInt16(1) << (glyph.width - column - 1)) != 0 {
                    NSRect(
                        x: x + CGFloat(glyph.xOffset + column),
                        y: y,
                        width: 1,
                        height: 1
                    ).fill()
                }
            }
            x += CGFloat(glyph.advance)
        }
        return true
    }
}
