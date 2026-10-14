import Foundation

/// Lets a recognizer's owner decline a gesture before it starts, as AppKit's delegate does.
@MainActor
public protocol NSGestureRecognizerDelegate: AnyObject {
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool
}

public extension NSGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool { true }
}

/// The part of AppKit's recognizer contract the shim's views use. Delivery is driven by the
/// window: a press offers itself to the recognizers of the view it hit and that view's
/// ancestors, and the press still reaches the view, so a label inside can select text.
@MainActor
open class NSGestureRecognizer {
    public enum State: Sendable { case possible, began, changed, ended, cancelled, failed }

    public internal(set) weak var view: NSView?
    open weak var target: AnyObject?
    /// On Linux a `Selector` is the closure itself.
    open var action: Selector?
    open weak var delegate: NSGestureRecognizerDelegate?
    open var isEnabled = true
    public internal(set) var state = State.possible

    public init(target: AnyObject?, action: Selector?) {
        self.target = target
        self.action = action
    }

    /// Whether this recognizer takes part in the press `event` starts.
    func accepts(_ event: NSEvent) -> Bool {
        isEnabled && view?.window != nil && delegate?.gestureRecognizer(self, shouldAttemptToRecognizeWith: event) != false
    }

    func pressBegan(_ event: NSEvent) {}
    func pressMoved(_ event: NSEvent) {}
    func pressEnded(_ event: NSEvent) {}
}

/// One primary-button click: the press and its release within the view, with the pointer
/// staying close to where it went down.
@MainActor
open class NSClickGestureRecognizer: NSGestureRecognizer {
    /// AppKit's drag hysteresis: a press that travels further is a drag, not a click.
    static let movementTolerance: CGFloat = 4
    open var numberOfClicksRequired = 1 {
        didSet { precondition(numberOfClicksRequired == 1, "Linux recognizes single clicks only") }
    }
    private var origin: NSPoint?

    override func pressBegan(_ event: NSEvent) {
        origin = event.locationInWindow
        state = .possible
    }

    override func pressMoved(_ event: NSEvent) {
        guard let origin else { return }
        if hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y)
            > Self.movementTolerance {
            self.origin = nil
            state = .failed
        }
    }

    override func pressEnded(_ event: NSEvent) {
        defer { origin = nil }
        guard origin != nil, let view, view.window != nil,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else {
            state = .failed
            return
        }
        state = .ended
        action?()
        state = .possible
    }
}
