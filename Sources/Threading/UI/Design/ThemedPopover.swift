import AppKit

/// App-owned popover chrome with AppKit-compatible anchoring semantics.
///
/// The content remains an ordinary view controller. This type owns only the presentation:
/// themed surface and arrow, screen-edge flipping, transient dismissal, Escape, focus return,
/// and following the window it is attached to. Context and menu-bar menus deliberately do not
/// use this type; their system behavior is part of their value.
@MainActor
final class ThemedPopover {

    enum Behavior {
        /// The owner closes the popover. Escape remains a universal way out.
        case applicationDefined
        /// A click outside the popover closes it.
        case transient
        /// A click back in the presenting window closes it, while auxiliary panels stay usable.
        case semitransient
    }

    var behavior: Behavior = .applicationDefined
    var animates = true
    var contentViewController: NSViewController?
    var onClose: (() -> Void)?

    private(set) var isShown = false
    var presentedWindow: NSWindow? { panel }

    /// Every popover currently on screen, so the one thing that outranks it can find it.
    ///
    /// A popover is a child *window* above the window it hangs off; a themed dropdown is a
    /// view inside that window's content. Whatever order the two open in, the popover is on
    /// top — which is how a hover card left over a sidebar row came to cover the menu that
    /// row's own `+` had just opened, and to swallow the clicks meant for its rows. Weak, and
    /// dropped on close: nothing here extends a popover's life.
    private static let shown = NSHashTable<ThemedPopover>.weakObjects()

    private let panelOwner = ThemedPopoverPanelOwner()
    private var panel: ThemedPopoverPanel? {
        get { panelOwner.panel }
        set { panelOwner.panel = newValue }
    }
    private weak var anchorView: NSView?
    private var anchorRect: NSRect = .zero
    private var preferredEdge: NSRectEdge = .maxY
    private weak var presentingWindow: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    private let eventMonitor = LocalEventMonitor()
    private let windowEvents = AppEventObservations()
    private var preferredSizeObservation: NSKeyValueObservation?
    private let appEvents = AppEventObservations()

    init() {
        // A theme switch can change the presentation's geometry, not just its colours: classic
        // hard-bevel materials remove the modern speech-arrow and spend that space on a square
        // period frame. Reposition while the popover is open so the old silhouette never lingers.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.reposition() }
    }

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        guard let parent = positioningView.window, let controller = contentViewController else { return }
        // The other half of `closeAll(presentedFrom:)`: a dropdown already up in this window
        // would end up underneath, and hover tracking keeps firing while one is open — a row
        // the pointer crosses on its way down a menu must not raise a card over it. The
        // platform answers the same way: an open menu owns the pointer, and nothing hover
        // brings up appears while it does.
        guard !ThemedMenuPresenter.isMenuOpen(in: parent) else { return }
        if isShown { close() }

        self.anchorView = positioningView
        self.anchorRect = positioningRect
        self.preferredEdge = preferredEdge
        presentingWindow = parent
        previousFirstResponder = parent.firstResponder

        let panel = ThemedPopoverPanel()
        panel.onCancel = { [weak self] in self?.close() }
        panel.chromeView.onStyleChange = { [weak self] in self?.reposition() }
        panel.contentViewController = ThemedPopoverHostController(
            chrome: panel.chromeView,
            content: controller
        )
        panel.appearance = parent.appearance
        self.panel = panel

        parent.addChildWindow(panel, ordered: .above)
        reposition()
        installObservation()
        installEventMonitor()

        isShown = true
        Self.shown.add(self)
        panel.alphaValue = animates && Design.Motion.standard > 0 ? 0 : 1
        panel.orderFront(nil)
        if panel.alphaValue == 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Design.Motion.standard
                panel.animator().alphaValue = 1
            }
        }

        preferredSizeObservation = controller.observe(\.preferredContentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        NSAccessibility.post(element: panel, notification: .created)
    }

    /// Closes the popovers a dropdown opening in `window` would be drawn behind.
    ///
    /// Called by `ThemedMenuPresenter` before it installs its overlay, for the reason `shown`
    /// states. A dropdown opened from a control *inside* a popover is presented in that
    /// panel's own window rather than the window the popover hangs off, so the surface
    /// carrying the menu is not one of these and stays open.
    static func closeAll(presentedFrom window: NSWindow) {
        for popover in shown.allObjects where popover.presentingWindow === window {
            popover.close()
        }
    }

    func close() {
        guard isShown || panel != nil else { return }
        isShown = false
        Self.shown.remove(self)
        removeEventMonitor()
        removeObservation()
        preferredSizeObservation = nil

        guard let panel else { return }
        let parent = presentingWindow
        let wasKey = panel.isKeyWindow
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentViewController = nil
        self.panel = nil

        if wasKey, let parent {
            parent.makeKey()
            if let responder = previousFirstResponder,
               responder.isDescendantResponder(of: parent) {
                parent.makeFirstResponder(responder)
            }
        }
        onClose?()
    }

    /// Re-measures dynamic content and keeps the arrow attached to its anchor.
    func reposition() {
        guard let panel, let anchorView, let window = anchorView.window,
              let screen = window.screen ?? NSScreen.main,
              let controller = contentViewController else {
            if isShown { close() }
            return
        }

        controller.view.layoutSubtreeIfNeeded()
        let fitting = controller.view.fittingSize
        let preferred = controller.preferredContentSize
        let contentSize = NSSize(
            width: max(1, preferred.width > 0 ? preferred.width : fitting.width),
            height: max(1, preferred.height > 0 ? preferred.height : fitting.height)
        )
        let screenAnchor = window.convertToScreen(anchorView.convert(anchorRect, to: nil))
        let material = AppThemePalette.current.material(for: panel.effectiveAppearance)
        let placement = ThemedPopoverLayout.place(
            anchor: screenAnchor,
            contentSize: contentSize,
            visibleFrame: screen.visibleFrame,
            preferredEdge: preferredEdge,
            style: material.popoverStyle,
            hasMaterialShadow: material.glow != nil,
            bevelWidth: material.bevel?.width
        )

        panel.setFrame(placement.panelFrame, display: panel.isVisible)
        panel.apply(style: placement.style, hasMaterialShadow: placement.hasMaterialShadow)
        panel.chromeView.placement = placement
        panel.chromeView.contentView = controller.view
        panel.invalidateShadow()
    }

    private func installObservation() {
        guard let window = presentingWindow else { return }
        windowEvents.removeAll()
        let repositionNames: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification
        ]
        for name in repositionNames {
            windowEvents.observe(name, object: window) { [weak self] in self?.reposition() }
        }
        windowEvents.observe(NSWindow.willCloseNotification, object: window) { [weak self] in
            self?.close()
        }
        windowEvents.observe(NSApplication.didResignActiveNotification, object: NSApp) {
            [weak self] in
            guard self?.behavior != .applicationDefined else { return }
            self?.close()
        }
    }

    private func removeObservation() {
        windowEvents.removeAll()
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor.install(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.isShown else { return event }
            // The anchor can leave the hierarchy without any notification this type observes —
            // a sidebar reload discards its rows in place — and an owner waiting on hover exit
            // never hears about it either. The next interaction anywhere is the moment a
            // popover pointing at nothing disappears, whatever the behavior mode.
            if self.anchorView?.window == nil {
                self.close()
                return event
            }
            if event.type == .keyDown, event.charactersIgnoringModifiers == "\u{1b}" {
                self.close()
                return nil
            }

            guard event.type != .keyDown, event.window !== self.panel else { return event }
            switch self.behavior {
            case .applicationDefined:
                break
            case .transient:
                self.close()
            case .semitransient:
                if event.window === self.presentingWindow { self.close() }
            }
            return event
        }
    }

    private func removeEventMonitor() {
        eventMonitor.remove()
    }

}

/// Owns the panel past the main-actor presenter's lifetime. A parent window retains its child
/// windows, so an owner dropped without `close()` must still detach the panel or it remains visible
/// after the monitor that could dismiss it is gone. Uniquely owned storage makes that exceptional
/// deinit handoff explicit without exposing the presenter's mutable property as unsafe.
private final class ThemedPopoverPanelOwner: @unchecked Sendable {
    var panel: ThemedPopoverPanel?

    deinit {
        guard let panel else { return }
        self.panel = nil
        let handoff = ThemedPopoverPanelHandoff(panel)
        if Thread.isMainThread {
            MainActor.assumeIsolated { Self.detach(handoff) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Self.detach(handoff) }
            }
        }
    }

    @MainActor
    private static func detach(_ handoff: ThemedPopoverPanelHandoff) {
        let panel = handoff.panel
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentViewController = nil
    }
}

/// Carries the panel across `ThemedPopoverPanelOwner`'s deinit-to-main hop.
private final class ThemedPopoverPanelHandoff: @unchecked Sendable {
    let panel: ThemedPopoverPanel
    init(_ panel: ThemedPopoverPanel) { self.panel = panel }
}

// MARK: - Placement

/// Pure screen geometry for an anchored popover, shared by presentation and tests.
@MainActor
enum ThemedPopoverLayout {
    static let arrowLength: CGFloat = 10
    static let arrowBreadth: CGFloat = 18
    static let anchorGap: CGFloat = 2
    static let screenInset: CGFloat = 8
    static let borderInset: CGFloat = 1
    static let compactArrowLength: CGFloat = 7
    static let compactArrowBreadth: CGFloat = 12
    static let compactAnchorGap: CGFloat = 1
    static let compactScreenInset: CGFloat = 4
    static let compactBorderInset: CGFloat = 0.5

    struct Placement: Equatable {
        let edge: NSRectEdge
        let panelFrame: NSRect
        let bodyFrame: NSRect
        let contentFrame: NSRect
        let arrowTip: NSPoint
        let classic: Bool
        let arrowBreadth: CGFloat
        let style: AppTheme.Material.PopoverStyle
        let hasMaterialShadow: Bool

        var hasArrow: Bool { style.arrow == .triangle }
    }

    /// Compatibility entry for geometry tests written before popover presentation became
    /// material data. Product presentation uses the style-bearing overload below.
    static func place(
        anchor: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect,
        preferredEdge: NSRectEdge,
        classic: Bool = false
    ) -> Placement {
        let style = classic
            ? AppTheme.Material.PopoverStyle(
                arrow: .none,
                edge: .material,
                shadow: .none,
                density: .compact,
                glyphStyle: .classic
            )
            : .system
        return place(
            anchor: anchor,
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            preferredEdge: preferredEdge,
            style: style,
            hasMaterialShadow: false,
            bevelWidth: classic ? AppThemePalette.current.material.bevel?.width : nil
        )
    }

    static func place(
        anchor: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect,
        preferredEdge: NSRectEdge,
        style: AppTheme.Material.PopoverStyle,
        hasMaterialShadow: Bool,
        bevelWidth: CGFloat? = nil
    ) -> Placement {
        let metrics = Metrics(
            style: style,
            hasMaterialShadow: hasMaterialShadow,
            bevelWidth: bevelWidth
        )
        let preferred = supported(preferredEdge) ? preferredEdge : .maxY
        let opposite = opposite(of: preferred)
        let needed = requiredSpace(for: preferred, contentSize: contentSize, metrics: metrics)
        let preferredSpace = availableSpace(for: preferred, anchor: anchor, screen: visibleFrame)
        let oppositeSpace = availableSpace(for: opposite, anchor: anchor, screen: visibleFrame)
        let edge = preferredSpace >= needed || preferredSpace >= oppositeSpace ? preferred : opposite

        let bodySize = NSSize(
            width: contentSize.width + 2 * metrics.borderInset,
            height: contentSize.height + 2 * metrics.borderInset
        )
        let surfaceSize: NSSize
        if edge == .minX || edge == .maxX {
            surfaceSize = NSSize(
                width: bodySize.width + metrics.arrowLength,
                height: bodySize.height
            )
        } else {
            surfaceSize = NSSize(
                width: bodySize.width,
                height: bodySize.height + metrics.arrowLength
            )
        }
        let panelSize = NSSize(
            width: surfaceSize.width + 2 * metrics.shadowGutter,
            height: surfaceSize.height + 2 * metrics.shadowGutter
        )

        var origin: NSPoint
        switch edge {
        case .maxX:
            origin = NSPoint(
                x: anchor.maxX + metrics.anchorGap - metrics.shadowGutter,
                y: anchor.midY - surfaceSize.height / 2 - metrics.shadowGutter
            )
        case .minX:
            origin = NSPoint(
                x: anchor.minX - metrics.anchorGap - surfaceSize.width - metrics.shadowGutter,
                y: anchor.midY - surfaceSize.height / 2 - metrics.shadowGutter
            )
        case .minY:
            origin = NSPoint(
                x: anchor.midX - surfaceSize.width / 2 - metrics.shadowGutter,
                y: anchor.minY - metrics.anchorGap - surfaceSize.height - metrics.shadowGutter
            )
        default:
            origin = NSPoint(
                x: anchor.midX - surfaceSize.width / 2 - metrics.shadowGutter,
                y: anchor.maxY + metrics.anchorGap - metrics.shadowGutter
            )
        }

        let allowed = visibleFrame.insetBy(dx: metrics.screenInset, dy: metrics.screenInset)
        origin.x = min(max(origin.x, allowed.minX), max(allowed.minX, allowed.maxX - panelSize.width))
        origin.y = min(max(origin.y, allowed.minY), max(allowed.minY, allowed.maxY - panelSize.height))
        let panelFrame = NSRect(origin: origin, size: panelSize)

        let bodyFrame: NSRect
        switch edge {
        case .maxX:
            bodyFrame = NSRect(
                x: metrics.shadowGutter + metrics.arrowLength,
                y: metrics.shadowGutter,
                width: bodySize.width,
                height: bodySize.height
            )
        case .minX, .minY:
            bodyFrame = NSRect(
                x: metrics.shadowGutter,
                y: metrics.shadowGutter,
                width: bodySize.width,
                height: bodySize.height
            )
        default:
            bodyFrame = NSRect(
                x: metrics.shadowGutter,
                y: metrics.shadowGutter + metrics.arrowLength,
                width: bodySize.width,
                height: bodySize.height
            )
        }
        let contentFrame = bodyFrame.insetBy(
            dx: metrics.borderInset,
            dy: metrics.borderInset
        )

        let anchorLocal = NSPoint(x: anchor.midX - origin.x, y: anchor.midY - origin.y)
        let half = metrics.arrowBreadth / 2
        let arrowTip: NSPoint
        switch edge {
        case .maxX:
            let y = min(max(anchorLocal.y, bodyFrame.minY + half), bodyFrame.maxY - half)
            arrowTip = NSPoint(x: metrics.shadowGutter, y: y)
        case .minX:
            let y = min(max(anchorLocal.y, bodyFrame.minY + half), bodyFrame.maxY - half)
            arrowTip = NSPoint(x: panelSize.width - metrics.shadowGutter, y: y)
        case .minY:
            let x = min(max(anchorLocal.x, bodyFrame.minX + half), bodyFrame.maxX - half)
            arrowTip = NSPoint(x: x, y: panelSize.height - metrics.shadowGutter)
        default:
            let x = min(max(anchorLocal.x, bodyFrame.minX + half), bodyFrame.maxX - half)
            arrowTip = NSPoint(x: x, y: metrics.shadowGutter)
        }

        return Placement(
            edge: edge,
            panelFrame: panelFrame,
            bodyFrame: bodyFrame,
            contentFrame: contentFrame,
            arrowTip: arrowTip,
            classic: style.glyphStyle == .classic,
            arrowBreadth: metrics.arrowBreadth,
            style: style,
            hasMaterialShadow: metrics.shadowGutter > 0
        )
    }

    private struct Metrics {
        let arrowLength: CGFloat
        let arrowBreadth: CGFloat
        let anchorGap: CGFloat
        let screenInset: CGFloat
        let borderInset: CGFloat
        let shadowGutter: CGFloat

        @MainActor
        init(
            style: AppTheme.Material.PopoverStyle,
            hasMaterialShadow: Bool,
            bevelWidth: CGFloat?
        ) {
            let compact = style.density == .compact
            arrowLength = style.arrow == .triangle
                ? (compact ? compactArrowLength : ThemedPopoverLayout.arrowLength)
                : 0
            arrowBreadth = compact ? compactArrowBreadth : ThemedPopoverLayout.arrowBreadth
            anchorGap = compact ? compactAnchorGap : ThemedPopoverLayout.anchorGap
            screenInset = compact ? compactScreenInset : ThemedPopoverLayout.screenInset
            let baseInset = compact ? compactBorderInset : ThemedPopoverLayout.borderInset
            borderInset = style.edge == .material
                ? max(baseInset, bevelWidth ?? baseInset)
                : baseInset
            let materialDepth = style.shadow == .material
                || (style.shadow == .automatic && hasMaterialShadow)
            shadowGutter = materialDepth && hasMaterialShadow ? Design.Size.glowGutter : 0
        }
    }

    /// The popover's silhouette — body and arrow as **one closed path**, walked once around.
    ///
    /// The chrome used to fill and stroke the rounded body and the arrow triangle separately,
    /// then repaint the seam where the triangle's base lay inside the body. That repaint also
    /// erased the last half-point of the arrow's own stroked sides, which read as gaps in the
    /// border exactly where the arrow met the body. A single outline has no seam to repaint and
    /// its joins are drawn by the stroke itself.
    ///
    /// `strokeWidth` insets the path so a stroke centred on it lands fully inside the panel;
    /// the arrow's base corners are kept clear of the corner arcs.
    static func outline(
        for placement: Placement,
        cornerRadius: CGFloat,
        strokeWidth: CGFloat
    ) -> NSBezierPath {
        let inset = strokeWidth / 2
        let rect = placement.bodyFrame.insetBy(dx: inset, dy: inset)
        let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        let half = placement.arrowBreadth / 2

        // The tip sits on the panel's very edge; pulled in by the same half stroke as the body
        // so its point is not shaved flat by the panel bounds.
        var tip = placement.arrowTip
        switch placement.edge {
        case .maxX: tip.x += inset
        case .minX: tip.x -= inset
        case .minY: tip.y -= inset
        default: tip.y += inset
        }

        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + radius, y: rect.minY))

        // Bottom edge — carries the arrow when the popover sits above its anchor (.maxY).
        if placement.hasArrow, placement.edge == .maxY {
            path.line(to: NSPoint(x: max(tip.x - half, rect.minX + radius), y: rect.minY))
            path.line(to: tip)
            path.line(to: NSPoint(x: min(tip.x + half, rect.maxX - radius), y: rect.minY))
        }
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius, startAngle: 270, endAngle: 360
        )

        // Right edge — the arrow when the popover sits left of its anchor (.minX).
        if placement.hasArrow, placement.edge == .minX {
            path.line(to: NSPoint(x: rect.maxX, y: max(tip.y - half, rect.minY + radius)))
            path.line(to: tip)
            path.line(to: NSPoint(x: rect.maxX, y: min(tip.y + half, rect.maxY - radius)))
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius, startAngle: 0, endAngle: 90
        )

        // Top edge — the arrow when the popover sits below its anchor (.minY).
        if placement.hasArrow, placement.edge == .minY {
            path.line(to: NSPoint(x: min(tip.x + half, rect.maxX - radius), y: rect.maxY))
            path.line(to: tip)
            path.line(to: NSPoint(x: max(tip.x - half, rect.minX + radius), y: rect.maxY))
        }
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius, startAngle: 90, endAngle: 180
        )

        // Left edge — the arrow when the popover sits right of its anchor (.maxX).
        if placement.hasArrow, placement.edge == .maxX {
            path.line(to: NSPoint(x: rect.minX, y: min(tip.y + half, rect.maxY - radius)))
            path.line(to: tip)
            path.line(to: NSPoint(x: rect.minX, y: max(tip.y - half, rect.minY + radius)))
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius, startAngle: 180, endAngle: 270
        )
        path.close()
        return path
    }

    private static func supported(_ edge: NSRectEdge) -> Bool {
        edge == .minX || edge == .maxX || edge == .minY || edge == .maxY
    }

    private static func opposite(of edge: NSRectEdge) -> NSRectEdge {
        switch edge {
        case .minX: .maxX
        case .maxX: .minX
        case .minY: .maxY
        default: .minY
        }
    }

    private static func requiredSpace(
        for edge: NSRectEdge,
        contentSize: NSSize,
        metrics: Metrics
    ) -> CGFloat {
        let body = edge == .minX || edge == .maxX ? contentSize.width : contentSize.height
        return body
            + 2 * metrics.borderInset
            + metrics.arrowLength
            + metrics.anchorGap
            + metrics.shadowGutter
            + metrics.screenInset
    }

    private static func availableSpace(for edge: NSRectEdge, anchor: NSRect, screen: NSRect) -> CGFloat {
        switch edge {
        case .minX: anchor.minX - screen.minX
        case .maxX: screen.maxX - anchor.maxX
        case .minY: anchor.minY - screen.minY
        default: screen.maxY - anchor.maxY
        }
    }
}

// MARK: - Window and chrome

@MainActor
private final class ThemedPopoverPanel: NSPanel {
    let chromeView = ThemedPopoverChromeView()
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        contentView = chromeView
        setAccessibilitySubrole(.floatingWindow)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func apply(
        style: AppTheme.Material.PopoverStyle,
        hasMaterialShadow: Bool
    ) {
        switch style.shadow {
        case .system:
            hasShadow = true
        case .automatic:
            hasShadow = !hasMaterialShadow
        case .material, .none:
            hasShadow = false
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "\u{1b}" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class ThemedPopoverHostController: NSViewController {
    private let chrome: ThemedPopoverChromeView
    private let child: NSViewController

    init(chrome: ThemedPopoverChromeView, content: NSViewController) {
        self.chrome = chrome
        child = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = chrome
        addChild(child)
        chrome.contentView = child.view
    }
}

/// Internal rather than private for the same reason `ThemedPopoverLayout` is: the border's
/// continuity around the arrow is asserted on drawn pixels in `ThemedPresentationTests`.
@MainActor
final class ThemedPopoverChromeView: NSView, ThemedComponent {
    var onStyleChange: (() -> Void)?
    var placement: ThemedPopoverLayout.Placement? {
        didSet { needsLayout = true; needsDisplay = true }
    }
    weak var contentView: NSView? {
        didSet {
            guard contentView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let contentView { addSubview(contentView) }
            needsLayout = true
        }
    }

    private let appEvents = AppEventObservations()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.needsDisplay = true
            self?.window?.invalidateShadow()
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Popover"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { false }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        guard let placement, let contentView else { return }
        contentView.frame = placement.contentFrame
        contentView.layoutSubtreeIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        window?.invalidateShadow()
        onStyleChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let placement else { return }
        let style = placement.style
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        let fill = AppThemePalette.color(style.surfaceRole)
        let materialEdge = style.edge == .material
            && material.bevel != nil
            && !placement.hasArrow
        let width: CGFloat = style.edge == .none || materialEdge ? 0 : Design.Radius.border
        let radius = style.cornerRadius ?? Design.Radius.panel
        let outline = ThemedPopoverLayout.outline(
            for: placement,
            cornerRadius: radius,
            strokeWidth: width
        )
        applyMaterialShadow(material.glow, to: outline, enabled: placement.hasMaterialShadow)

        if materialEdge {
            // A bevel is one edge around one rectilinear/rounded silhouette. Themes choosing it
            // also choose a stemless popover (held by validation), so the ordinary shared
            // surface interpreter can draw the exact same hard or soft construction as panels.
            ThemedSurface.draw(
                placement.bodyFrame,
                fill: fill,
                radius: radius
            )
            return
        }

        // One silhouette, filled once and stroked once — see `ThemedPopoverLayout.outline`.
        fill.setFill()
        outline.fill()
        if style.edge != .none {
            Design.Surface.border.setStroke()
            outline.lineWidth = width
            outline.stroke()
        }
    }

    private func applyMaterialShadow(
        _ glow: AppTheme.Glow?,
        to outline: NSBezierPath,
        enabled: Bool
    ) {
        let highlightName = "threading.popoverGlow.highlight"
        let existingHighlight = layer?.sublayers?.first { $0.name == highlightName }
        guard enabled, let glow, let layer else {
            layer?.shadowOpacity = 0
            layer?.shadowPath = nil
            existingHighlight?.removeFromSuperlayer()
            return
        }

        layer.masksToBounds = false
        applyLayerShadow(AppThemePalette.current.resolved(glow.role))
        layer.shadowRadius = glow.radius
        layer.shadowOpacity = Float(glow.opacity)
        layer.shadowOffset = CGSize(width: glow.offsetX, height: glow.offsetY)
        layer.shadowPath = outline.threadingCGPath

        guard let highlight = glow.highlight else {
            existingHighlight?.removeFromSuperlayer()
            return
        }
        let highlightLayer = existingHighlight ?? CALayer()
        highlightLayer.name = highlightName
        highlightLayer.frame = layer.bounds
        highlightLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        applyLayerShadow(AppThemePalette.current.resolved(highlight.role), to: highlightLayer)
        highlightLayer.shadowRadius = highlight.radius
        highlightLayer.shadowOpacity = Float(highlight.opacity)
        highlightLayer.shadowOffset = CGSize(width: highlight.offsetX, height: highlight.offsetY)
        highlightLayer.shadowPath = outline.threadingCGPath
        if existingHighlight == nil {
            layer.insertSublayer(highlightLayer, at: 0)
        }
    }
}

/// `NSBezierPath.cgPath` starts at macOS 14, while Threading still supports macOS 13. Keep the
/// presentation path identical on both rather than dropping the material shadow on Ventura.
private extension NSBezierPath {
    var threadingCGPath: CGPath {
        let result = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            let element = points.withUnsafeMutableBufferPointer { buffer in
                self.element(at: index, associatedPoints: buffer.baseAddress!)
            }
            switch element {
            case .moveTo:
                result.move(to: points[0])
            case .lineTo:
                result.addLine(to: points[0])
            case .curveTo:
                result.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo:
                result.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                result.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                result.closeSubpath()
            @unknown default:
                break
            }
        }
        return result
    }
}

private extension NSResponder {
    @MainActor
    func isDescendantResponder(of window: NSWindow) -> Bool {
        if self === window { return true }
        guard let view = self as? NSView else { return false }
        return view.window === window
    }
}
