#if os(Linux)
import AppKit

/// The Linux table shim already leaves its surface transparent and delegates visible rows to
/// the supplied Design components. Match the shared table factory's themed construction name.
@MainActor
final class ThemedTableView: NSTableView {
    var onCopy: (() -> Void)?
    var canCopy: (() -> Bool)?
    var onSelectAll: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        if command, event.charactersIgnoringModifiers == "c", canCopy?() == true {
            onCopy?()
            return
        }
        if command, event.charactersIgnoringModifiers == "a", onSelectAll?() == true {
            return
        }
        super.keyDown(with: event)
    }
}
#endif
