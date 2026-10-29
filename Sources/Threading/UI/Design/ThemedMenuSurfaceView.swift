import AppKit

/// The live menu panel and document, shared by macOS and Linux hosts.
final class ThemedMenuSurfaceView: ThemedMenuPanelView {

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onHighlight: ((Int) -> Void)?
    /// The panel scrolled under its rows — what tells an open submenu its anchor moved.
    var onScrolled: (() -> Void)?
    /// A press landed on this panel, on a row or on the ground between them.
    var onPressBegan: ((NSEvent) -> Void)?

    let selectableIndices: [Int]

    private let scrollView = ThemedScrollView()
    private let document: ThemedMenuDocumentView
    private let rows: [Int: ThemedMenuRowView]
    // NotificationCenter removes this token during nonisolated deinitialization. The callback
    // itself re-enters the main actor before touching menu state.
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
    private var isRetiredFromAccessibility = false
    /// Echoes what has been typed, in the strip the filter opens across the panel's top —
    /// without it, typing visibly does nothing until a row happens to dim.
    private let filterLabel = NSTextField(labelWithString: "")

    init(
        frame: NSRect,
        entries: [ThemedMenuEntry],
        selectedEntryIndex: Int?
    ) {
        let entries = ThemedMenuMetrics.entries(
            entries, fitting: frame.width, selectedEntryIndex: selectedEntryIndex
        )
        var madeRows: [Int: ThemedMenuRowView] = [:]
        var views: [NSView] = []
        var selectable: [Int] = []
        let rowPlan = ThemedMenuRowPlan(entries: entries, selectedEntryIndex: selectedEntryIndex)

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                views.append(ThemedMenuSeparatorView())
            case .header(let title):
                views.append(ThemedMenuHeaderView(title: title))
            case .item(let item):
                guard let row = rowPlan.row(at: index) else { continue }
                madeRows[index] = row
                views.append(row)
                if item.isEnabled { selectable.append(index) }
            }
        }

        rows = madeRows
        selectableIndices = selectable
        document = ThemedMenuDocumentView(views: views, heights: rowPlan.heights)
        super.init(frame: frame)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller =
            document.naturalHeight > frame.height - ThemedMenuMetrics.verticalOuterInset * 2
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        addSubview(scrollView)

        filterLabel.applyFont(.detail())
        filterLabel.textColor = Design.Text.secondary
        filterLabel.lineBreakMode = .byTruncatingHead
        filterLabel.isHidden = true
        addSubview(filterLabel)

        for row in rows.values {
            row.onChoose = { [weak self] index, item in self?.onChoose?(index, item) }
            row.onHighlight = { [weak self] index in self?.onHighlight?(index) }
            row.onPressBegan = { [weak self] event in self?.onPressBegan?(event) }
        }
        // Scrolling moves every row under any submenu anchored to one of them; the overlay
        // listens and closes what no longer lines up.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScrolled?() }
        }
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    /// Ends the semantic menu synchronously while its already-drawn pixels finish fading.
    /// `setAccessibilityRole(nil)` is not a removal operation in AppKit: it restores the
    /// receiver's inferred/default role, which leaves this surface reporting `.menu`. Mark the
    /// whole subtree hidden and non-element, and have the role getter return nil once retired so
    /// direct inspection cannot mistake the visual afterimage for a live menu.
    func retireFromAccessibility() {
        isRetiredFromAccessibility = true
        setAccessibilityHidden(true)
        setAccessibilityElement(false)
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        isRetiredFromAccessibility ? nil : .menu
    }
    override func isAccessibilityElement() -> Bool { !isRetiredFromAccessibility }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Wider at the ends than at the sides under a broad corner — see `verticalOuterInset`.
        let inset = ThemedMenuMetrics.outerInset
        var content = bounds.insetBy(dx: inset, dy: ThemedMenuMetrics.verticalOuterInset)
        if ThemedMenuMetrics.appearance == .platinum {
            // The menu's one-pixel hard shadow is outside the bordered panel on the trailing
            // edge. A symmetric inset gave the document that shadow column and separators
            // painted across the black containment rule at x = width - 2.
            content.size.width = max(0, content.width - 1)
        }
        if !filterLabel.isHidden {
            let header = ThemedMenuMetrics.filterHeaderHeight
            let labelHeight = ceil(filterLabel.font?.boundingRectForFont.height ?? header)
            filterLabel.frame = NSRect(
                x: content.minX + ThemedMenuMetrics.contentInset,
                y: content.maxY - header + (header - labelHeight) / 2,
                width: max(0, content.width - ThemedMenuMetrics.contentInset * 2),
                height: labelHeight
            )
            content.size.height -= header
        }
        scrollView.frame = content
        document.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: max(document.naturalHeight, scrollView.contentSize.height)
        )
        document.needsLayout = true
    }

    func highlight(_ index: Int?, scrollIntoView: Bool = true) {
        for (entryIndex, row) in rows {
            row.isKeyboardHighlighted = entryIndex == index
        }
        if scrollIntoView, let row = row(at: index) {
            row.scrollToVisible(row.bounds)
        }
    }

    func row(at index: Int?) -> ThemedMenuRowView? {
        index.flatMap { rows[$0] }
    }

    /// The enabled row whose shortcut is `event`, in stable menu order. A dictionary walk here
    /// would make duplicate chords choose nondeterministically; menu order is the tie-breaker a
    /// person can see.
    func row(matchingShortcut event: NSEvent) -> ThemedMenuRowView? {
        for index in selectableIndices {
            guard let row = rows[index], row.item.resolvedShortcut?.matches(event) == true else {
                continue
            }
            return row
        }
        return nil
    }

    /// The row under a point given in window coordinates — the press-drag-release lookup.
    /// Per-row conversion, so a scrolled document answers correctly.
    func row(underWindowPoint point: NSPoint) -> ThemedMenuRowView? {
        rows.values.first { row in
            row.bounds.contains(row.convert(point, from: nil))
        }
    }

    // MARK: - Filtering

    func applyFilter(_ query: String) {
        for row in rows.values {
            row.isFilteredOut = !query.isEmpty && !Self.matches(row.item, query)
        }
        filterLabel.stringValue = L10n.format("Filter: %@", query)
        filterLabel.isHidden = query.isEmpty
        needsLayout = true
    }

    func selectableIndices(matching query: String) -> [Int] {
        guard !query.isEmpty else { return selectableIndices }
        return selectableIndices.filter { index in
            guard let row = rows[index] else { return false }
            return Self.matches(row.item, query)
        }
    }

    private static func matches(_ item: ThemedMenuItem, _ query: String) -> Bool {
        item.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// A section head: the name of the group under it, choosing nothing.
///
/// Drawn rather than hosted for the same reason the rows are — the panel places its children by
/// frame — and read as a heading by accessibility so a screen reader announces the group before
/// its logins instead of leaving them an undifferentiated run of names.
final class ThemedMenuHeaderView: NSView, ThemedComponent {

    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // The rows' own text column, so the head sits over the names it introduces rather than
        // over the checkmark gutter in front of them.
        let font = ThemedMenuMetrics.headerFont
        let height = Design.Typography.lineHeight(of: font)
        (title as NSString).draw(
            in: NSRect(
                x: ThemedMenuMetrics.contentInset,
                y: bounds.maxY - ThemedMenuMetrics.headerTopInset - height / 2
                    - ThemedMenuMetrics.titleBaselineOffset,
                width: max(0, bounds.width - ThemedMenuMetrics.contentInset * 2),
                height: height
            ),
            withAttributes: [
                .font: font,
                .foregroundColor: Design.Text.tertiary,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.lineBreakMode = .byTruncatingTail
                    return style
                }()
            ]
        )
    }
}
