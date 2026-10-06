import AppKit

extension NSView {
    /// The same ancestor walk as AppThemeRefresh, over the fills retained by the shim. The
    /// application owns composition and fallback; the shim only reports what it draws.
    func resolvedGround() -> NSColor {
        var fills: [NSColor] = []
        var node: NSView? = self
        while let current = node {
            if let fill = current.recordedSurfaceFill,
               let resolved = fill.usingColorSpace(.sRGB), resolved.alphaComponent > 0 {
                fills.append(resolved)
                if resolved.alphaComponent >= 1 { break }
            }
            node = current.superview
        }
        let backdrop = window?.backgroundColor ?? Design.Surface.ground
        return fills.reversed().reduce(backdrop) { ground, fill in fill.composited(over: ground) }
    }
}

extension ThemedMenuPresenter {
    typealias AnchoredPresentationProvider = (ThemedMenuPresentation, NSView, ThemedMenuAnchor,
        Int?, @escaping (Int, ThemedMenuItem) -> Void, @escaping () -> Void) -> AnyObject?
    static var anchoredPresentationProvider: AnchoredPresentationProvider?

    static func present(_ presentation: ThemedMenuPresentation, from source: NSView,
                        anchor: ThemedMenuAnchor, selectedEntryIndex: Int?,
                        onChoose: @escaping (Int, ThemedMenuItem) -> Void,
                        onDismiss: @escaping () -> Void) -> AnyObject? {
        anchoredPresentationProvider?(presentation, source, anchor, selectedEntryIndex, onChoose, onDismiss)
    }
}
