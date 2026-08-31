import AppKit

struct ConversationSearchWindowRowPresentation: Equatable {
    let id: SearchSourceRecordID
    let eyebrow: String
    let title: String?
    let body: String
    let match: SearchTextRange?
    let isAnchor: Bool
}

struct ConversationSearchWindowPresentation: Equatable {
    let title: String
    let subtitle: String
    let rows: [ConversationSearchWindowRowPresentation]
    let anchorRowID: SearchSourceRecordID
    let hasEarlier: Bool
    let hasLater: Bool
}

/// A bounded, read-only historical conversation landing. The semantic loader owns source
/// validation and paging bounds; this theme-owned surface receives display values only and keeps
/// the potentially transcript-sized collection virtualized through a table.
@MainActor
final class ConversationSearchWindowViewController: NSViewController {
    private enum Layout {
        static let column = NSUserInterfaceItemIdentifier("conversationSearchWindow.column")
        static let row = NSUserInterfaceItemIdentifier("conversationSearchWindow.row")
        static let ordinaryRowHeight: CGFloat = 104
        static let anchorRowHeight: CGFloat = 138
    }

    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let closeButton = ThemedButton(
        symbol: "xmark",
        accessibility: L10n.string("Close History"),
        target: nil,
        action: nil
    )
    private let tableView = ThemedTableView()
    private var presentation: ConversationSearchWindowPresentation?
    private var didRevealAnchor = false

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("conversation-search-window")
        view = root

        let header = ThemedSurfaceView()
        header.applySurface(
            fill: Design.Surface.background,
            radius: .fixed(0),
            border: Design.Surface.border
        )
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        titleLabel.applyFont(.heading)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.applyFont(.caption)
        subtitleLabel.textColor = Design.Text.secondary
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = Design.Spacing.hairline

        closeButton.target = self
        closeButton.action = #selector(closeHistory)

        let headerRow = NSStackView(views: [titles, closeButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = Design.Spacing.medium
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.style = .inset
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.setAccessibilityLabel(L10n.string("Nearby conversation history"))
        tableView.addTableColumn(NSTableColumn(identifier: Layout.column))

        let scroll = ThemedScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
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

    override func cancelOperation(_: Any?) {
        onClose?()
    }

    func apply(_ presentation: ConversationSearchWindowPresentation) {
        _ = view
        self.presentation = presentation
        titleLabel.stringValue = presentation.title
        subtitleLabel.stringValue = presentation.subtitle
        contextLabel.stringValue = contextDescription(for: presentation)
        tableView.reloadData()
        revealAnchorIfNeeded()
    }

    private func contextDescription(
        for presentation: ConversationSearchWindowPresentation
    ) -> String {
        switch (presentation.hasEarlier, presentation.hasLater) {
        case (true, true):
            return L10n.string("Showing nearby history · Earlier and later messages are not shown")
        case (true, false):
            return L10n.string("Showing nearby history · Earlier messages are not shown")
        case (false, true):
            return L10n.string("Showing nearby history · Later messages are not shown")
        case (false, false):
            return L10n.string("Showing complete indexed history")
        }
    }

    private func revealAnchorIfNeeded() {
        guard !didRevealAnchor,
              let presentation,
              let index = presentation.rows.firstIndex(where: {
                  $0.id == presentation.anchorRowID
              }) else { return }
        didRevealAnchor = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tableView.scrollRowToVisible(index)
            NSAccessibility.post(
                element: self.tableView,
                notification: .layoutChanged
            )
        }
    }

    @objc private func closeHistory() {
        onClose?()
    }
}

extension ConversationSearchWindowViewController: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int {
        presentation?.rows.count ?? 0
    }
}

extension ConversationSearchWindowViewController: NSTableViewDelegate {
    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool { false }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let rows = presentation?.rows, rows.indices.contains(row) else {
            return Layout.ordinaryRowHeight
        }
        return rows[row].isAnchor ? Layout.anchorRowHeight : Layout.ordinaryRowHeight
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor _: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let rows = presentation?.rows, rows.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Layout.row, owner: self)
            as? ConversationSearchWindowRowView) ?? ConversationSearchWindowRowView()
        cell.identifier = Layout.row
        cell.show(rows[row])
        return cell
    }
}

@MainActor
private final class ConversationSearchWindowRowView: NSTableCellView, ThemedComponent {
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private var row: ConversationSearchWindowRowPresentation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)

        eyebrowLabel.applyFont(.detail(weight: .semibold))
        eyebrowLabel.textColor = Design.Text.secondary
        eyebrowLabel.lineBreakMode = .byTruncatingTail
        eyebrowLabel.setAccessibilityElement(false)

        titleLabel.applyFont(.detail(weight: .semibold))
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)

        bodyLabel.maximumNumberOfLines = 5
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bodyLabel.setAccessibilityElement(false)

        let stack = NSStackView(views: [eyebrowLabel, titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.medium),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -Design.Spacing.medium
            ),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.pane),
        ])
    }

    func show(_ row: ConversationSearchWindowRowPresentation) {
        self.row = row
        eyebrowLabel.stringValue = row.eyebrow
        titleLabel.stringValue = row.title ?? ""
        titleLabel.isHidden = row.title == nil
        bodyLabel.maximumNumberOfLines = row.isAnchor ? 6 : 4
        bodyLabel.attributedStringValue = attributedBody(for: row)
        setAccessibilityValue(
            [row.eyebrow, row.title, row.body].compactMap { $0 }.joined(separator: ". ")
        )
        needsDisplay = true
    }

    func applyTheme() {
        guard let row else { return }
        eyebrowLabel.applyFont(.detail(weight: .semibold))
        eyebrowLabel.textColor = Design.Text.secondary
        titleLabel.applyFont(.detail(weight: .semibold))
        titleLabel.textColor = Design.Text.label
        bodyLabel.attributedStringValue = attributedBody(for: row)
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        guard row?.isAnchor == true else { return }
        ThemedSurface.draw(
            bounds.insetBy(dx: Design.Spacing.small, dy: Design.Spacing.hairline),
            fill: Design.Surface.searchMatch,
            border: Design.Surface.border,
            radius: Design.Radius.control
        )
    }

    private func attributedBody(
        for row: ConversationSearchWindowRowPresentation
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: row.body,
            attributes: [
                .font: Design.FontRole.body.resolved(in: .chrome),
                .foregroundColor: Design.Text.label,
            ]
        )
        if let match = row.match, match.isValid {
            let range = NSRange(
                location: match.utf16Location,
                length: match.utf16Length
            )
            if NSMaxRange(range) <= text.length {
                text.addAttributes([
                    .font: Design.FontRole.body.emphasized.resolved(in: .chrome),
                    .backgroundColor: Design.Surface.searchMatch,
                ], range: range)
            }
        }
        return text
    }
}
