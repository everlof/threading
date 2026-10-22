import AppKit

/// The visible session-row subtree shared by the Mac table cell and Linux outline cell.
/// The cell still owns identity, selection, hover and extension content, while this assembly
/// owns the default content stack, trailing controls and their relationship to the cell.
@MainActor
final class SidebarSessionRowAssembly {
    struct Mount {
        let leading: NSLayoutConstraint
        let trailing: NSLayoutConstraint
        let slotWidth: NSLayoutConstraint
    }

    let visuals = ThemedSessionRowContentView()
    let trailingSlot = SidebarSessionTrailingSlot()
    let contentStack: NSStackView

    init() {
        contentStack = NSStackView(views: [visuals])
        SidebarRowDefaults.configureSessionContentStack(contentStack)
        contentStack.setAccessibilityIdentifier("sidebar.session.content-stack")
    }

    func mount(in row: NSView, leadingInset: CGFloat, trailingInset: CGFloat) -> Mount {
        row.addSubview(contentStack)
        row.addSubview(trailingSlot)

        let edges = SidebarRowDefaults.constrainContent(
            contentStack, trailingSlot: trailingSlot, in: row,
            leadingInset: leadingInset, trailingInset: trailingInset)
        let width = trailingSlot.widthAnchor.constraint(
            equalToConstant: SidebarRowDefaults.trailingSlotSize)
        NSLayoutConstraint.activate([
            width,
            trailingSlot.heightAnchor.constraint(
                equalToConstant: SidebarRowDefaults.trailingSlotSize)
        ])
        return Mount(leading: edges.leading, trailing: edges.trailing, slotWidth: width)
    }
}
