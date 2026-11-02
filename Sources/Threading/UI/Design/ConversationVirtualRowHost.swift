import AppKit

enum ConversationRowDefaults {
    static let arrivalAnimationKey = "conversationArrival"
    static let columnWidthPriority = NSLayoutConstraint.Priority(999)
}

// MARK: - Row Host

/// Reusable shell around a conversation row. The host, not the content, is what AppKit recycles;
/// replacing its child releases offscreen Markdown and tool constraint trees while AppKit keeps
/// automatic height ownership for the presentation table.
final class ConversationVirtualRowHost: NSTableCellView {
    private var releaseContent: (() -> Void)?
    /// The installed content's ceiling, `Design.Chat.columnWidth(inPane:)`.
    private weak var measureCap: NSLayoutConstraint?
    /// The measure this cell's pane currently gives, stated before and after content is installed.
    private var measure: CGFloat?
    /// How far the installed content's frame reaches past the column on each side, so what it
    /// draws stands on the column's edge and only its hover plate hangs outside it.
    private var overhang: CGFloat = 0
    /// How far inboard of the column the installed content stands, when it is nested.
    private var indent: CGFloat = 0

    /// The transcript's own text selection, which a press on this row's prose belongs to.
    weak var textSelection: TranscriptTextSelection?

    /// A primary press on transcript text is answered by the host rather than by the label under
    /// it, because the selection it starts may run on into other rows — which a label, owning
    /// only itself and lent the window's one field editor, cannot follow. Everything else keeps
    /// its own route: controls, links' neighbours, the scroll wheel over a code block, and a
    /// Control-click, which is a secondary click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, textSelection != nil,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control),
              TranscriptTextSegments.isText(hit, within: self) else { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let textSelection else {
            super.mouseDown(with: event)
            return
        }
        textSelection.track(mouseDown: event)
    }

#if os(Linux)
    override func mouseDragged(with event: NSEvent) {
        textSelection?.track(mouseDragged: event)
    }

    override func mouseUp(with event: NSEvent) {
        textSelection?.track(mouseUp: event)
    }
#endif


    /// The width of the column this cell sits in, which has to be *stated* — see
    /// `setColumnWidth`. Held on the cell rather than the content so it survives recycling.
    private lazy var columnWidth: NSLayoutConstraint = {
        // Above the content's own compression resistance and below required: a row too narrow
        // for what is in it gives way in the words, never by growing past the pane. Required
        // would make the same choice by breaking someone else's required constraint and
        // logging it as a failure.
        let constraint = widthAnchor.constraint(equalToConstant: 0)
        constraint.priority = ConversationRowDefaults.columnWidthPriority
        return constraint
    }()

    /// States how wide the cell's column is, because AppKit does not.
    ///
    /// **A cell is not given its column's width.** Under `usesAutomaticRowHeights` the table
    /// solves the cell from the constraints inside it, and a width nothing determines settles on
    /// the smallest that satisfies them. So a row capped at the readable measure came out
    /// exactly the measure plus its insets — 644pt, at the time — sitting at the column's
    /// leading edge, and the `centerXAnchor` below centred the content inside *that* rather
    /// than in the pane. The column the whole pane is designed around was therefore flush left
    /// in every window wider than 644, which is most of them: prose and bubbles hugged the
    /// sidebar with several hundred points of empty pane beside them, and the turn rail —
    /// placed for a column that is *centred* — landed on the first character of every paragraph.
    ///
    /// Stating the width is what makes `centerXAnchor` mean the pane's centre. It also closes
    /// the older fault the other way round: with the cell pinned to its column it can no longer
    /// grow past the clip in a pane narrower than the column.
    ///
    /// `paneWidth` is what the measure is read from, so a row and the reply box asking about one
    /// pane get one answer. A caller with no pane to name has only the column to go on.
    func setColumnWidth(_ width: CGFloat, paneWidth: CGFloat? = nil) {
        // The measure is restated beside the column: it follows the pane and is counted in the
        // reading size, so a resize or a text-size change moves it under a cell never recycled.
        let measure = Design.Chat.columnWidth(inPane: paneWidth ?? width)
        self.measure = measure
        let cap = measure + overhang * 2 - indent
        if let measureCap, abs(measureCap.constant - cap) > 0.5 {
            measureCap.constant = cap
        }
        guard width > 0 else {
            columnWidth.isActive = false
            return
        }
        guard !columnWidth.isActive || abs(columnWidth.constant - width) > 0.5 else { return }
        columnWidth.constant = width
        columnWidth.isActive = true
    }

    /// The column a table's cells stand in — the table's own, not its pane's, because the table
    /// insets the column and a cell centred on the pane's width would sit off that centre by
    /// half the inset.
    static func columnWidth(of tableView: NSTableView) -> CGFloat {
        tableView.tableColumns.first?.width ?? tableView.bounds.width
    }

    /// The width of the pane a table's column stands in, which is what the reading measure and the
    /// reply box both read. The scroller and the table's own insets are not the pane's to give up.
    static func paneWidth(of tableView: NSTableView) -> CGFloat {
        tableView.enclosingScrollView?.frame.width ?? columnWidth(of: tableView)
    }

    /// Tells every cell currently on screen how wide its column is, and answers with it.
    ///
    /// Called from the host's `viewDidLayout`, because a cell AppKit does not rebuild would
    /// otherwise go on centring itself in a column that no longer exists — the pane can be
    /// dragged wider without a single row being recycled.
    @discardableResult
    static func stateColumnWidth(in tableView: NSTableView) -> CGFloat {
        let width = columnWidth(of: tableView)
        guard width > 0 else { return width }
        let paneWidth = paneWidth(of: tableView)
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ConversationVirtualRowHost)?.setColumnWidth(width, paneWidth: paneWidth)
            }
        }
        return width
    }

    func install(
        _ content: NSView,
        topInset: CGFloat,
        bottomInset: CGFloat,
        isNested: Bool = false,
        onRelease: (() -> Void)?
    ) {
        releaseInstalledContent()
        releaseContent = onRelease

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // A row whose frame carries padding for a hover plate hangs that padding into the margin:
        // the transcript has one ink edge, and a plate reaching past it reads as a plate.
        overhang = (content as? OpticalInsetProviding)?.opticalHorizontalInset ?? 0
        let sideInset = Design.Chat.columnMargin - overhang
        indent = isNested ? Design.Chat.nestedRowIndent : 0

        // The pane's width leads and the readable column is a cap, never the other way round.
        //
        // A cell is not pinned to its column: under automatic row heights the table solves the
        // cell's own width from the constraints inside it, so a row that *asks* for the readable
        // measure gets it even where there is no room — the cell grows past the clip, taking the
        // words with it. Nothing announces that; the pane has no horizontal scroller, so the
        // sentences are simply cut mid-word at its edge. This shipped as a child transcript in
        // the display pane, which is routinely narrower than the column, rendering as clipped
        // paragraphs with an untouched gutter of pane behind them. Ordering the two the other
        // way had the same intent and only worked while the pane was wide enough to hide it.
        //
        // The cell's own width is stated by `setColumnWidth`; without it neither this nor the
        // centring below has a column to be a fraction of.
        let paneWidth = content.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -sideInset * 2 - indent
        )
        paneWidth.priority = .defaultHigh
        let measureCap = content.widthAnchor.constraint(
            lessThanOrEqualToConstant: (measure ?? Design.Chat.columnWidth) + overhang * 2 - indent
        )
        self.measureCap = measureCap

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            content.centerXAnchor.constraint(equalTo: centerXAnchor, constant: indent / 2),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: sideInset + indent),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -sideInset),
            measureCap,
            paneWidth
        ])
        if isNested { installSpine(leading: content.leadingAnchor, offset: overhang - indent) }
    }

    /// The rule a nested row hangs from. It runs the cell's full height, gap included, so one
    /// disclosure's rows draw one unbroken line down from it. Added after the content, which is
    /// what `playArrival` and the text selection find first.
    private func installSpine(leading: NSLayoutXAxisAnchor, offset: CGFloat) {
        let spine = NSView()
        spine.translatesAutoresizingMaskIntoConstraints = false
        spine.wantsLayer = true
        spine.applyLayerBackground(Design.Chat.turnDivider)
        addSubview(spine)
        NSLayoutConstraint.activate([
            spine.topAnchor.constraint(equalTo: topAnchor),
            spine.bottomAnchor.constraint(equalTo: bottomAnchor),
            spine.leadingAnchor.constraint(equalTo: leading, constant: offset),
            spine.widthAnchor.constraint(equalToConstant: Design.Chat.turnDividerHeight)
        ])
    }

    /// The entrance of a row that has just arrived at the live end: its picture fades in while
    /// rising `Design.Chat.arrivalRise` into place.
    ///
    /// Presentation only. The animation runs on the content's layer from a stated start to the
    /// model values Auto Layout already put there, so the row's frame, the table's measured
    /// height and the scroll that brings the row into view are all final from the first frame;
    /// nothing waits for the movement, and recycling the host mid-flight simply discards it.
    /// Under Reduce Motion there is no entrance at all.
    @discardableResult
    func playArrival() -> Bool {
        guard !Design.Motion.reducesMotion, let content = subviews.first else { return false }
        content.wantsLayer = true
        guard let layer = content.layer else { return false }
        // Toward the reply box: down the screen, whichever way this host's y axis runs.
        let below = isFlipped ? Design.Chat.arrivalRise : -Design.Chat.arrivalRise

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = below
        rise.toValue = 0

        let arrival = CAAnimationGroup()
        arrival.animations = [fade, rise]
        arrival.duration = Design.Motion.transcriptArrive
        arrival.timingFunction = Design.Motion.lift
        layer.add(arrival, forKey: ConversationRowDefaults.arrivalAnimationKey)
        return true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseInstalledContent()
    }

    private func releaseInstalledContent() {
        releaseContent?()
        releaseContent = nil
        subviews.forEach { $0.removeFromSuperview() }
    }
}
