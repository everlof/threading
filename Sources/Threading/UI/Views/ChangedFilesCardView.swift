import AppKit

/// The summary card a settled turn leaves behind: what it changed, as an indented tree.
///
/// t3code's per-turn changed-files card. The header carries the totals and the two actions —
/// Collapse all and View diff — and each directory row folds its own subtree. Small turns
/// open expanded (`ChangedFilesTree.autoExpands`); big ones start with every directory
/// folded, so a wide sweep is one line per top-level scope rather than forty rows in the
/// transcript. View diff opens Git Review on this card's immutable turn checkpoint, so older
/// cards remain accurate after later turns.
///
/// Resting on a file row shows that file's diff on a popover: the card names what changed, and
/// the preview answers the question the name raises without spending the pane on it.
final class ChangedFilesCardView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Properties

    private let tree: ChangedFilesTree
    private let previews: [String: ChangedFileDiffPreview]
    private let onViewDiff: () -> Void
    private let onHeightChange: () -> Void

    private var collapsedDirectories: Set<Int> = []
    /// The cheap projection the table presents. AppKit owns only cells intersecting the outer
    /// conversation viewport; folding changes this array rather than retaining and hiding views.
    private var presentedNodeIndices: [Int] = []
    private var tableIsBound = false
    private var rowsHeightConstraint: NSLayoutConstraint?

    /// The row the pointer is on, and the row the open preview belongs to. They differ while
    /// the pointer crosses from one file to the next, which is what swaps the preview over.
    private var hoveredNodeIndex: Int?
    private var previewedNodeIndex: Int?
    private var previewPopover: ThemedPopover?

    /// Decides when the preview opens and closes. It carries a scrollable diff, so the pointer
    /// has to be able to reach it: a grace to cross the gap, and the popover holds itself open
    /// while the pointer rests on it.
    private lazy var previewScheduler: HoverPopoverScheduler = {
        let scheduler = HoverPopoverScheduler(policy: ChangedFilesCardDefaults.previewPolicy)
        scheduler.onPresent = { [weak self] in self?.presentPreview() }
        scheduler.onDismiss = { [weak self] in self?.dismissPreview() }
        return scheduler
    }()

    private lazy var collapseButton = ThemedButton(
        title: "",
        target: self,
        action: #selector(toggleAll)
    )
    private lazy var viewDiffButton = ThemedButton(
        title: L10n.string("View diff"),
        target: self,
        action: #selector(viewDiff)
    )
    private lazy var rowsTable: ThemedTableView = {
        let table = ThemedTableView()
        let column = NSTableColumn(identifier: ChangedFilesCardDefaults.rowColumnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: Design.Spacing.hairline)
        table.rowHeight = ChangedFilesCardDefaults.rowHeight
        table.autoresizingMask = [.width]
        table.translatesAutoresizingMaskIntoConstraints = false
        return table
    }()

    // MARK: - Initialization

    init(
        tree: ChangedFilesTree,
        previews: [String: ChangedFileDiffPreview] = [:],
        onViewDiff: @escaping () -> Void,
        onHeightChange: @escaping () -> Void = {}
    ) {
        self.tree = tree
        self.previews = previews
        self.onViewDiff = onViewDiff
        self.onHeightChange = onHeightChange
        super.init(frame: .zero)

        if !tree.autoExpands {
            collapsedDirectories = allDirectoryIndices
        }
        rebuildPresentedNodes()
        setupViews()
        updateCollapseButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// The preview a file row raises, built apart from the pointer that asks for it so it can
    /// be drawn and asserted without a live popover over a window on screen.
    func makePreviewSurface(for preview: ChangedFileDiffPreview) -> NSViewController {
        ChangedFileDiffViewController(preview: preview) { [weak self] hovering in
            self?.previewScheduler.popoverHoverChanged(hovering)
        }
    }

    /// The bounded diff a row would show, or nil where there is nothing to show — a directory,
    /// a file the card was given no diff for, or a binary one.
    func preview(forNodeAt index: Int) -> ChangedFileDiffPreview? {
        guard tree.nodes.indices.contains(index) else { return nil }
        let node = tree.nodes[index]
        guard !node.isDirectory, let preview = previews[node.path], !preview.isEmpty else {
            return nil
        }
        return preview
    }

    /// Cheap logical rows and currently materialized AppKit cells, kept separate so stress tests
    /// can assert the ownership boundary rather than merely timing it.
    var presentedNodeCountForTesting: Int { presentedNodeIndices.count }
    var materializedRowCountForTesting: Int {
        materializedNodeIndicesForTesting.count
    }
    var materializedNodeIndicesForTesting: [Int] {
        var indices: [Int] = []
        rowsTable.enumerateAvailableRowViews { [rowsTable] _, tableRow in
            if let cell = rowsTable.view(
                atColumn: 0,
                row: tableRow,
                makeIfNecessary: false
            ) as? ChangedFilesRowView, cell.nodeIndex >= 0 {
                indices.append(cell.nodeIndex)
            }
        }
        return indices
    }

    // MARK: - Setup

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Surface.panel, radius: .control)

        let title = NSTextField(labelWithString: summaryText())
        title.applyFont(.caption, in: .conversation)
        title.textColor = Design.Text.secondary
        title.translatesAutoresizingMaskIntoConstraints = false

        let counts = NSTextField.label(attributed: Self.countText(
            added: tree.added,
            removed: tree.removed
        ))
        counts.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [title, counts, spacer, collapseButton, viewDiffButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Design.Spacing.small
        header.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(rowsTable)

        let inset = Design.Spacing.medium
        let rowsHeight = rowsTable.heightAnchor.constraint(equalToConstant: presentedRowsHeight)
        rowsHeightConstraint = rowsHeight
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            rowsTable.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.Spacing.small),
            rowsTable.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            rowsTable.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            rowsTable.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            rowsHeight
        ])

        // Small cards are the ordinary case and are safe to bind while detached. A pathological
        // set of root-level files has no directory to fold; wait until the card is under the
        // conversation clip before asking AppKit for that table, or detached construction sees
        // the table's whole height as visible and eagerly requests every cell.
        bindTableIfNeeded(force: presentedNodeIndices.count <= ChangedFilesCardDefaults.eagerRowCap)
    }

    private func summaryText() -> String {
        tree.fileCount == 1 ? "1 changed file" : "\(tree.fileCount) changed files"
    }

    private var presentedRowsHeight: CGFloat {
        guard !presentedNodeIndices.isEmpty else { return 0 }
        return CGFloat(presentedNodeIndices.count) * ChangedFilesCardDefaults.rowStride
            - rowsTable.intercellSpacing.height
    }

    private var allDirectoryIndices: Set<Int> {
        Set(tree.nodes.indices.filter { tree.nodes[$0].isDirectory })
    }

    private func bindTableIfNeeded(force: Bool) {
        guard !tableIsBound, force else { return }
        tableIsBound = true
        rowsTable.delegate = self
        rowsTable.dataSource = self
        rowsTable.reloadData()
    }

    // MARK: - Collapsing

    private func toggleDirectory(at index: Int) {
        guard tree.nodes.indices.contains(index), tree.nodes[index].isDirectory else { return }
        if collapsedDirectories.contains(index) {
            collapsedDirectories.remove(index)
        } else {
            collapsedDirectories.insert(index)
        }
        applyCollapseState()
        updateCollapseButton()
    }

    @objc private func toggleAll() {
        let allDirectories = allDirectoryIndices
        if collapsedDirectories == allDirectories {
            collapsedDirectories.removeAll()
        } else {
            collapsedDirectories = allDirectories
        }
        applyCollapseState()
        updateCollapseButton()
    }

    @objc private func viewDiff() {
        onViewDiff()
    }

    /// A row is presented iff no ancestor directory is collapsed. One pre-order pass produces
    /// the table model; no AppKit object is created for rows outside the outer scroll viewport.
    private func applyCollapseState() {
        rebuildPresentedNodes()
        rowsHeightConstraint?.constant = presentedRowsHeight
        if tableIsBound { rowsTable.reloadData() }

        // A row that just folded away cannot go on describing what the pointer is over.
        if let previewedNodeIndex, !presentedNodeIndices.contains(previewedNodeIndex) {
            dismissPreview()
        }
        onHeightChange()
    }

    private func rebuildPresentedNodes() {
        presentedNodeIndices.removeAll(keepingCapacity: true)
        presentedNodeIndices.reserveCapacity(tree.nodes.count)
        var hiddenBelowDepth: Int?

        for (index, node) in tree.nodes.enumerated() {
            if let depth = hiddenBelowDepth, node.depth <= depth {
                hiddenBelowDepth = nil
            }
            guard hiddenBelowDepth == nil else { continue }

            presentedNodeIndices.append(index)
            if node.isDirectory, collapsedDirectories.contains(index) {
                hiddenBelowDepth = node.depth
            }
        }
    }

    private func updateCollapseButton() {
        let allDirectories = allDirectoryIndices
        let allCollapsed = !allDirectories.isEmpty && collapsedDirectories == allDirectories
        collapseButton.title = allCollapsed ? "Expand all" : "Collapse all"
        collapseButton.isHidden = allDirectories.isEmpty
    }

    // MARK: - Diff Preview

    private func hoverChanged(_ hovering: Bool, atNodeIndex index: Int) {
        if hovering {
            hoveredNodeIndex = index
            previewScheduler.pointerEntered()
        } else if hoveredNodeIndex == index {
            hoveredNodeIndex = nil
            previewScheduler.pointerExited()
        }
    }

    private func presentPreview() {
        guard let index = hoveredNodeIndex,
              let presentedRow = presentedNodeIndices.firstIndex(of: index),
              let row = rowsTable.view(
                atColumn: 0,
                row: presentedRow,
                makeIfNecessary: false
              ) as? ChangedFilesRowView,
              let preview = preview(forNodeAt: index),
              window != nil else { return }

        // Asked of the popover rather than of the reference held to it: a dropdown opening in
        // this window closes the preview out from under the row (see
        // `ThemedPopover.closeAll(presentedFrom:)`), and a stale reference would read as one
        // still showing. A preview belonging to the row the pointer has *left* is replaced.
        if previewPopover?.isShown == true {
            guard previewedNodeIndex != index else { return }
            previewPopover?.close()
        }

        let content = HostPopoverFactory.make(.conversationChangedFileDiff)
        // Closed by hand on exit, so a click in the conversation under it is not what dismisses
        // a surface the pointer is still holding open.
        content.behavior = .applicationDefined
        content.animates = false
        content.contentViewController = makePreviewSurface(for: preview)
        content.show(relativeTo: row.bounds, of: row, preferredEdge: .maxX)

        previewPopover = content
        previewedNodeIndex = index
    }

    private func dismissPreview() {
        previewScheduler.cancelPendingWork()
        previewPopover?.close()
        previewPopover = nil
        previewedNodeIndex = nil
    }

    /// A conversation row can be discarded without the pointer ever leaving it; a preview
    /// anchored to a card that left the window would keep floating over nothing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !tableIsBound {
            // The outer conversation table commits this retained row's final frame on the next
            // turn. Bind behind that layout so `visibleRect` is the clip viewport, not the full
            // logical height of a detached table.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.bindTableIfNeeded(force: true)
            }
        } else if window == nil {
            hoveredNodeIndex = nil
            dismissPreview()
        }
    }

    /// `+N −M` in the diff roles and the caption face — the same reading, in the same voice,
    /// as Git Review's file rows.
    static func countText(added: Int, removed: Int) -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "+\(added)", attributes: [
            .foregroundColor: Design.Diff.added,
            .font: Design.Typography.caption()
        ]))
        text.append(NSAttributedString(string: " −\(removed)", attributes: [
            .foregroundColor: Design.Diff.removed,
            .font: Design.Typography.caption()
        ]))
        return text
    }

    // MARK: - Virtual Rows

    func numberOfRows(in tableView: NSTableView) -> Int {
        presentedNodeIndices.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row presentedRow: Int
    ) -> NSView? {
        guard presentedNodeIndices.indices.contains(presentedRow) else { return nil }
        let nodeIndex = presentedNodeIndices[presentedRow]
        let node = tree.nodes[nodeIndex]
        let row = tableView.makeView(
            withIdentifier: ChangedFilesCardDefaults.rowIdentifier,
            owner: self
        ) as? ChangedFilesRowView ?? ChangedFilesRowView()
        row.identifier = ChangedFilesCardDefaults.rowIdentifier
        row.configure(
            nodeIndex: nodeIndex,
            node: node,
            collapsed: collapsedDirectories.contains(nodeIndex),
            hasPreview: previews[node.path]?.isEmpty == false,
            onToggle: { [weak self] in self?.toggleDirectory(at: nodeIndex) },
            onHoverChange: { [weak self] hovering in
                self?.hoverChanged(hovering, atNodeIndex: nodeIndex)
            }
        )
        return row
    }
}

// MARK: - Changed Files Row View

/// One row of the tree, owning the pointer that rests on it.
///
/// The wash is the row's own rather than the card's: the preview hangs off *this* row, and a
/// highlight drawn by whatever happens to be presenting would go stale the moment the tree
/// folds under it.
final class ChangedFilesRowView: NSTableCellView {

    private(set) var nodeIndex = -1

    /// Whether the row answers the pointer at all. A directory folds and a file with a diff
    /// previews it, so both light up; a file the card holds no diff for does nothing when it is
    /// pointed at, and a wash promising otherwise is the row lying about itself.
    var tracksPointer = false

    /// Set on rows with something to preview.
    var onHoverChange: ((Bool) -> Void)?
    private var onToggle: (() -> Void)?

    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let chevron = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private lazy var chevronLeading = chevron.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var nameLeading = nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var clickRecognizer = NSClickGestureRecognizer(
        target: self,
        action: #selector(clicked)
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentTintColor = Design.Text.quaternary
        chevron.symbolConfiguration = Design.Symbol.configuration(
            Design.Symbol.chevron,
            weight: .semibold
        )

        nameLabel.applyFont(.code(), in: .conversation)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.usesSingleLineMode = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        countsLabel.translatesAutoresizingMaskIntoConstraints = false
        countsLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(chevron)
        addSubview(nameLabel)
        addSubview(countsLabel)
        addGestureRecognizer(clickRecognizer)

        NSLayoutConstraint.activate([
            chevronLeading,
            chevron.widthAnchor.constraint(equalToConstant: ChangedFilesCardDefaults.markWidth),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLeading,
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.hairline),
            nameLabel.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Design.Spacing.hairline
            ),

            countsLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameLabel.trailingAnchor,
                constant: Design.Spacing.small
            ),
            countsLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            countsLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor)
        ])
    }

    func configure(
        nodeIndex: Int,
        node: ChangedFilesTree.Node,
        collapsed: Bool,
        hasPreview: Bool,
        onToggle: @escaping () -> Void,
        onHoverChange: @escaping (Bool) -> Void
    ) {
        setHovered(false)
        self.nodeIndex = nodeIndex
        self.onToggle = node.isDirectory ? onToggle : nil
        self.onHoverChange = hasPreview ? onHoverChange : nil
        tracksPointer = node.isDirectory || hasPreview
        clickRecognizer.isEnabled = node.isDirectory

        let indent = CGFloat(node.depth) * ChangedFilesCardDefaults.indentStep
        chevronLeading.constant = indent
        nameLeading.constant = indent + ChangedFilesCardDefaults.markColumn
        chevron.isHidden = !node.isDirectory
        chevron.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil
        )
        nameLabel.stringValue = node.name
        nameLabel.textColor = node.isDirectory ? Design.Text.secondary : Design.Text.label
        countsLabel.attributedStringValue = ChangedFilesCardView.countText(
            added: node.added,
            removed: node.removed
        )

        setAccessibilityRole(node.isDirectory ? .disclosureTriangle : .row)
        setAccessibilityLabel(node.name)
        setAccessibilityExpanded(node.isDirectory && !collapsed)
        applyHoverBackground()
        updateTrackingAreas()
    }

    @objc private func clicked() {
        onToggle?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHovered(false)
        nodeIndex = -1
        tracksPointer = false
        onHoverChange = nil
        onToggle = nil
        clickRecognizer.isEnabled = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard tracksPointer else { return }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area

        // The conversation scrolls and the tree folds under a still pointer, and neither
        // delivers an exit — see `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) { setHovered(false) }
    }

    override func mouseEntered(with event: NSEvent) {
        // Not through a surface floating over the conversation — see
        // `NSView.isPointerCovered(at:)`.
        guard !isPointerCovered(at: event.locationInWindow) else { return }
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }

    /// Exposed so the hover state can be driven without a pointer on a real screen.
    func setHovered(_ hovered: Bool) {
        guard tracksPointer, hovered != isHovered else { return }
        isHovered = hovered
        applyHoverBackground()
        onHoverChange?(hovered)
    }

    private func applyHoverBackground() {
        applySurface(
            fill: isHovered ? Design.Chat.toolRowActive : Design.Chat.toolRowResting,
            radius: .control
        )
    }
}

// MARK: - Changed File Diff View Controller

/// One file's diff on a popover: the path and its ±counts, then the change itself, scrolling
/// once it outgrows the height a hover surface should have.
///
/// The renderer is Git Review's — one TextKit document per hunk rather than a view per line —
/// because the file under the pointer is as likely to be a four-hundred-line rewrite as a
/// two-line fix, and a preview that costs hundreds of views to open is a preview that stutters
/// every time the pointer crosses the tree.
final class ChangedFileDiffViewController: NSViewController {

    private let preview: ChangedFileDiffPreview
    private let onHoverChange: (Bool) -> Void

    /// The rendered hunks and the viewport they measure themselves against. A diff states its
    /// height for the width it was given, and the width it is *given* is not the one it was
    /// built at wherever the reader has legacy scrollers turned on — a wrapped line more than
    /// it measured for is a line clipped off the bottom.
    private var diffViews: [GitReviewDiffTextView] = []
    private weak var scrollView: ThemedScrollView?

    init(preview: ChangedFileDiffPreview, onHoverChange: @escaping (Bool) -> Void) {
        self.preview = preview
        self.onHoverChange = onHoverChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // The pointer bridge: the card's policy holds the preview open while the pointer rests
        // on it, so crossing the gap from the row does not lose the thing being read.
        let container = HoverTrackingView()
        container.onHoverChange = onHoverChange
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let document = makeDocument()

        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scrollView = scroll

        container.addSubview(header)
        container.addSubview(scroll)

        let inset = Design.Spacing.medium
        let height = scroll.heightAnchor.constraint(
            lessThanOrEqualToConstant: ChangedFilesCardDefaults.previewMaximumHeight
        )
        let fits = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        fits.priority = .defaultHigh

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(
                equalToConstant: ChangedFilesCardDefaults.previewContentWidth + 2 * inset
            ),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.Spacing.small),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),

            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            height,
            fits
        ])

        container.setAccessibilityIdentifier("conversation.changed-file-diff")
        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let width = scrollView?.contentView.bounds.width, width > 1 else { return }
        // `fit` is a no-op at a width already measured, so this settles rather than looping.
        diffViews.forEach { $0.fit(toWidth: width) }
    }

    // MARK: - Private Methods

    private func makeHeader() -> NSView {
        let path = NSTextField(labelWithString: preview.path)
        path.applyFont(.code(), in: .conversation)
        path.textColor = Design.Text.secondary
        path.lineBreakMode = .byTruncatingMiddle
        path.usesSingleLineMode = true
        path.translatesAutoresizingMaskIntoConstraints = false
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let counts = NSTextField.label(attributed: ChangedFilesCardView.countText(
            added: preview.added,
            removed: preview.removed
        ))
        counts.translatesAutoresizingMaskIntoConstraints = false
        counts.setContentHuggingPriority(.required, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [path, counts])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = Design.Spacing.small
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    /// The hunks, each under its own `@@` line, and a closing note for whatever the capture cap
    /// left out.
    private func makeDocument() -> NSStackView {
        let document = NSStackView()
        document.orientation = .vertical
        document.alignment = .leading
        document.spacing = Design.Spacing.small
        document.translatesAutoresizingMaskIntoConstraints = false

        for hunk in preview.hunks where !hunk.lines.isEmpty {
            if preview.hunks.count > 1 {
                addRow(makeNote(hunk.header), to: document)
            }
            let diff = GitReviewDiffTextView(
                gitLines: hunk.lines,
                displayCap: hunk.lines.count,
                path: preview.path,
                wraps: true,
                initialLayoutWidth: ChangedFilesCardDefaults.previewContentWidth
            )
            diffViews.append(diff)
            addRow(diff, to: document)
        }

        if preview.omittedLines > 0 {
            addRow(makeNote("… \(preview.omittedLines) more lines"), to: document)
        }

        return document
    }

    private func addRow(_ view: NSView, to document: NSStackView) {
        document.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: document.trailingAnchor)
        ])
    }

    private func makeNote(_ text: String) -> NSTextField {
        let note = NSTextField(labelWithString: text)
        note.applyFont(.code(), in: .conversation)
        note.textColor = Design.Text.tertiary
        note.lineBreakMode = .byTruncatingTail
        note.usesSingleLineMode = true
        note.translatesAutoresizingMaskIntoConstraints = false
        return note
    }
}

// MARK: - Changed Files Card Defaults

@MainActor
enum ChangedFilesCardDefaults {
    static let rowColumnIdentifier = NSUserInterfaceItemIdentifier("ChangedFilesColumn")
    static let rowIdentifier = NSUserInterfaceItemIdentifier("ChangedFilesRow")

    /// Detached construction may bind this many ordinary rows immediately. Larger flat-root
    /// trees wait until they are clipped by the conversation viewport, or AppKit correctly sees
    /// their entire detached bounds as visible and asks for every cell at once.
    static let eagerRowCap = 32

    static var rowHeight: CGFloat {
        Design.Typography.lineHeight(of: Design.FontRole.code().resolved(in: .conversation))
            + 2 * Design.Spacing.hairline
    }

    static var rowStride: CGFloat { rowHeight + Design.Spacing.hairline }

    /// Indentation per tree level. One `Spacing.medium` step, which beside the chevron column
    /// reads as containment without spending a fifth of a narrow pane on the tree's left edge.
    static let indentStep: CGFloat = Design.Spacing.medium

    /// The disclosure column. The chevron is `Design.Symbol.chevron`, an 8pt hint, so the
    /// column it sits in is measured for that glyph rather than for a control's slot.
    static let markWidth: CGFloat = Design.Spacing.medium
    static let markSpacing: CGFloat = Design.Spacing.small

    /// What every row spends before its name — the chevron's column and the gap after it.
    static var markColumn: CGFloat { markWidth + markSpacing }

    /// The hover preview's content width: wide enough for ordinary source at the code face
    /// without becoming a second pane floating over the first.
    static let previewContentWidth: CGFloat = 520

    /// Past this the preview scrolls. A hover surface is a reading, not a page.
    static let previewMaximumHeight: CGFloat = 320

    /// Dwell before the preview opens, so it does not flash while the pointer crosses the tree
    /// on its way somewhere else, then a grace to cross the gap into a surface that scrolls.
    static let previewPolicy = HoverPopoverScheduler.Policy(
        openDelay: SessionPopoverDefaults.hoverDelay,
        closeGrace: ExtensionDisclosureDefaults.popoverPolicy.closeGrace,
        holdsWhilePointerOnPopover: true
    )
}
