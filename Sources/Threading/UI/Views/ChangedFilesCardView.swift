import AppKit

/// The summary card a settled turn leaves behind: what it changed, as an indented tree.
///
/// t3code's per-turn changed-files card. The header carries the totals and the two actions —
/// Collapse all and View diff — and each directory row folds its own subtree. Small turns
/// open expanded (`ChangedFilesTree.autoExpands`); big ones start with every directory
/// folded, so a wide sweep is one line per top-level scope rather than forty rows in the
/// transcript. View diff opens Git Review's Last Turn scope, so it is offered only while
/// this card is the latest turn's — an older card's diff is no longer what that scope shows.
///
/// Resting on a file row shows that file's diff on a popover: the card names what changed, and
/// the preview answers the question the name raises without spending the pane on it.
final class ChangedFilesCardView: NSView {

    // MARK: - Properties

    private let tree: ChangedFilesTree
    private let previews: [String: ChangedFileDiffPreview]
    private let onViewDiff: () -> Void

    private var rowsByNodeIndex: [Int: ChangedFilesRowView] = [:]
    private var chevronsByNodeIndex: [Int: NSImageView] = [:]
    private var collapsedDirectories: Set<Int> = []

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
    private lazy var rowsStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // MARK: - Initialization

    init(
        tree: ChangedFilesTree,
        previews: [String: ChangedFileDiffPreview] = [:],
        onViewDiff: @escaping () -> Void
    ) {
        self.tree = tree
        self.previews = previews
        self.onViewDiff = onViewDiff
        super.init(frame: .zero)
        setupViews()

        if !tree.autoExpands { collapseAll() }
        updateCollapseButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// A newer turn settled: Last Turn no longer shows this card's diff, so the door closes.
    func hideViewDiff() {
        viewDiffButton.isHidden = true
    }

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

        for (index, node) in tree.nodes.enumerated() {
            let row = makeRow(for: node, at: index)
            rowsByNodeIndex[index] = row
            rowsStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor)
            ])
        }

        addSubview(header)
        addSubview(rowsStack)

        let inset = Design.Spacing.medium
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            rowsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.Spacing.small),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }

    private func summaryText() -> String {
        tree.fileCount == 1 ? "1 changed file" : "\(tree.fileCount) changed files"
    }

    /// One row: indentation, a chevron for directories, the name, and the subtree's ±counts at
    /// the trailing edge.
    private func makeRow(for node: ChangedFilesTree.Node, at index: Int) -> ChangedFilesRowView {
        let row = ChangedFilesRowView(nodeIndex: index)
        row.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: node.name)
        name.applyFont(.code(), in: .conversation)
        name.textColor = node.isDirectory ? Design.Text.secondary : Design.Text.label
        name.lineBreakMode = .byTruncatingMiddle
        name.usesSingleLineMode = true
        name.translatesAutoresizingMaskIntoConstraints = false

        let counts = NSTextField.label(attributed: Self.countText(
            added: node.added,
            removed: node.removed
        ))
        counts.translatesAutoresizingMaskIntoConstraints = false
        counts.setContentHuggingPriority(.required, for: .horizontal)

        // Directory rows spend a chevron on their lead-in; file rows skip it but *pay for it
        // anyway*, so a directory's files start exactly one indent step right of its own name
        // rather than drifting left of it. One column, not two: a folder mark beside every
        // chevron said what the chevron already said, and charged every row in the tree the
        // width of a second glyph to say it.
        let indent = CGFloat(node.depth) * ChangedFilesCardDefaults.indentStep
        let nameLeading = indent + ChangedFilesCardDefaults.markColumn

        if node.isDirectory {
            let chevron = NSImageView()
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.image = Self.chevronImage(collapsed: false)
            chevron.contentTintColor = Design.Text.quaternary
            chevron.symbolConfiguration = Design.Symbol.configuration(
                Design.Symbol.chevron,
                weight: .semibold
            )
            chevronsByNodeIndex[index] = chevron

            row.addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
                chevron.widthAnchor.constraint(
                    equalToConstant: ChangedFilesCardDefaults.markWidth
                ),
                chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])

            row.setAccessibilityRole(.disclosureTriangle)
            row.setAccessibilityLabel(node.name)
            row.tracksPointer = true

            let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
            row.addGestureRecognizer(click)
        } else if previews[node.path]?.isEmpty == false {
            row.tracksPointer = true
            row.onHoverChange = { [weak self] hovering in
                self?.hoverChanged(hovering, atNodeIndex: index)
            }
        }

        row.addSubview(name)
        row.addSubview(counts)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: nameLeading),
            name.topAnchor.constraint(equalTo: row.topAnchor, constant: Design.Spacing.hairline),
            name.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Design.Spacing.hairline),

            counts.leadingAnchor.constraint(
                greaterThanOrEqualTo: name.trailingAnchor,
                constant: Design.Spacing.small
            ),
            counts.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            counts.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor)
        ])

        return row
    }

    // MARK: - Collapsing

    @objc private func rowClicked(_ gesture: NSClickGestureRecognizer) {
        guard let row = gesture.view as? ChangedFilesRowView else { return }
        let index = row.nodeIndex
        if collapsedDirectories.contains(index) {
            collapsedDirectories.remove(index)
        } else {
            collapsedDirectories.insert(index)
        }
        applyCollapseState()
        updateCollapseButton()
    }

    @objc private func toggleAll() {
        let allDirectories = Set(tree.nodes.indices.filter { tree.nodes[$0].isDirectory })
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

    private func collapseAll() {
        collapsedDirectories = Set(tree.nodes.indices.filter { tree.nodes[$0].isDirectory })
        applyCollapseState()
    }

    /// A row is visible iff no ancestor directory is collapsed. Hidden arranged views detach
    /// from the stack, so the card's height follows.
    private func applyCollapseState() {
        var hidden = Set<Int>()
        for index in collapsedDirectories {
            hidden.formUnion(tree.descendantIndices(of: index))
        }
        for (index, row) in rowsByNodeIndex {
            row.isHidden = hidden.contains(index)
        }
        for (index, chevron) in chevronsByNodeIndex {
            chevron.image = Self.chevronImage(collapsed: collapsedDirectories.contains(index))
            rowsByNodeIndex[index]?.setAccessibilityExpanded(!collapsedDirectories.contains(index))
        }
        // A row that just folded away cannot go on describing what the pointer is over.
        if let previewedNodeIndex, hidden.contains(previewedNodeIndex) {
            dismissPreview()
        }
    }

    private func updateCollapseButton() {
        let allDirectories = Set(tree.nodes.indices.filter { tree.nodes[$0].isDirectory })
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
              let row = rowsByNodeIndex[index], !row.isHidden,
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
        if window == nil {
            hoveredNodeIndex = nil
            dismissPreview()
        }
    }

    // MARK: - Private Methods

    private static func chevronImage(collapsed: Bool) -> NSImage? {
        NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil
        )
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
}

// MARK: - Changed Files Row View

/// One row of the tree, owning the pointer that rests on it.
///
/// The wash is the row's own rather than the card's: the preview hangs off *this* row, and a
/// highlight drawn by whatever happens to be presenting would go stale the moment the tree
/// folds under it.
final class ChangedFilesRowView: NSView {

    let nodeIndex: Int

    /// Whether the row answers the pointer at all. A directory folds and a file with a diff
    /// previews it, so both light up; a file the card holds no diff for does nothing when it is
    /// pointed at, and a wash promising otherwise is the row lying about itself.
    var tracksPointer = false

    /// Set on rows with something to preview.
    var onHoverChange: ((Bool) -> Void)?

    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(nodeIndex: Int) {
        self.nodeIndex = nodeIndex
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

enum ChangedFilesCardDefaults {
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
