import AppKit

struct ProjectTextSearchPreviewLinePresentation: Equatable {
    let number: Int
    let text: String
    let match: SearchTextRange?
    let isAnchor: Bool
}

struct ProjectTextSearchPreviewPresentation: Equatable {
    let path: String
    let project: String
    let lines: [ProjectTextSearchPreviewLinePresentation]
    let anchorLine: Int
    let hasEarlier: Bool
    let hasLater: Bool
}

/// Theme-owned read-only source landing for explicit Project text search.
@MainActor
final class ProjectTextSearchPreviewViewController: NSViewController {
    private enum Layout {
        static let column = NSUserInterfaceItemIdentifier("projectTextSearchPreview.column")
        static let row = NSUserInterfaceItemIdentifier("projectTextSearchPreview.row")
        static let rowHeight: CGFloat = 34
    }

    var onClose: (() -> Void)?

    private let pathLabel = NSTextField(labelWithString: "")
    private let projectLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let tableView = ThemedTableView()
    private let closeButton = ThemedButton(
        symbol: "xmark",
        accessibility: L10n.string("Close File Preview"),
        target: nil,
        action: nil
    )
    private var presentation: ProjectTextSearchPreviewPresentation?
    private var didRevealAnchor = false

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("project-text-search-preview")
        view = root

        let header = ThemedSurfaceView()
        header.applySurface(
            fill: Design.Surface.background,
            radius: .fixed(0),
            border: Design.Surface.border
        )
        root.addSubview(header)

        pathLabel.applyFont(.heading)
        pathLabel.textColor = Design.Text.label
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        projectLabel.applyFont(.caption)
        projectLabel.textColor = Design.Text.secondary

        let labels = NSStackView(views: [pathLabel, projectLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        closeButton.target = self
        closeButton.action = #selector(closePreview)

        let headerRow = NSStackView(views: [labels, closeButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = Design.Spacing.medium
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.setAccessibilityLabel(L10n.string("Project text match"))
        tableView.addTableColumn(NSTableColumn(identifier: Layout.column))

        let scroll = ThemedScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        contextLabel.applyFont(.caption)
        contextLabel.textColor = Design.Text.tertiary
        contextLabel.alignment = .center
        contextLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contextLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerRow.topAnchor.constraint(equalTo: header.topAnchor, constant: Design.Spacing.medium),
            headerRow.bottomAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: -Design.Spacing.medium
            ),
            headerRow.leadingAnchor.constraint(
                equalTo: header.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            headerRow.trailingAnchor.constraint(
                equalTo: header.trailingAnchor,
                constant: -Design.Spacing.pane
            ),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: contextLabel.topAnchor),
            contextLabel.leadingAnchor.constraint(
                equalTo: root.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            contextLabel.trailingAnchor.constraint(
                equalTo: root.trailingAnchor,
                constant: -Design.Spacing.pane
            ),
            contextLabel.bottomAnchor.constraint(
                equalTo: root.bottomAnchor,
                constant: -Design.Spacing.medium
            ),
            contextLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
    }

    override func cancelOperation(_: Any?) { onClose?() }

    func apply(_ presentation: ProjectTextSearchPreviewPresentation) {
        _ = view
        self.presentation = presentation
        pathLabel.stringValue = presentation.path
        projectLabel.stringValue = presentation.project
        contextLabel.stringValue = contextDescription(for: presentation)
        tableView.reloadData()
        revealAnchorIfNeeded()
    }

    private func contextDescription(
        for presentation: ProjectTextSearchPreviewPresentation
    ) -> String {
        switch (presentation.hasEarlier, presentation.hasLater) {
        case (true, true): return L10n.string("Showing nearby lines · Earlier and later lines are not shown")
        case (true, false): return L10n.string("Showing nearby lines · Earlier lines are not shown")
        case (false, true): return L10n.string("Showing nearby lines · Later lines are not shown")
        case (false, false): return L10n.string("Showing complete file")
        }
    }

    private func revealAnchorIfNeeded() {
        guard !didRevealAnchor,
              let presentation,
              let index = presentation.lines.firstIndex(where: {
                  $0.number == presentation.anchorLine
              }) else { return }
        didRevealAnchor = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tableView.scrollRowToVisible(index)
            NSAccessibility.post(element: self.tableView, notification: .layoutChanged)
        }
    }

    @objc private func closePreview() { onClose?() }
}

extension ProjectTextSearchPreviewViewController: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int { presentation?.lines.count ?? 0 }
}

extension ProjectTextSearchPreviewViewController: NSTableViewDelegate {
    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool { false }
    func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat { Layout.rowHeight }

    func tableView(
        _ tableView: NSTableView,
        viewFor _: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let lines = presentation?.lines, lines.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Layout.row, owner: self)
            as? ProjectTextSearchPreviewRowView) ?? ProjectTextSearchPreviewRowView()
        cell.identifier = Layout.row
        cell.show(lines[row])
        return cell
    }
}

@MainActor
private final class ProjectTextSearchPreviewRowView: NSTableCellView, ThemedComponent {
    private let numberLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private var line: ProjectTextSearchPreviewLinePresentation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)

        numberLabel.applyFont(.numericDetail())
        numberLabel.textColor = Design.Text.tertiary
        numberLabel.alignment = .right
        numberLabel.setAccessibilityElement(false)
        numberLabel.translatesAutoresizingMaskIntoConstraints = false

        codeLabel.lineBreakMode = .byClipping
        codeLabel.usesSingleLineMode = true
        codeLabel.setAccessibilityElement(false)
        codeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(numberLabel)
        addSubview(codeLabel)
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            numberLabel.widthAnchor.constraint(equalToConstant: 52),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            codeLabel.leadingAnchor.constraint(
                equalTo: numberLabel.trailingAnchor,
                constant: Design.Spacing.medium
            ),
            codeLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.medium
            ),
            codeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ line: ProjectTextSearchPreviewLinePresentation) {
        self.line = line
        numberLabel.stringValue = String(line.number)
        codeLabel.attributedStringValue = attributedCode(for: line)
        setAccessibilityValue(L10n.format("Line %lld: %@", Int64(line.number), line.text))
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard line?.isAnchor == true else { return }
        ThemedSurface.draw(
            bounds.insetBy(dx: Design.Spacing.small, dy: Design.Spacing.hairline),
            fill: Design.Surface.searchMatch,
            border: Design.Surface.border,
            radius: Design.Radius.control
        )
    }

    private func attributedCode(
        for line: ProjectTextSearchPreviewLinePresentation
    ) -> NSAttributedString {
        let content = NSMutableAttributedString(
            string: line.text,
            attributes: [
                .font: Design.FontRole.code().resolved(),
                .foregroundColor: Design.Text.label,
            ]
        )
        if let match = line.match, match.isValid {
            let range = NSRange(
                location: match.utf16Location,
                length: match.utf16Length
            )
            if NSMaxRange(range) <= content.length {
                content.addAttributes([
                    .font: Design.FontRole.code(weight: .semibold).resolved(),
                    .backgroundColor: Design.Surface.searchMatch,
                ], range: range)
            }
        }
        return content
    }
}
