import AppKit

/// Tables that start transparent, replacing `NSTableView` and `NSOutlineView`.
///
/// The stock background is `controlBackgroundColor` — a system surface that stays
/// system-white or system-charcoal on a page that has gone neon. Every table in the app
/// sits on a pane the theme already painted, so transparent is not a preference here, it
/// is the only value any call site ever wanted; the ones that forgot were bugs waiting
/// for a styled theme to expose them.
///
/// Selection is not claimed *here*, because a list's rows are the only thing that can draw it:
/// see `ThemedTableRowView`, which a list hands back from `rowViewForRow:` and the sidebar
/// answers its own way. How *strongly* they draw it is this file's, and every list's:
/// `ListSelectionStrength`.
class ThemedTableView: NSTableView, ThemedComponent {

    private lazy var selectionStrength = ListSelectionStrength(self)

    /// See `ListSelectionStrength.fixtureIsKey`. Restated on both classes rather than shared,
    /// for the reason `ThemedOutlineView` gives: `NSOutlineView` is already an `NSTableView`.
    var fixtureIsKey: Bool? {
        get { selectionStrength.fixtureIsKey }
        set { selectionStrength.fixtureIsKey = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        selectionStrength.apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionStrength.followWindow()
    }

    /// See `ThemedTableRowDefaults.rowView(for:from:owner:)` — this is where a list that says
    /// nothing about selection still gets the theme's row.
    override func makeView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        owner: Any?
    ) -> NSView? {
        ThemedTableRowDefaults.rowView(
            for: identifier,
            recycling: super.makeView(withIdentifier: identifier, owner: owner)
        )
    }

    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        if MainActor.assumeIsolated({
            RowControls.takesItsOwnClick(responder)
        }) {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

// MARK: - Selection Strength

/// **A list draws its selection at the strength of its window, never of the focus inside it.**
///
/// AppKit's rule is the other one: `NSTableRowView.isEmphasized` follows the *first responder*,
/// so a list that does not hold focus shows the quiet fill — a flat grey under **System**, and
/// whatever each theme holds back for `accentMuted` elsewhere. That is right for an app where a
/// click leaves focus in the list it landed in, and this is not one. Selecting a session attaches
/// its controller and calls `focusTerminal`, so the row a click had just selected was demoted a
/// turn later, into a fill a hair from the hover wash; the second click selected nothing new,
/// presented no session, took no focus, and was the one that appeared to work. *First tap hovers,
/// second tap selects*, for a pane that had been showing the right session since the first.
///
/// It is the second report of one defect. `ThemedIconButton.mouseDown` used to take first
/// responder, which recoloured a **different** row's selection and read as random (see
/// `design-system.md`); that was fixed by having one control stop taking focus, which left every
/// other way of taking it — the terminal, the composer, a web view, the next thing — still able
/// to reintroduce it. So the rule is stated where it cannot be missed instead of defended at each
/// place focus moves.
///
/// **Here is the last point every row passes through.** A row class cannot carry it: the row that
/// gets this wrong is the one nobody wrote, since a delegate returning no row view is handed a
/// plain `NSTableRowView`. `ThemedTableView` and `ThemedOutlineView`, by contrast, are provably
/// every list in the app — subclassing `NSTableView` or `NSOutlineView` anywhere else fails
/// `scripts/check_theme_boundaries.sh`, which is what makes this a construction rather than
/// another fix. Rows stay dumb: they read `isEmphasized` and draw.
@MainActor
final class ListSelectionStrength {

    /// Key state stated by a fixture. An unshown test window is never key, and the emphasized
    /// selection is the state worth asserting, so without this the rule is unrenderable outside
    /// a window ordered on screen — which `Threading-Fast` is built to avoid.
    var fixtureIsKey: Bool? {
        didSet { apply() }
    }

    private weak var table: NSTableView?
    nonisolated(unsafe) private var windowStateObservations: [NSObjectProtocol] = []

    init(_ table: NSTableView) {
        self.table = table
    }

    deinit {
        windowStateObservations.forEach(NotificationCenter.default.removeObserver)
    }

    /// Re-asserted from `viewWillDraw`, which is the last moment before any row of this list
    /// paints and therefore the one place that covers every way a row can arrive demoted: AppKit
    /// lowering all of them when the list resigns, and a row built later while scrolling. Rows
    /// already holding the right answer are left alone, so this costs a comparison per visible
    /// row and no invalidation.
    func apply() {
        guard let table else { return }

        let emphasized = drawsAsKey
        table.enumerateAvailableRowViews { row, _ in
            guard row.isEmphasized != emphasized else { return }
            row.isEmphasized = emphasized
        }
    }

    /// The window's own transitions, which nothing else would repaint: to AppKit an unfocused
    /// list is unemphasized before and after its window comes back, so it has no change to report
    /// and no row to invalidate. Applied directly rather than by invalidating the list, because
    /// raising a row's emphasis is what marks that row for display.
    func followWindow() {
        windowStateObservations.forEach(NotificationCenter.default.removeObserver)
        windowStateObservations = []

        defer { apply() }
        guard let window = table?.window else { return }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ] {
            windowStateObservations.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
    }

    /// A list with no window yet draws its key form, the same answer `WindowChromeButton` gives:
    /// a fixture is not a background window.
    private var drawsAsKey: Bool {
        guard let window = table?.window else { return fixtureIsKey ?? true }
        return fixtureIsKey ?? window.isKeyWindow
    }
}

// MARK: - Row

/// The row a themed list is selected in, replacing the plain `NSTableRowView` AppKit builds for
/// a list whose delegate hands back none.
///
/// AppKit's selection is the **system** accent — blue on nearly every Mac, and read from the
/// user's settings rather than from the window — so a list that says nothing lights a stock blue
/// bar in the middle of a themed pane. Reported against the attachments pane, whose lavender
/// window had a Finder-blue row in it; nothing there had claimed selection, and nothing had to
/// for the blue to appear. Every list that leaves the question alone has the same defect, which
/// is why the answer is a component rather than a fix at one call site.
///
/// The fill is the theme's `selection` role — the accent held far enough back that the row's own
/// label tiers still read over it, so a row states its selection without restating its contents.
/// That is deliberately *not* the sidebar's answer — `SidebarHoverRowView` fills with the accent
/// at full strength, because the selected session is the window's subject and a list inside a pane
/// answering at the same strength would put two selections in one window with equal weight.
///
/// **"Held far enough back" was a description, and is now a construction.** It was true of every
/// theme that happened to author a wash and false of the two that authored a near-opaque fill:
/// Windows 98's 90% navy put the chrome's near-black label on it at 1.47:1, Platinum's 88% blue at
/// 3.70:1. Nothing caught it because the row draws the fill and the *cells* are feature code —
/// nine view controllers inking themselves from `Design.Text`, as anything on the chrome's ground
/// should. `SelectionSurface.quiet` is the strength a surface takes when it cannot reach the ink
/// of what it contains: it holds the authored fill back until that ink reads, and leaves themes
/// that already kept the promise exactly as they were authored.
///
/// Under **System** it defers to `super` entirely, so the stock selection — the user's own
/// accent, its emphasized and unemphasized strengths, its vibrancy — is untouched.
class ThemedTableRowView: NSTableRowView, ThemedComponent {

    override func drawSelection(in dirtyRect: NSRect) {
        guard !AppThemeLibrary.current.isSystem else {
            return super.drawSelection(in: dirtyRect)
        }
        guard isSelected else { return }

        // The ground is measured rather than assumed: the same row class is drawn in the
        // attachments pane, in Git Review's file list and inside a settings sheet, and how far the
        // fill has to be held back depends on what is under it. `resolvedGround` is the walk that
        // already answers this for every other derived colour in the app.
        SelectionSurface.quiet(over: resolvedGround()).fill.setFill()
        selectionPath.fill()
    }

    /// The theme's control corner, inset just off the row's edges so the fill reads as a surface
    /// the row is sitting on rather than as a band ruled across the list — and so a rounded
    /// theme's corner has somewhere to turn. The same silhouette rule the sidebar's rows follow,
    /// at a list's scale rather than a source list's.
    private var selectionPath: NSBezierPath {
        let shape = bounds.insetBy(
            dx: ThemedTableRowDefaults.selectionInsetX,
            dy: ThemedTableRowDefaults.selectionInsetY
        )
        let radius = Design.Radius.control(fitting: shape.size)
        return NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)
    }
}

enum ThemedTableRowDefaults {
    /// Enough to keep the fill off the list's edges without pulling it in from the row's
    /// content, which starts one `small` step in.
    static let selectionInsetX: CGFloat = Design.Spacing.hairline
    /// The same 1pt the sidebar's rows leave, so two consecutive selected rows read as two.
    static let selectionInsetY: CGFloat = Design.Spacing.hairline / 2

    /// AppKit's own key for a list's row view, held here because its Swift binding was obsoleted
    /// in Swift 3 while the constant itself was not: `NSTableView.h` still declares
    /// `NSTableViewRowViewKey` and still pins it to this string.
    static let rowViewKey = NSUserInterfaceItemIdentifier("NSTableViewRowViewKey")

    /// **Every list in this app selects through `ThemedTableRowView`, including the lists that
    /// never say so.**
    ///
    /// A row view is *created*, not asked for: a delegate that returns nothing from
    /// `rowViewForRow:` — or a list whose delegate has no such method at all — is handed a plain
    /// `NSTableRowView`, which fills its selected row with the **system** accent. That was live
    /// in four panes at once (see `ThemedTableRowView`), and not one of them contained a line to
    /// review: the defect was the absence of one, which is the single thing a source lint cannot
    /// see and a reviewer cannot read.
    ///
    /// So the answer is taken away from the call sites. AppKit asks
    /// `makeView(withIdentifier:owner:)` for `rowViewKey` before falling back to its own class,
    /// and `ThemedTableView`/`ThemedOutlineView` are provably every list in the app — subclassing
    /// `NSTableView` or `NSOutlineView` anywhere else fails `scripts/check_theme_boundaries.sh`.
    /// A delegate that *does* state a row still wins, because AppKit asks it first and only lands
    /// here when it declines; that is what leaves the sidebar's louder row (`SidebarHoverRowView`)
    /// alone while its unselectable headings quietly take this one.
    ///
    /// `recycling` is `super`'s answer, taken first so the reuse queue keeps working: after the
    /// first screenful it hands back the rows this list already made, which are these.
    static func rowView(
        for identifier: NSUserInterfaceItemIdentifier,
        recycling recycled: NSView?
    ) -> NSView? {
        if let recycled { return recycled }
        guard identifier == rowViewKey else { return nil }

        let row = ThemedTableRowView()
        row.identifier = identifier
        return row
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
/// anywhere else still selects it — "anywhere else" meaning outside every such control, the glyphs
/// and labels *inside* one included, for the reason `takesItsOwnClick` states.
@MainActor
enum RowControls {

    /// Whether the click that landed on `responder` belongs to a control rather than to the row.
    ///
    /// **AppKit asks about the deepest view under the pointer**, and that is the whole subtlety:
    /// what it hit is not what the user aimed at. `ThemedIconButton` draws its glyph in a child
    /// view (a `GlyphView`; an `NSImageView` when this was found), so the proposed responder over
    /// an archive box is that child — which AppKit does not exempt — and the table went on vetoing the click in the
    /// middle of a button it had just been taught to allow. What survived was the four-point
    /// padding ring around the glyph, which is why this was reported twice and differently: the `⋯`
    /// "worked, but nowhere near always" because an ellipsis is 9 points tall in a 20-point target
    /// and leaves live bands above and below it, while the archive box was "basically impossible"
    /// because `archivebox` is 12×16 and fills nearly all of the same target. Both are one glyph
    /// in the way, measured as a 16-point-wide dead centre.
    ///
    /// So the question is not *is this a control* but *is it inside one*: a control's glyph, label
    /// or chip is part of the target it draws, and a click landing on one is a click on the
    /// control. Letting it through is enough — the press then reaches the control the way it
    /// already does outside a list, an `NSImageView` with no action of its own forwarding it up the
    /// responder chain.
    static func takesItsOwnClick(_ responder: NSResponder) -> Bool {
        guard let view = responder as? NSView else { return false }
        return owner(of: view) != nil
    }

    /// The nearest control at or above `view` that acts on its own click.
    ///
    /// The walk stops at the row, so nothing the list is nested *inside* can claim a click that
    /// landed within it — the rule answers about one row's contents and no further.
    private static func owner(of view: NSView) -> NSView? {
        for node in sequence(first: view, next: { $0.superview }) {
            if node is ThemedControl || node is NSButton { return node }
            if node is NSTableRowView || node is NSTableView { return nil }
        }
        return nil
    }
}

/// `ThemedTableView`'s rule again, one class up: `NSOutlineView` inherits `NSTableView`,
/// so the two-line duplication here is what lets both keep their real superclass.
class ThemedOutlineView: NSOutlineView, ThemedComponent, SystemChromeBoundary {

    /// A secondary click (or an accessibility "show menu") landed on a row — `-1` for the
    /// empty stretch below the last one. Reported rather than handled, with the anchor the
    /// gesture carries: what a row's menu holds is the host's knowledge, not the outline's.
    /// Answers whether a menu actually opened, so the accessibility route can say so honestly.
    ///
    /// This replaces `menu(for:)`/`.menu`: the host presents an app-owned dropdown instead of
    /// an `NSMenu`, so the outline's part shrinks to resolving the row under the gesture.
    var onContextMenu: ((Int, ThemedMenuAnchor) -> Bool)?

    /// Starts every row's content at one leading edge, whatever its depth.
    ///
    /// `indentationPerLevel` stays untouched — zeroing it is the obvious route, and it leaves
    /// AppKit computing marker and cell frames from degenerate geometry nobody documents.
    /// Instead the normal indented frames are asked for and re-placed: the cell keeps its
    /// right edge and takes `cellLeading` as its left one, and the disclosure chevron drops
    /// into a fixed gutter at `markerLeading`. Depth is then the host's to say some other way
    /// — the sidebar says it with type and vertical rhythm.
    ///
    /// The host owns relayout: rows already built keep their old frames until the next
    /// `reloadData()`, so flipping this mid-list without one shows both geometries at once.
    struct FlattenedIndentation {
        let cellLeading: CGFloat
        let markerLeading: CGFloat

        init(cellLeading: CGFloat, markerLeading: CGFloat) {
            self.cellLeading = cellLeading
            self.markerLeading = markerLeading
        }
    }

    /// Nil draws the ordinary indented tree.
    var flattenedIndentation: FlattenedIndentation?

    /// Only the outline column indents, and this list has only that column — so the override
    /// applies wherever the frame came back indented rather than guessing at column indexes.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        guard let flattened = flattenedIndentation, tableColumns.indices.contains(column),
              tableColumns[column] === outlineTableColumn, !frame.isEmpty else { return frame }

        let trailingEdge = frame.maxX
        frame.origin.x = flattened.cellLeading
        frame.size.width = max(0, trailingEdge - flattened.cellLeading)
        return frame
    }

    /// AppKit answers `.zero` for a row with nothing to disclose; that answer stands.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard let flattened = flattenedIndentation, !frame.isEmpty else { return frame }

        frame.origin.x = flattened.markerLeading
        return frame
    }

    private lazy var selectionStrength = ListSelectionStrength(self)

    /// See `ListSelectionStrength.fixtureIsKey`.
    var fixtureIsKey: Bool? {
        get { selectionStrength.fixtureIsKey }
        set { selectionStrength.fixtureIsKey = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        selectionStrength.apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionStrength.followWindow()
    }

    /// See `ThemedTableRowDefaults.rowView(for:from:owner:)` — this is where a list that says
    /// nothing about selection still gets the theme's row.
    override func makeView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        owner: Any?
    ) -> NSView? {
        ThemedTableRowDefaults.rowView(
            for: identifier,
            recycling: super.makeView(withIdentifier: identifier, owner: owner)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else {
            super.rightMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        _ = onContextMenu(row(at: point), .pointer(event.locationInWindow))
    }

    /// The pointerless route to the same menu, anchored to the selected row itself.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let onContextMenu, selectedRow >= 0 else {
            return super.accessibilityPerformShowMenu()
        }
        return onContextMenu(selectedRow, .control)
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
        if MainActor.assumeIsolated({
            RowControls.takesItsOwnClick(responder)
        }) {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
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
