import AppKit

/// Tables that start transparent, replacing `NSTableView` and `NSOutlineView`.
///
/// The stock background is `controlBackgroundColor` — a system surface that stays
/// system-white or system-charcoal on a page that has gone neon. Every table in the app
/// sits on a pane the theme already painted, so transparent is not a preference here, it
/// is the only value any call site ever wanted; the ones that forgot were bugs waiting
/// for a styled theme to expose them.
///
/// Selection is deliberately *not* claimed: an unemphasized source-list row's fill and the
/// emphasized accent are system behaviours the sidebar already curates per row
/// (`applyTextColors`), and a second owner for the same pixels is how the first one broke.
class ThemedTableView: NSTableView, ThemedComponent {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        RowControls.takesItsOwnClick(responder)
            || super.validateProposedFirstResponder(responder, for: event)
    }
}

// MARK: - Row Controls

/// Which of a row's subviews may have the click that landed on it.
///
/// `NSTableView` decides that in `validateProposedFirstResponder(_:for:)`, and its default answer
/// for a row that is **not already selected** is no: the table takes the click itself and selects
/// the row, so acting on the control needs a second one. That is the right gesture for a text
/// field — click to select the row, click again to edit — and the wrong one for a button, which
/// is why AppKit exempts its own `NSButton`s and why nothing about this was visible until this
/// app started building row buttons out of `ThemedControl`.
///
/// What it looked like: a session row's archive box did nothing at all, and its `⋯` opened "only
/// sometimes" — the sometimes being the row that happened to be selected already. Both clicks
/// were landing on the button, drawing its hover fill, and then being spent selecting the row
/// underneath, which also switched the session on screen and moved the sidebar's focus ring. The
/// three reports were one bug.
///
/// Stated as a rule about *controls that act on their own click*, not a list of classes: every
/// `ThemedControl` in this app is one (button, toggle, chip, pop-up, recorder — no text editor
/// among them), and `NSButton` covers AppKit's own, including the disclosure triangle an outline
/// view inserts. A label, an image or the row's ground is none of these, so clicking a row
/// anywhere else still selects it.
enum RowControls {

    static func takesItsOwnClick(_ responder: NSResponder) -> Bool {
        responder is ThemedControl || responder is NSButton
    }
}

/// `ThemedTableView`'s rule again, one class up: `NSOutlineView` inherits `NSTableView`,
/// so the two-line duplication here is what lets both keep their real superclass.
class ThemedOutlineView: NSOutlineView, ThemedComponent, SystemChromeBoundary {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Disclosure triangles are controls AppKit inserts into outline rows after the data source
    /// returns them. Permit only that identified system control; an ordinary button anywhere in
    /// a cell remains a runtime violation.
    func permitsSystemChrome(_ view: NSView) -> Bool {
        guard let button = view as? NSButton else { return false }
        return button.identifier == NSOutlineView.disclosureButtonIdentifier
    }

    /// The sidebar's own case of `RowControls`, and the one the reports were about.
    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        RowControls.takesItsOwnClick(responder)
            || super.validateProposedFirstResponder(responder, for: event)
    }
}

/// The containment seam for the one header the app has, replacing `NSTableHeaderView`.
///
/// Unlike AppKit's header cells, this draws both its surface and titles from semantic roles.
/// Mouse tracking and divider resizing remain `NSTableHeaderView` behavior; only its pixels are
/// replaced.
class ThemedTableHeaderView: NSTableHeaderView, ThemedComponent {

    private var themeRedraw: ThemeRedraw?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.controlResting.setFill()
        bounds.fill()

        guard let tableView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.caption(),
            .foregroundColor: Design.Text.secondary
        ]

        for index in tableView.tableColumns.indices {
            let rect = headerRect(ofColumn: index)
            let titleRect = rect.insetBy(dx: Design.Spacing.small, dy: Design.Spacing.tight)
            (tableView.tableColumns[index].title as NSString).draw(
                in: titleRect,
                withAttributes: attributes
            )

            if index < tableView.tableColumns.count - 1 {
                Design.Surface.divider.setFill()
                NSRect(
                    x: rect.maxX - Design.Radius.border,
                    y: rect.minY,
                    width: Design.Radius.border,
                    height: rect.height
                ).fill()
            }
        }

        Design.Surface.divider.setFill()
        NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: Design.Radius.border
        ).fill()
    }
}
