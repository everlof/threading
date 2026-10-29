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
    private(set) var statusSpinner: ThemedSpinner?
    private var isBusy = false

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

    /// A foreground command is the only reason to construct the status view. Recycled rows
    /// retain that one view, while idle terminals never pay for a hidden spinner or animation.
    func setBusy(_ busy: Bool, in row: NSView, selected: Bool, actionVisible: Bool) {
        isBusy = busy
        guard busy || statusSpinner != nil else { return }

        let spinner: ThemedSpinner
        if let statusSpinner {
            spinner = statusSpinner
        } else {
            let materialized = ThemedSpinner()
            materialized.translatesAutoresizingMaskIntoConstraints = false
            materialized.setAccessibilityLabel(L10n.string("Terminal command running"))
            materialized.setAccessibilityIdentifier("sidebar.terminal.status")
            row.addSubview(materialized, positioned: .below, relativeTo: actionButton)
            NSLayoutConstraint.activate([
                materialized.centerXAnchor.constraint(equalTo: actionButton.centerXAnchor),
                materialized.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
                materialized.widthAnchor.constraint(equalToConstant: StatusIndicatorDefaults.spinnerSize),
                materialized.heightAnchor.constraint(equalToConstant: StatusIndicatorDefaults.spinnerSize)
            ])
            statusSpinner = materialized
            spinner = materialized
        }

        spinner.hostGround = selected ? .selection : nil
        spinner.isAnimating = busy
        spinner.alphaValue = busy && !actionVisible ? 1 : 0
    }

    func setActionVisible(_ visible: Bool, animated: Bool) {
        if visible { actionButton.materializeGlyphIfNeeded() }
        let statusAlpha: CGFloat = isBusy && !visible ? 1 : 0
        guard animated else {
            actionButton.alphaValue = visible ? 1 : 0
            statusSpinner?.alphaValue = statusAlpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            actionButton.animator().alphaValue = visible ? 1 : 0
            statusSpinner?.animator().alphaValue = statusAlpha
        }
    }

    func setSelected(_ selected: Bool) {
        let ground: InkSource? = selected ? .selection : nil
        actionButton.hostGround = ground
        statusSpinner?.hostGround = ground
    }
}
