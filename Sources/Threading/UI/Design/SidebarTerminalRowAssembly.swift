import AppKit

/// The default terminal row's content, action control and shared layout relationship.
/// Its host owns terminal identity, menu commands, hover and foreground status.
@MainActor
final class SidebarTerminalRowAssembly {
    let visuals = ThemedTerminalRowContentView()
    let actionButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.actionSymbol,
        accessibility: L10n.string("Terminal actions"),
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )

    init() {
        actionButton.presentsMenu = true
        actionButton.alphaValue = 0
        actionButton.setAccessibilityIdentifier("sidebar.terminal.actions")
    }

    func mount(in row: NSView, leadingInset: CGFloat, trailingInset: CGFloat)
        -> (leading: NSLayoutConstraint, trailing: NSLayoutConstraint) {
        row.addSubview(visuals)
        row.addSubview(actionButton)
        return SidebarRowDefaults.constrainContent(
            visuals, trailingSlot: actionButton, in: row,
            leadingInset: leadingInset, trailingInset: trailingSlotInset(for: trailingInset))
    }

    func trailingSlotInset(for gutter: CGFloat) -> CGFloat {
        max(0, gutter - actionButton.opticalHorizontalInset)
    }
}
