import AppKit

/// Temporarily gives an existing rendering view a visible WindowServer host without presenting
/// UI. The owning surface stays in its original window, including its dialogs and focus route.
/// This is AppKit transport, not a user-facing window: it has no chrome, input or accessibility.
@MainActor
final class BackgroundRenderingHost: NSObject {
    private let content: NSView
    private weak var originalSuperview: NSView?
    private var originalFrame: CGRect
    private var isHosted = false
    private var isUpdating = false

    var isRenderingInBackground: Bool { isHosted }

    // All concurrent operations share one transport and reuse their existing content views.
    // No window, observer or render activity is retained for idle sessions.
    private static var panel: RenderPanel?

    init(content: NSView) {
        self.content = content
        originalSuperview = content.superview
        originalFrame = content.frame
        super.init()
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSApplication.didChangeScreenParametersNotification
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(presentationChanged(_:)), name: name, object: nil
            )
        }
        update()
    }

    func setFrame(_ frame: CGRect) {
        originalFrame = frame
        content.frame = isHosted ? CGRect(origin: .zero, size: frame.size) : frame
        update()
    }

    /// Called by the owning surface when its view hierarchy changes, even without a window.
    func update() {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        guard let originalSuperview else {
            restore()
            return
        }
        let window = originalSuperview.window
        let canRenderInPlace = !originalSuperview.isHiddenOrHasHiddenAncestor
            && window?.isVisible == true
            && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
            && NSScreen.screens.contains { $0.frame.intersects(window?.frame ?? .zero) }
        if canRenderInPlace || content.isHidden {
            restore()
            return
        }
        // Another owner may retire a page during navigation/profile replacement. Never pull a
        // removed or reparented view back into an operation that still references its old page.
        guard isHosted || content.superview === originalSuperview else { return }
        let panel = Self.panel ?? Self.makePanel(size: originalFrame.size)
        Self.panel = panel
        if !isHosted {
            originalFrame = content.frame
            content.removeFromSuperview()
            panel.contentView?.addSubview(content)
            content.frame = CGRect(origin: .zero, size: originalFrame.size)
            isHosted = true
        }
        let size = panel.contentView?.bounds.size ?? .zero
        panel.setContentSize(CGSize(
            width: max(size.width, originalFrame.width),
            height: max(size.height, originalFrame.height)
        ))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func restore() {
        guard isHosted else { return }
        isHosted = false
        if content.superview === Self.panel?.contentView {
            content.removeFromSuperview()
            content.frame = originalFrame
            // Browser overlays must remain above the restored page.
            originalSuperview?.addSubview(content, positioned: .below, relativeTo: nil)
        }
        if Self.panel?.contentView?.subviews.isEmpty == true {
            Self.panel?.orderOut(nil)
            Self.panel = nil
        }
    }

    @objc private func presentationChanged(_ notification: Notification) {
        if notification.name == NSApplication.didChangeScreenParametersNotification {
            if let screen = NSScreen.main { Self.panel?.setFrameOrigin(screen.visibleFrame.origin) }
            update()
        } else if let window = notification.object as? NSWindow,
                  window === originalSuperview?.window {
            update()
        }
    }

    private static func makePanel(size: CGSize) -> RenderPanel {
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let panel = RenderPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isExcludedFromWindowsMenu = true
        panel.isRestorable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityElement(false)
        panel.contentView = RenderContainer(frame: CGRect(origin: .zero, size: size))
        return panel
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        restore()
    }
}

private final class RenderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // A non-key window can still assign a first responder. WebKit treats that assignment on
    // reattachment as focus traversal to the first form field, overwriting document.activeElement.
    // DOM focus stays page-owned; this transport never takes native keyboard focus.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSView { return false }
        return super.makeFirstResponder(responder)
    }
}

private final class RenderContainer: NSView {
    override var isFlipped: Bool { true }
    override func accessibilityChildren() -> [Any]? { [] }
}
