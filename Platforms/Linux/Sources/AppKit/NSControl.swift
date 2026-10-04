import Foundation

/// Linux actions are closures until the host has an Objective-C selector dispatcher.
/// Keeping the AppKit spelling lets unchanged controls snapshot their action at mouse-down.
public typealias Selector = () -> Void

/// The retained, cell-free part of AppKit's control contract. Linux controls can use a closure
/// action until Objective-C selectors have a host dispatch service; the same action is reached
/// by a themed control's keyboard and accessibility activation.
@MainActor
open class NSControl: NSView {
    open var font: NSFont?
    open var isEnabled = true {
        didSet { if isEnabled != oldValue { needsDisplay = true } }
    }

    /// A Linux action is explicitly callable, so it cannot silently disappear behind an
    /// Objective-C selector that this platform cannot invoke.
    open var action: Selector?
    open weak var target: AnyObject?

    @discardableResult
    open func sendAction(_ action: Selector?, to target: AnyObject?) -> Bool {
        guard isEnabled, let action else { return false }
        action()
        return true
    }
}
