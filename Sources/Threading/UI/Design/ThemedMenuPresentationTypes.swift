import AppKit

/// Where an open menu hangs from.
///
/// A dropdown belongs to the control that opened it and lines up under that control's edge. A
/// menu opened by a secondary click belongs to the pointer, at the exact point of the click.
public enum ThemedMenuAnchor {
    /// Under or over the opening control, aligned to its leading edge.
    case control
    /// A point in window coordinates, for a secondary click.
    case pointer(NSPoint)
}

/// A view whose presentation changes while a menu opened from it is on screen.
///
/// The presenter reports both opening and dismissal so the source can carry its held state
/// even though the menu itself lives in a window overlay.
@MainActor
public protocol ThemedMenuPresentationObserving: NSView {
    func themedMenuPresentationDidChange(isPresented: Bool)
}
