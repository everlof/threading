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

    private var panel: ThemedPopoverPanel?
    private weak var anchorView: NSView?
    private var anchorRect: NSRect = .zero
    private var preferredEdge: NSRectEdge = .maxY
    private weak var presentingWindow: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var observations: [NSObjectProtocol] = []
    private var preferredSizeObservation: NSKeyValueObservation?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        guard let parent = positioningView.window, let controller = contentViewController else { return }
        if isShown { close() }

        self.anchorView = positioningView
        self.anchorRect = positioningRect
        self.preferredEdge = preferredEdge
        presentingWindow = parent
        previousFirstResponder = parent.firstResponder

        let panel = ThemedPopoverPanel()
        panel.onCancel = { [weak self] in self?.close() }
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

    func close() {
        guard isShown || panel != nil else { return }
        isShown = false
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
        let placement = ThemedPopoverLayout.place(
            anchor: screenAnchor,
            contentSize: contentSize,
            visibleFrame: screen.visibleFrame,
            preferredEdge: preferredEdge
        )

        panel.setFrame(placement.panelFrame, display: panel.isVisible)
        panel.chromeView.placement = placement
        panel.chromeView.contentView = controller.view
        panel.invalidateShadow()
    }

    private func installObservation() {
        guard let window = presentingWindow else { return }
        let center = NotificationCenter.default
        let repositionNames: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification
        ]
        observations = repositionNames.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            }
        }
        observations.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        observations.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.behavior != .applicationDefined else { return }
                self?.close()
            }
        })
    }

    private func removeObservation() {
        let center = NotificationCenter.default
        observations.forEach(center.removeObserver)
        observations.removeAll()
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.isShown else { return event }
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
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        observations.forEach(NotificationCenter.default.removeObserver)
    }
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

    struct Placement: Equatable {
        let edge: NSRectEdge
        let panelFrame: NSRect
        let bodyFrame: NSRect
        let contentFrame: NSRect
        let arrowTip: NSPoint
        let arrowBaseA: NSPoint
        let arrowBaseB: NSPoint
    }

    static func place(
        anchor: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect,
        preferredEdge: NSRectEdge
    ) -> Placement {
        let preferred = supported(preferredEdge) ? preferredEdge : .maxY
        let opposite = opposite(of: preferred)
        let needed = requiredSpace(for: preferred, contentSize: contentSize)
        let preferredSpace = availableSpace(for: preferred, anchor: anchor, screen: visibleFrame)
        let oppositeSpace = availableSpace(for: opposite, anchor: anchor, screen: visibleFrame)
        let edge = preferredSpace >= needed || preferredSpace >= oppositeSpace ? preferred : opposite

        let bodySize = NSSize(
            width: contentSize.width + 2 * borderInset,
            height: contentSize.height + 2 * borderInset
        )
        let panelSize: NSSize
        if edge == .minX || edge == .maxX {
            panelSize = NSSize(width: bodySize.width + arrowLength, height: bodySize.height)
        } else {
            panelSize = NSSize(width: bodySize.width, height: bodySize.height + arrowLength)
        }

        var origin: NSPoint
        switch edge {
        case .maxX:
            origin = NSPoint(x: anchor.maxX + anchorGap, y: anchor.midY - panelSize.height / 2)
        case .minX:
            origin = NSPoint(x: anchor.minX - anchorGap - panelSize.width, y: anchor.midY - panelSize.height / 2)
        case .minY:
            origin = NSPoint(x: anchor.midX - panelSize.width / 2, y: anchor.minY - anchorGap - panelSize.height)
        default:
            origin = NSPoint(x: anchor.midX - panelSize.width / 2, y: anchor.maxY + anchorGap)
        }

        let allowed = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        origin.x = min(max(origin.x, allowed.minX), max(allowed.minX, allowed.maxX - panelSize.width))
        origin.y = min(max(origin.y, allowed.minY), max(allowed.minY, allowed.maxY - panelSize.height))
        let panelFrame = NSRect(origin: origin, size: panelSize)

        let bodyFrame: NSRect
        switch edge {
        case .maxX:
            bodyFrame = NSRect(x: arrowLength, y: 0, width: bodySize.width, height: bodySize.height)
        case .minX:
            bodyFrame = NSRect(x: 0, y: 0, width: bodySize.width, height: bodySize.height)
        case .minY:
            bodyFrame = NSRect(x: 0, y: 0, width: bodySize.width, height: bodySize.height)
        default:
            bodyFrame = NSRect(x: 0, y: arrowLength, width: bodySize.width, height: bodySize.height)
        }
        let contentFrame = bodyFrame.insetBy(dx: borderInset, dy: borderInset)

        let anchorLocal = NSPoint(x: anchor.midX - origin.x, y: anchor.midY - origin.y)
        let half = arrowBreadth / 2
        let arrowTip: NSPoint
        let a: NSPoint
        let b: NSPoint
        switch edge {
        case .maxX:
            let y = min(max(anchorLocal.y, bodyFrame.minY + half), bodyFrame.maxY - half)
            arrowTip = NSPoint(x: 0, y: y)
            a = NSPoint(x: bodyFrame.minX + borderInset, y: y - half)
            b = NSPoint(x: bodyFrame.minX + borderInset, y: y + half)
        case .minX:
            let y = min(max(anchorLocal.y, bodyFrame.minY + half), bodyFrame.maxY - half)
            arrowTip = NSPoint(x: panelSize.width, y: y)
            a = NSPoint(x: bodyFrame.maxX - borderInset, y: y + half)
            b = NSPoint(x: bodyFrame.maxX - borderInset, y: y - half)
        case .minY:
            let x = min(max(anchorLocal.x, bodyFrame.minX + half), bodyFrame.maxX - half)
            arrowTip = NSPoint(x: x, y: panelSize.height)
            a = NSPoint(x: x - half, y: bodyFrame.maxY - borderInset)
            b = NSPoint(x: x + half, y: bodyFrame.maxY - borderInset)
        default:
            let x = min(max(anchorLocal.x, bodyFrame.minX + half), bodyFrame.maxX - half)
            arrowTip = NSPoint(x: x, y: 0)
            a = NSPoint(x: x + half, y: bodyFrame.minY + borderInset)
            b = NSPoint(x: x - half, y: bodyFrame.minY + borderInset)
        }

        return Placement(
            edge: edge,
            panelFrame: panelFrame,
            bodyFrame: bodyFrame,
            contentFrame: contentFrame,
            arrowTip: arrowTip,
            arrowBaseA: a,
            arrowBaseB: b
        )
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

    private static func requiredSpace(for edge: NSRectEdge, contentSize: NSSize) -> CGFloat {
        let body = edge == .minX || edge == .maxX ? contentSize.width : contentSize.height
        return body + 2 * borderInset + arrowLength + anchorGap + screenInset
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

@MainActor
private final class ThemedPopoverChromeView: NSView, ThemedComponent {
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
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let placement else { return }
        let body = NSBezierPath(
            roundedRect: placement.bodyFrame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Design.Radius.panel,
            yRadius: Design.Radius.panel
        )
        let arrow = NSBezierPath()
        arrow.move(to: placement.arrowTip)
        arrow.line(to: placement.arrowBaseA)
        arrow.line(to: placement.arrowBaseB)
        arrow.close()

        Design.Surface.elevated.setFill()
        body.fill()
        arrow.fill()

        Design.Surface.border.setStroke()
        body.lineWidth = Design.Radius.border
        body.stroke()
        arrow.lineWidth = Design.Radius.border
        arrow.stroke()

        // The triangle's base lies inside the body. Repainting that seam produces one continuous
        // surface rather than a border line cutting through the arrow.
        let seam = NSBezierPath()
        seam.move(to: placement.arrowBaseA)
        seam.line(to: placement.arrowBaseB)
        Design.Surface.elevated.setStroke()
        seam.lineWidth = max(2, Design.Radius.border + 1)
        seam.stroke()
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
