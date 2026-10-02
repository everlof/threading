import Foundation

/// Content ownership and view attachment for the bounded Linux raster tree. Native window
/// operations still belong to the SDL host; this object gives AppKit views a real attach/detach
/// lifecycle and first-responder ownership. Title bars and window ordering remain native-host work.
@MainActor
public final class NSWindow: NSResponder {
    private struct CursorRect {
        let rect: NSRect
        let cursor: NSCursor
    }
    private final class CursorRegistration {
        weak var view: NSView?
        var rects: [CursorRect] = []
        init(view: NSView) { self.view = view }
    }

    private var root: NSView?
    private weak var focusedResponder: NSResponder?
    /// The down-hit view owns the rest of its pointer gesture, even when the pointer leaves
    /// its bounds. Keep this weak so rebuilding a sidebar row cannot retain an obsolete view;
    /// an application-scope release monitor may still finish that detached control's action.
    private weak var pressedView: NSView?
    // Pointer motion is frequent. The diagnostic native host mounts at most 32 visible rows
    // (normally eight at 480px), with at most three text/control fragments each. A future
    // 32-row/96-claim stress viewport stays O(attached visible views), not all saved sessions;
    // detached registrations are dropped when the tree moves or the pointer is resolved.
    private var cursorRegistrations: [ObjectIdentifier: CursorRegistration] = [:]
    private var pointerLocation: NSPoint = .zero
    public var firstResponder: NSResponder? { focusedResponder ?? self }
    public var isKeyWindow = true
    public var screenOrigin: NSPoint = .zero
    public var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
    /// The raster host chooses this from its drawable scale. It is fixed for the lifetime of
    /// this bounded content owner; display migration still belongs to the native window host.
    public let backingScaleFactor: CGFloat

    public init(backingScaleFactor: CGFloat = 1) {
        precondition(backingScaleFactor.isFinite && backingScaleFactor > 0)
        self.backingScaleFactor = backingScaleFactor
        super.init()
    }

    /// A direct focus request does not consult `acceptsFirstResponder`; AppKit uses that
    /// property while choosing a responder during traversal. A detached view (or a responder
    /// that declines `becomeFirstResponder`) leaves the window itself as first responder.
    @discardableResult
    public func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let candidate: NSResponder
        if let view = responder as? NSView {
            candidate = view.window === self ? view : self
        } else {
            candidate = self
        }
        let old = firstResponder ?? self
        if old === candidate { return true }
        guard old.resignFirstResponder() else { return false }
        if candidate === self || candidate.becomeFirstResponder() {
            focusedResponder = candidate === self ? nil : candidate
        } else {
            focusedResponder = nil
        }
        return true
    }

    /// AppKit clears focus when its view leaves the window, without a resign callback. Keep
    /// same-window reparenting focused; only the move's source window calls this method.
    func focusDidLeave(_ subtree: NSView) {
        if let view = focusedResponder as? NSView, view.isDescendant(of: subtree) {
            focusedResponder = nil
        }
        if let pressedView, pressedView.isDescendant(of: subtree) {
            self.pressedView = nil
        }
    }

    public var contentView: NSView? {
        get { root }
        set {
            guard root !== newValue else { return }

            if let oldRoot = root {
                oldRoot.notifyWillMove(toWindow: nil)
                focusDidLeave(oldRoot)
                discardCursorRects(in: oldRoot)
                oldRoot.contentWindow = nil
                root = nil
                oldRoot.notifyDidMoveToWindow()
            }

            guard let newValue else { return }
            let previousAppearance = newValue.effectiveAppearance.name
            newValue.notifyWillMove(toWindow: self)
            newValue.detachFromSuperview(notifyAppearance: false, notifyWindow: false)
            if let previousWindow = newValue.contentWindow {
                previousWindow.detachContentRootWithoutNotification(newValue)
            }
            newValue.contentWindow = self
            root = newValue
            newValue.notifyEffectiveAppearanceChanged(from: previousAppearance)
            newValue.notifyDidMoveToWindow()
        }
    }

    func detachContentRootWithoutNotification(_ view: NSView) {
        if root === view {
            focusDidLeave(view)
            discardCursorRects(in: view)
            root = nil
        }
    }

    public func layoutIfNeeded() { root?.layoutSubtreeIfNeeded() }

    public func convertPoint(toScreen point: NSPoint) -> NSPoint {
        NSPoint(x: point.x + screenOrigin.x, y: point.y + screenOrigin.y)
    }

    public func convertPoint(fromScreen point: NSPoint) -> NSPoint {
        NSPoint(x: point.x - screenOrigin.x, y: point.y - screenOrigin.y)
    }

    public func convertToScreen(_ rect: NSRect) -> NSRect {
        NSRect(origin: convertPoint(toScreen: rect.origin), size: rect.size)
    }

    /// Called before native delivery. The returned event has passed all installed local monitors;
    /// nil means a monitor consumed it. Tracking uses the physical pointer even when consumed.
    public func dispatch(_ event: NSEvent) -> NSEvent? {
        event.attach(to: self)
        if event.type.carriesPointer {
            pointerLocation = event.locationInWindow
            root?.pointerMoved(toWindowPoint: pointerLocation, event: event)
            cursor(atWindowPoint: pointerLocation).set()
        }
        return NSEvent.dispatchLocalMonitors(event)
    }

    /// Deliver a native host event through tracking, local monitors and the retained content
    /// tree. The down-hit view receives drag/up while attached, even outside its frame. A
    /// detached control's application-scope monitor still sees the release in `dispatch(_:)`.
    /// Returning the down-hit view lets a host keep its own row selection policy.
    @discardableResult
    public func dispatchToContent(_ event: NSEvent) -> NSView? {
        if event.type == .leftMouseDown { pressedView = nil }
        let delivered = dispatch(event)
        defer {
            if event.type == .leftMouseUp { pressedView = nil }
        }
        guard let delivered else { return nil }
        switch delivered.type {
        case .leftMouseDown:
            let target = pointerTarget(at: delivered.locationInWindow)
            pressedView = target
            target?.mouseDown(with: delivered)
            return target
        case .leftMouseDragged:
            if let pressedView, pressedView.window === self {
                pressedView.mouseDragged(with: delivered)
            }
        case .leftMouseUp:
            if let pressedView, pressedView.window === self {
                pressedView.mouseUp(with: delivered)
            }
        case .rightMouseDown:
            pointerTarget(at: delivered.locationInWindow)?.rightMouseDown(with: delivered)
        case .keyDown:
            // AppKit offers a key equivalent to the visible content tree before ordinary
            // first-responder delivery. A sheet's default/cancel button may answer while a
            // text field owns focus; a consumed key must not also reach that field.
            if root?.performKeyEquivalent(with: delivered) != true {
                (firstResponder ?? self).keyDown(with: delivered)
            }
        case .mouseMoved:
            break
        }
        return nil
    }

    /// Native focus loss ends an in-flight pointer gesture without performing its action.
    /// A synthetic off-content down tells application-scope release monitors that the old
    /// press was superseded, then leaves tracking and cursor state outside the content tree.
    public func cancelPointerGesture() {
        pressedView = nil
        _ = dispatch(NSEvent(type: .leftMouseDown, window: self,
                             locationInWindow: NSPoint(x: -1, y: -1)))
    }

    /// A decorative glyph inside a control is part of that control's hit target. Dispatching
    /// to the glyph would bubble down but strand drag/up and secondary click on the glyph.
    private func pointerTarget(at point: NSPoint) -> NSView? {
        guard let hit = root?.hitTest(point) else { return nil }
        var ancestor: NSView? = hit
        while let view = ancestor {
            if view is NSControl { return view }
            ancestor = view.superview
        }
        return hit
    }

    public func registerCursorRect(_ rect: NSRect, cursor: NSCursor, for view: NSView) {
        guard view.window === self, !rect.isEmpty else { return }
        let key = ObjectIdentifier(view)
        let registration = cursorRegistrations[key] ?? CursorRegistration(view: view)
        registration.rects.append(CursorRect(rect: rect, cursor: cursor))
        cursorRegistrations[key] = registration
    }

    public func invalidateCursorRects(for view: NSView) {
        cursorRegistrations.removeValue(forKey: ObjectIdentifier(view))
        guard view.window === self else { return }
        view.resetCursorRects()
    }

    public func discardCursorRects(for view: NSView) {
        cursorRegistrations.removeValue(forKey: ObjectIdentifier(view))
    }

    private func discardCursorRects(in view: NSView) {
        discardCursorRects(for: view)
        for child in view.subviews { discardCursorRects(in: child) }
    }

    /// Resolve frontmost child first, then its parent, then lower siblings. A transparent view
    /// with no claim lets a lower visible view answer, matching `PointerClaiming`'s contract.
    @discardableResult
    public func cursor(atWindowPoint point: NSPoint) -> NSCursor {
        cursorRegistrations = cursorRegistrations.filter { $0.value.view?.window === self }
        func resolve(_ view: NSView) -> NSCursor? {
            guard !view.isHidden else { return nil }
            let local = view.convert(point, from: nil)
            guard view.bounds.contains(local) else { return nil }
            for child in view.subviews.reversed() {
                if let cursor = resolve(child) { return cursor }
            }
            guard let registration = cursorRegistrations[ObjectIdentifier(view)] else { return nil }
            return registration.rects.reversed().first { $0.rect.contains(local) }?.cursor
        }
        return root.flatMap(resolve) ?? .arrow
    }
}
