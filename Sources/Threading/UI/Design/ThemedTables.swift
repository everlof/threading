import AppKit

// MARK: - Virtual Content Rows

/// A fixed-height, single-line cell whose label survives reuse and streaming updates.
/// Frame layout avoids installing constraints for every line of a live table. The table still
/// owns selection, scrolling, accessibility and the lifetime of offscreen cells.
public final class ThemedTableTextCell: NSTableCellView {
    public let label = NSTextField(labelWithString: "")
    public var horizontalInset: CGFloat = Design.Spacing.tight {
        didSet { needsLayout = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.applyFont(.compactCode)
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = true
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: horizontalInset, dy: 0)
    }
}

/// A recycled table-cell shell for content whose height comes from Auto Layout.
///
/// AppKit does not state a view-based table cell's column width while asking Auto Layout for its
/// height. Without the explicit width below, a wrapping settings or transcript row solves at its
/// narrowest legal width, reports a very tall height, and only later gets stretched by the table.
/// The host owns that one piece of table plumbing so virtualized feature lists do not each grow a
/// subtly different copy.
public final class ThemedVirtualTableCell: NSTableCellView {
    private lazy var columnWidth: NSLayoutConstraint = {
        let constraint = widthAnchor.constraint(equalToConstant: 0)
        constraint.priority = NSLayoutConstraint.Priority(999)
        return constraint
    }()

    public func install(
        _ content: NSView,
        columnWidth width: CGFloat,
        horizontalInset: CGFloat = 0,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) {
        subviews.forEach { $0.removeFromSuperview() }
        setColumnWidth(width)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset)
        ])
    }

    public func setColumnWidth(_ width: CGFloat) {
        guard width > 0 else {
            columnWidth.isActive = false
            return
        }
        guard !columnWidth.isActive || abs(columnWidth.constant - width) > 0.5 else { return }
        columnWidth.constant = width
        columnWidth.isActive = true
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        subviews.forEach { $0.removeFromSuperview() }
    }
}

/// A run of virtual rows that reads as one settings card.
///
/// `topInset` and `bottomInset` belong to the first and last row hosts respectively. Repeating
/// them here keeps the painted panel behind the content rather than behind the inter-section
/// breathing room carried by those rows.
public struct ThemedTableCardDecoration: Equatable {
    public let rows: ClosedRange<Int>
    public var topInset: CGFloat = 0
    public var bottomInset: CGFloat = 0
}

/// A virtual table that paints grouped settings-card surfaces behind row runs.
///
/// The surface belongs to the table, not to a retained container around all of its rows. AppKit
/// can therefore recycle every offscreen cell while the group still reads as one continuous card;
/// only the cheap row range survives outside the viewport.
public final class ThemedGroupedTableView: ThemedTableView {
    public var cardDecorations: [ThemedTableCardDecoration] = [] {
        didSet { needsDisplay = true }
    }

    public override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)

        for decoration in cardDecorations where decoration.rows.lowerBound >= 0
            && decoration.rows.upperBound < numberOfRows {
            let first = rect(ofRow: decoration.rows.lowerBound)
            let last = rect(ofRow: decoration.rows.upperBound)
            var cardRect = first.union(last).insetBy(dx: Design.Size.glowGutter, dy: 0)
            cardRect.origin.y += decoration.topInset
            cardRect.size.height -= decoration.topInset + decoration.bottomInset
            guard cardRect.width > 0, cardRect.height > 0,
                  cardRect.insetBy(dx: -Design.Size.glowGutter, dy: -Design.Size.glowGutter)
                    .intersects(clipRect) else { continue }

            drawCard(in: cardRect)
            drawDividers(in: decoration, cardRect: cardRect, clipRect: clipRect)
        }
    }

    private func drawCard(in rect: NSRect) {
        let radius = Design.Radius.panel
        let silhouette = ThemedSurface.Shape(rect: rect, radius: radius)
        if let glow = AppThemePalette.current.material.glow {
            if let highlight = glow.highlight {
                drawShadow(
                    around: silhouette,
                    color: AppThemePalette.current.resolved(highlight.role),
                    radius: highlight.radius,
                    opacity: highlight.opacity,
                    offset: NSSize(width: highlight.offsetX, height: highlight.offsetY)
                )
            }
            drawShadow(
                around: silhouette,
                color: AppThemePalette.current.resolved(glow.role),
                radius: glow.radius,
                opacity: glow.opacity,
                offset: NSSize(width: glow.offsetX, height: glow.offsetY)
            )
        }

        ThemedSurface.draw(
            rect,
            fill: Design.Surface.panel,
            border: Design.Surface.border,
            radius: radius,
            borderWidth: Design.Radius.border
        )
    }

    /// `NSShadow` needs a caster as well as a path. Painting the panel colour makes the caster
    /// disappear into the final panel pass while leaving only the authored outer shadow visible.
    private func drawShadow(
        around shape: ThemedSurface.Shape,
        color: NSColor,
        radius: CGFloat,
        opacity: Double,
        offset: NSSize
    ) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(CGFloat(opacity))
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = offset
        shadow.set()
        Design.Surface.panel.setFill()
        shape.path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDividers(
        in decoration: ThemedTableCardDecoration,
        cardRect: NSRect,
        clipRect: NSRect
    ) {
        guard decoration.rows.lowerBound < decoration.rows.upperBound else { return }
        let visible = rows(in: clipRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        let firstVisible = max(decoration.rows.lowerBound, visible.location)
        let lastVisibleBoundary = min(
            decoration.rows.upperBound,
            visible.location + visible.length
        )
        guard firstVisible < lastVisibleBoundary else { return }

        Design.Surface.border.setFill()
        for row in firstVisible..<lastVisibleBoundary {
            let boundary = rect(ofRow: row).maxY
            NSRect(
                x: cardRect.minX + Design.Spacing.inset,
                y: boundary,
                width: max(0, cardRect.maxX - cardRect.minX - Design.Spacing.inset),
                height: 1
            ).fill()
        }
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
public enum RowControls {

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
    public static func takesItsOwnClick(_ responder: NSResponder) -> Bool {
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
public class ThemedOutlineView:
    NSOutlineView,
    ThemedComponent,
    SystemChromeBoundary,
    SoleColumnFitting,
    SelectionStrengthStating {

    /// See `SoleColumnFitting`.
    public var soleColumnFillsBoundsExactly = false

    /// A secondary click (or an accessibility "show menu") landed on a row — `-1` for the
    /// empty stretch below the last one. Reported rather than handled, with the anchor the
    /// gesture carries: what a row's menu holds is the host's knowledge, not the outline's.
    /// Answers whether a menu actually opened, so the accessibility route can say so honestly.
    ///
    /// This replaces `menu(for:)`/`.menu`: the host presents an app-owned dropdown instead of
    /// an `NSMenu`, so the outline's part shrinks to resolving the row under the gesture.
    public var onContextMenu: ((Int, ThemedMenuAnchor) -> Bool)?

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
    public struct FlattenedIndentation {
        public let cellLeading: CGFloat
        public let markerLeading: CGFloat

        public init(cellLeading: CGFloat, markerLeading: CGFloat) {
            self.cellLeading = cellLeading
            self.markerLeading = markerLeading
        }
    }

    /// Nil draws the ordinary indented tree.
    public var flattenedIndentation: FlattenedIndentation?

    /// How far to either side of a row's disclosure chevron a press still folds the row.
    ///
    /// AppKit's chevron already spans its row's full height, but it is 13pt wide (measured on
    /// macOS 26) — so a press a few points beside the mark selected the row instead, which is
    /// what "the chevron's hitbox is small" meant. Widening the button itself is the obvious
    /// route, and it moves what the button draws: the system triangle and the authored marker
    /// (which takes the button's frame) both re-centre in the wider frame. So the button keeps
    /// its frame and its pixels, and `mouseDown` hands a press in the band around it to that
    /// same button — expansion then takes AppKit's own route, including `shouldExpandItem`,
    /// Option-click folding descendants, and the notifications hosts persist collapse from.
    ///
    /// **How far is the host's to say**, because the trailing side reaches into the cell and only
    /// the host knows where its row's content begins. So that side is measured from the cell's
    /// leading edge, not the chevron's trailing one: the two need not meet — the compact tree
    /// leaves a point between them — and a reach stated from the chevron stopped that point short
    /// of the content it was measured against. Zero — every list but the one that opts in —
    /// leaves AppKit's own target exactly as it was.
    public struct DisclosureHitOutsets: Equatable, Sendable {
        /// Points before the chevron's leading edge.
        public let beforeChevron: CGFloat
        /// Points past the leading edge of the row's cell; the target never ends before the
        /// chevron does.
        public let intoCell: CGFloat

        public static let zero = DisclosureHitOutsets(beforeChevron: 0, intoCell: 0)

        public init(beforeChevron: CGFloat, intoCell: CGFloat) {
            self.beforeChevron = beforeChevron
            self.intoCell = intoCell
        }
    }

    public var disclosureHitOutsets: DisclosureHitOutsets = .zero

    /// The disclosure a press at `point`, in this view's coordinates, belongs to: the chevron of
    /// the row under it, widened by `disclosureHitOutsets` and clipped to that row. Nil for a row
    /// with nothing to disclose, and for every point while the outsets are zero.
    func disclosureButton(forPressAt point: NSPoint) -> NSButton? {
        guard disclosureHitOutsets != .zero else { return nil }

        let row = row(at: point)
        guard row >= 0,
              let rowView = rowView(atRow: row, makeIfNecessary: false),
              let button = disclosureButton(in: rowView),
              !button.isHidden, button.isEnabled
        else { return nil }

        let rowFrame = convert(rowView.bounds, from: rowView)
        let marker = convert(button.frame, from: rowView)
        let cellLeading = outlineTableColumn
            .flatMap { column in tableColumns.firstIndex { $0 === column } }
            .map { frameOfCell(atColumn: $0, row: row).minX }
            ?? marker.maxX
        let minX = max(rowFrame.minX, marker.minX - disclosureHitOutsets.beforeChevron)
        let maxX = min(
            rowFrame.maxX,
            max(marker.maxX, cellLeading + disclosureHitOutsets.intoCell)
        )
        guard point.x >= minX, point.x < maxX,
              point.y >= rowFrame.minY, point.y < rowFrame.maxY
        else { return nil }
        return button
    }

    private let disclosureEvents = AppEventObservations()
    private let disclosureWindowEvents = AppEventObservations()

    /// Points of the style's own trailing padding handed back to the cells.
    ///
    /// `.inset` — what `.automatic` resolves to — keeps 16pt past every cell's trailing edge, and
    /// that band is where a narrow list's last reclaimable space is: the row's own gutter is a
    /// couple of points, while this is sixteen. Measured on macOS 26 at every width; the same
    /// number appears in `SoleColumnFitting`, which meets it from the column's side.
    ///
    /// Widening only, and never past the row's trailing edge. **How far is the host's to say**,
    /// because what bounds it is the shape that host draws: content moving out into this band has
    /// to stay inside the silhouette a selected row fills, and only the host knows where that is.
    /// See `SidebarDefaults.tightTrailingCellReclaim`.
    public var trailingCellReclaim: CGFloat = 0

    /// Only the outline column indents, and this list has only that column — so the override
    /// applies wherever the frame came back indented rather than guessing at column indexes.
    public override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        guard tableColumns.indices.contains(column),
              tableColumns[column] === outlineTableColumn, !frame.isEmpty else { return frame }

        if let flattened = flattenedIndentation {
            let trailingEdge = frame.maxX
            frame.origin.x = flattened.cellLeading
            frame.size.width = max(0, trailingEdge - flattened.cellLeading)
        }

        if trailingCellReclaim > 0 {
            let reclaimed = min(trailingCellReclaim, max(0, bounds.width - frame.maxX))
            frame.size.width += reclaimed
        }
        return frame
    }

    /// AppKit answers `.zero` for a row with nothing to disclose; that answer stands.
    public override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard let flattened = flattenedIndentation, !frame.isEmpty else { return frame }

        frame.origin.x = flattened.markerLeading
        return frame
    }

    /// Moves the rows the outline already owns to the geometry it would build them at now.
    ///
    /// `indentationPerLevel` and `flattenedIndentation` are read when a row is *built*, and
    /// nothing re-reads them afterwards: measured on macOS 26, a change followed by
    /// `layoutSubtreeIfNeeded`, `tile()` or `noteHeightOfRows` leaves every mounted cell and
    /// chevron exactly where it was, while `frameOfCell` already answers the new place. Only
    /// `reloadData()` re-places them — which discards and rebuilds the whole list, and a
    /// continuous divider drag cannot pay that per frame. `reloadData(forRowIndexes:…)` is no
    /// help either: it rebuilds the cell and leaves the chevron behind.
    ///
    /// So the placement is applied directly, to both halves of a row, for the rows the table
    /// currently has views for — `enumerateAvailableRowViews`, which is the viewport plus
    /// AppKit's own margin, never the whole tree. Rows built later take the same geometry from
    /// `frameOfCell`/`frameOfOutlineCell` on their own, so scrolling in stays consistent.
    ///
    /// The chevron is AppKit's own button, added as a direct subview of the row view and stamped
    /// with `NSOutlineView.disclosureButtonIdentifier` — the identifier the framework documents
    /// for exactly this, so the marker is named rather than guessed at by position or class.
    public func refitIndentedRows() {
        guard let column = outlineTableColumn,
              let columnIndex = tableColumns.firstIndex(where: { $0 === column })
        else { return }

        // **Only the horizontal half is taken.** Both `frameOfCell` and `frameOfOutlineCell`
        // answer in the *table's* coordinates, and a cell and a chevron live in their row
        // view's — where a row's own content sits at y 0. Assigning either frame whole moves
        // every row's content down by the row's offset in the list, out of the row it belongs
        // to: the first render of this showed a column with one clipped project row and nothing
        // under it. Indentation is horizontal; nothing else here is this method's to move.
        func slide(_ subview: NSView, toX x: CGFloat, width: CGFloat) {
            var frame = subview.frame
            frame.origin.x = x
            frame.size.width = width
            subview.frame = frame
        }

        enumerateAvailableRowViews { rowView, row in
            if let cell = view(atColumn: columnIndex, row: row, makeIfNecessary: false) {
                let target = frameOfCell(atColumn: columnIndex, row: row)
                slide(cell, toX: target.minX, width: target.width)
            }

            let markerFrame = frameOfOutlineCell(atRow: row)
            guard !markerFrame.isEmpty,
                  let marker = disclosureButton(in: rowView)
            else { return }
            slide(marker, toX: markerFrame.minX, width: markerFrame.width)
        }

        refreshDisclosureInks()
    }

    private lazy var selectionStrength = ListSelectionStrength(self)

    /// See `SoleColumnFitting`.
    public var soleColumnFitWidth: CGFloat = -1

    /// See `SelectionStrengthStating` — asked by this list's own rows as AppKit demotes them,
    /// which in the sidebar is every time a click hands focus to the session it just opened.
    public var drawsSelectionAtFullStrength: Bool { selectionStrength.drawsAsKey }

    /// See `ListSelectionStrength.fixtureIsKey`.
    public var fixtureIsKey: Bool? {
        get { selectionStrength.fixtureIsKey }
        set { selectionStrength.fixtureIsKey = newValue }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundColor = .clear
        disclosureEvents.observe(
            NSTableView.selectionDidChangeNotification,
            object: self
        ) { [weak self] in
            self?.refreshDisclosureInks()
        }
        for name in [
            NSOutlineView.itemDidExpandNotification,
            NSOutlineView.itemDidCollapseNotification,
        ] {
            disclosureEvents.observe(name, object: self) { [weak self] in
                self?.refreshDisclosureInks()
            }
        }
        disclosureEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.refreshDisclosureInks()
        }
        disclosureEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.refreshDisclosureInks()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewWillDraw() {
        super.viewWillDraw()
        fitSoleColumnToWidth()
        selectionStrength.apply()
        refreshDisclosureInks()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionStrength.followWindow()
        followWindowForDisclosureInk()
        refreshDisclosureInks()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDisclosureInks()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        _ = fitExactSoleColumn(to: newSize.width)
        super.setFrameSize(newSize)
        fitSoleColumnToWidth()
    }

    public override func layout() {
        super.layout()
        fitSoleColumnToWidth()
        refreshDisclosureInks()
    }

    /// AppKit's disclosure is a direct child of the row rather than of the cell, so it never
    /// receives the cell's `interiorBackgroundStyle` update that correctly re-inks the title
    /// and trailing controls. `contentTintColor` does not affect the private disclosure cell's
    /// pixels either. Under an authored theme, keep that button as the hit target but make it
    /// transparent and draw the semantic mark immediately behind it; System keeps AppKit's
    /// pixels untouched. Work stays bounded to the mounted viewport rows, and resolution happens
    /// inside the button's appearance for adaptive themes and offscreen fixtures.
    private func refreshDisclosureInks() {
        enumerateAvailableRowViews { rowView, row in
            guard let button = disclosureButton(in: rowView) else { return }
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard !AppThemePalette.current.isSystem else {
                    button.isTransparent = false
                    disclosureMarker(in: rowView)?.removeFromSuperview()
                    return
                }

                let marker = disclosureMarker(in: rowView) ?? makeDisclosureMarker(
                    in: rowView,
                    behind: button
                )
                let expanded = item(atRow: row).map(isItemExpanded) ?? false
                let identifier = expanded
                    ? Self.expandedDisclosureMarkerIdentifier
                    : Self.collapsedDisclosureMarkerIdentifier
                if marker.identifier != identifier {
                    marker.identifier = identifier
                    marker.setSymbol(
                        expanded ? "chevron.down" : "chevron.right",
                        role: .chevron,
                        weight: .semibold
                    )
                }
                marker.frame = button.frame
                marker.tint =
                    (rowView as? OutlineDisclosureInkProviding)?.outlineDisclosureInk
                    ?? Design.Text.tertiary
                button.isTransparent = true
            }
            button.needsDisplay = true
        }
    }

    private static let collapsedDisclosureMarkerIdentifier = NSUserInterfaceItemIdentifier(
        "ThemedOutlineView.collapsedDisclosureMarker"
    )
    private static let expandedDisclosureMarkerIdentifier = NSUserInterfaceItemIdentifier(
        "ThemedOutlineView.expandedDisclosureMarker"
    )

    private func disclosureMarker(in rowView: NSTableRowView) -> GlyphView? {
        rowView.subviews.first(where: {
            $0.identifier == Self.collapsedDisclosureMarkerIdentifier
                || $0.identifier == Self.expandedDisclosureMarkerIdentifier
        }) as? GlyphView
    }

    private func makeDisclosureMarker(
        in rowView: NSTableRowView,
        behind button: NSButton
    ) -> GlyphView {
        let marker = GlyphView()
        marker.translatesAutoresizingMaskIntoConstraints = true
        rowView.addSubview(marker, positioned: .below, relativeTo: button)
        return marker
    }

    private func disclosureButton(in rowView: NSTableRowView) -> NSButton? {
        rowView.subviews.first(where: {
            $0.identifier == NSOutlineView.disclosureButtonIdentifier
        }) as? NSButton
    }

    /// Selection strength follows the window rather than list focus. The row's fill changes on
    /// those two transitions, so the system control sitting on that fill has to move with it.
    private func followWindowForDisclosureInk() {
        disclosureWindowEvents.removeAll()
        guard let window else { return }

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            disclosureWindowEvents.observe(name, object: window) { [weak self] in
                self?.refreshDisclosureInks()
            }
        }
    }

    /// See `ThemedTableRowDefaults.vendedView(for:recycling:)` — this is where a list that says
    /// nothing about selection still gets the theme's row, and where a view coming back out of
    /// the reuse queue is brought up to the theme in force.
    public override func makeView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        owner: Any?
    ) -> NSView? {
        ThemedTableRowDefaults.vendedView(
            for: identifier,
            recycling: super.makeView(withIdentifier: identifier, owner: owner)
        )
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else {
            super.rightMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        _ = onContextMenu(row(at: point), .pointer(event.locationInWindow))
    }

    /// The pointerless route to the same menu, anchored to the selected row itself.
    public override func accessibilityPerformShowMenu() -> Bool {
        guard let onContextMenu, selectedRow >= 0 else {
            return super.accessibilityPerformShowMenu()
        }
        return onContextMenu(selectedRow, .control)
    }

    /// A press on the chevron itself never arrives here — the button is hit first. This is the
    /// band around it; see `disclosureHitOutsets`.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let button = disclosureButton(forPressAt: point) {
            button.performClick(nil)
            return
        }
        super.mouseDown(with: event)
    }

    /// Disclosure triangles are controls AppKit inserts into outline rows after the data source
    /// returns them. Permit only that identified system control; an ordinary button anywhere in
    /// a cell remains a runtime violation.
    public func permitsSystemChrome(_ view: NSView) -> Bool {
        guard let button = view as? NSButton else { return false }
        return button.identifier == NSOutlineView.disclosureButtonIdentifier
    }

    /// The sidebar's own case of `RowControls`, and the one the reports were about.
    public override func validateProposedFirstResponder(
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
public class ThemedTableHeaderView: NSTableHeaderView, ThemedComponent {

    private var themeRedraw: ThemeRedraw?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func draw(_ dirtyRect: NSRect) {
        // The floating-surface rule (`ImageCompareView`, `ThemedTabItemView`): a fill that stands
        // over moving content is flattened over its ground, because `controlResting` is
        // deliberately below full opacity — 5% under Swiss Minimalist and most palette themes, and
        // only opaque under a few. That is right for a control on a panel and wrong for the one
        // surface in a table whose whole job is to hide what is behind it.
        //
        // Nothing opaque is behind it to help: `ThemedScrollView` turns its own background off in
        // `init`, and its `tile()` turns the header clip's off too. This fill is the only occluder
        // there is, which is why the log rows were legible straight through the column titles.
        Design.Surface.controlResting.composited(over: InkSource.chrome.ground).setFill()
        bounds.fill()

        guard let tableView else { return }

        for index in tableView.tableColumns.indices {
            let column = tableView.tableColumns[index]
            let rect = headerRect(ofColumn: index)
            let titleRect = rect.insetBy(dx: Design.Spacing.small, dy: Design.Spacing.tight)
            // A column states which edge its content is set against — a name reads from the
            // leading edge, a figure from the trailing one — and a heading that ignores it
            // stands over the wrong end of its own column. `NSTableColumn` already carries that
            // answer; taking it here is what keeps a caller from re-stating alignment twice.
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = column.headerCell.alignment
            paragraph.lineBreakMode = .byTruncatingTail
            (column.title as NSString).draw(
                in: titleRect,
                withAttributes: [
                    .font: Design.Typography.caption(),
                    .foregroundColor: Design.Text.secondary,
                    .paragraphStyle: paragraph
                ]
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
