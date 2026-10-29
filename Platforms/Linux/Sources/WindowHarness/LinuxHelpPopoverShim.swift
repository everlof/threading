#if os(Linux)
import AppKit

/// The shared HelpPopoverButton supplies its view and content. The SDL host supplies the
/// window-level presentation that AppKit's NSPanel gives the Mac implementation.
@MainActor
final class ThemedPopover {
    enum Behavior { case applicationDefined, transient, semitransient }

    static var presentationProvider: ((ThemedPopover, NSRect, NSView, NSRectEdge) -> Bool)?

    var behavior: Behavior = .applicationDefined
    var contentViewController: NSViewController?
    var initialFirstResponder: NSResponder?
    var onClose: (() -> Void)?
    var hostDismiss: (() -> Void)?
    var hostReposition: (() -> Void)?
    private(set) var isShown = false

    func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        guard !isShown else { return }
        isShown = Self.presentationProvider?(self, rect, view, preferredEdge) ?? false
    }

    func reposition() { hostReposition?() }

    func close() {
        guard isShown else { return }
        isShown = false
        hostDismiss?()
        hostDismiss = nil
        hostReposition = nil
        onClose?()
    }
}

/// Placement and focus are the host seam; the button, explanatory text and panel body come
/// from the unchanged shared HelpPopoverButton source.
@MainActor
final class LinuxHelpPopoverSession {
    let popover: ThemedPopover
    private weak var source: NSView?
    private weak var root: NSView?
    private weak var owner: NSWindow?
    private let surface: NSView

    init?(popover: ThemedPopover, source: NSView, root: NSView, owner: NSWindow) {
        guard let content = popover.contentViewController?.view else { return nil }
        self.popover = popover
        self.source = source
        self.root = root
        self.owner = owner
        surface = HelpPopoverPanelStructure.make(content: content)
        root.addSubview(surface)
        reposition()
        _ = owner.makeFirstResponder(popover.initialFirstResponder ?? content)
        popover.hostDismiss = { [weak self] in self?.dismiss() }
        popover.hostReposition = { [weak self] in self?.reposition() }
    }

    var frame: NSRect { surface.frame }

    func reposition() {
        guard let source, let root, source.window === owner else {
            popover.close()
            return
        }
        let anchor = source.convert(source.bounds, to: root)
        let size = surface.fittingSize
        let padding = Design.Spacing.small
        let below = root.isFlipped ? root.bounds.maxY - anchor.maxY
                                   : anchor.minY - root.bounds.minY
        let above = root.isFlipped ? anchor.minY - root.bounds.minY
                                   : root.bounds.maxY - anchor.maxY
        let placeAbove = below < size.height + padding && above > below
        let proposedY: CGFloat
        if root.isFlipped {
            proposedY = placeAbove ? anchor.minY - size.height - padding : anchor.maxY + padding
        } else {
            proposedY = placeAbove ? anchor.maxY + padding : anchor.minY - size.height - padding
        }
        let x = min(max(anchor.midX - Design.Spacing.inset, root.bounds.minX),
                    root.bounds.maxX - size.width)
        let y = min(max(proposedY, root.bounds.minY), root.bounds.maxY - size.height)
        surface.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func dismiss() {
        surface.removeFromSuperview()
        if let source { _ = owner?.makeFirstResponder(source) }
    }
}

@MainActor
enum HostPopoverFactory {
    enum ID { case designHelp }
    static func make(_ id: ID) -> ThemedPopover { ThemedPopover() }
}
#endif
