import AppKit

/// The summary card a settled turn leaves behind: what it changed, as an indented tree.
///
/// t3code's per-turn changed-files card. The header carries the totals and the two actions —
/// Collapse all and View diff — and each directory row folds its own subtree. Small turns
/// open expanded (`ChangedFilesTree.autoExpands`); big ones start with every directory
/// folded, so a wide sweep is one line per top-level scope rather than forty rows in the
/// transcript. View diff opens Git Review's Last Turn scope, so it is offered only while
/// this card is the latest turn's — an older card's diff is no longer what that scope shows.
final class ChangedFilesCardView: NSView {

    // MARK: - Properties

    private let tree: ChangedFilesTree
    private let onViewDiff: () -> Void

    private var rowsByNodeIndex: [Int: NSView] = [:]
    private var chevronsByNodeIndex: [Int: NSImageView] = [:]
    private var collapsedDirectories: Set<Int> = []

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

    init(tree: ChangedFilesTree, onViewDiff: @escaping () -> Void) {
        self.tree = tree
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

    /// One row: indentation, a chevron and folder mark for directories, the name, and the
    /// subtree's ±counts at the trailing edge.
    private func makeRow(for node: ChangedFilesTree.Node, at index: Int) -> NSView {
        let row = NSView()
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

        // Directory rows spend a chevron-and-folder lead-in before their name; file rows skip
        // it but *pay for it anyway*, so a directory's files start exactly one indent step
        // right of its own name rather than drifting left of it. Fixed-width symbol columns —
        // an SF symbol's intrinsic width varies by glyph, and alignment by ink means the
        // names line up, not the images' happenstance edges.
        let markWidth = Design.Chat.toolIconWidth + Design.Spacing.tight
        let indent = Design.Spacing.inset + CGFloat(node.depth) * ChangedFilesCardDefaults.indentStep
        let nameLeading = indent + markWidth * 2

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

            let folder = NSImageView()
            folder.translatesAutoresizingMaskIntoConstraints = false
            folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            folder.contentTintColor = Design.Text.tertiary

            row.addSubview(chevron)
            row.addSubview(folder)
            NSLayoutConstraint.activate([
                chevron.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
                chevron.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),
                chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),

                folder.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: Design.Spacing.tight),
                folder.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),
                folder.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])

            row.setAccessibilityRole(.disclosureTriangle)
            row.setAccessibilityLabel(node.name)

            let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
            row.addGestureRecognizer(click)
            rowTags[ObjectIdentifier(row)] = index
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

    /// Row → node index for the click handler; gesture recognizers carry no payload.
    private var rowTags: [ObjectIdentifier: Int] = [:]

    // MARK: - Collapsing

    @objc private func rowClicked(_ gesture: NSClickGestureRecognizer) {
        guard let row = gesture.view, let index = rowTags[ObjectIdentifier(row)] else { return }
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
    }

    private func updateCollapseButton() {
        let allDirectories = Set(tree.nodes.indices.filter { tree.nodes[$0].isDirectory })
        let allCollapsed = !allDirectories.isEmpty && collapsedDirectories == allDirectories
        collapseButton.title = allCollapsed ? "Expand all" : "Collapse all"
        collapseButton.isHidden = allDirectories.isEmpty
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
    private static func countText(added: Int, removed: Int) -> NSAttributedString {
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

// MARK: - Changed Files Card Defaults

enum ChangedFilesCardDefaults {
    /// Indentation per tree level — `Spacing.inset`, which is deep enough to read as
    /// containment beside the folder marks without wandering off in a deep tree.
    static let indentStep: CGFloat = Design.Spacing.inset
}
