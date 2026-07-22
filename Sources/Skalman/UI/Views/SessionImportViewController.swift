import AppKit

/// Picks a conversation found on disk to adopt into a project.
///
/// Presented as a sheet rather than a chip menu: a busy project has hundreds of past
/// conversations, which is far past what a menu can be scanned in, so the list is searchable
/// and shows enough of each conversation to tell them apart.
final class SessionImportViewController: NSViewController {

    // MARK: - Properties

    /// Every conversation offered, before the search field narrows it.
    private let sessions: [ImportableSession]
    private var visible: [ImportableSession] = []

    private let headingLabel = NSTextField(labelWithString: ImportStrings.heading)
    private let subheadingLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let importButton = NSButton()

    /// Called with the chosen conversation, or nil when the sheet is dismissed.
    var onPick: ((ImportableSession?) -> Void)?

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Initialization

    init(sessions: [ImportableSession]) {
        self.sessions = sessions
        self.visible = sessions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(
            x: 0, y: 0,
            width: ImportLayout.sheetWidth,
            height: ImportLayout.sheetHeight
        ))
        setupViews()
        updateSubheading()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        // Typing should narrow the list straight away, which is the only thing to do here
        // when the list is long.
        view.window?.makeFirstResponder(searchField)
        selectFirstRow()
    }

    // MARK: - Setup

    private func setupViews() {
        headingLabel.font = Design.Typography.heading()
        headingLabel.textColor = Design.Text.label

        subheadingLabel.font = Design.Typography.subheading()
        subheadingLabel.textColor = Design.Text.secondary

        let headings = NSStackView(views: [headingLabel, subheadingLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = Design.Spacing.hairline

        searchField.placeholderString = ImportStrings.searchPlaceholder
        searchField.font = Design.Typography.body()

        // Filtering is driven by the delegate rather than the field's action, leaving Return
        // to confirm the selection: the field holds focus, so its action would otherwise
        // swallow the key that is meant to import.
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(confirm)

        let stack = NSStackView(views: [headings, searchField, makeTable(), makeFooter()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: headings)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.pane),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.pane)
        ])

        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeTable() -> NSView {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = ImportLayout.rowHeight
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.doubleAction = #selector(confirm)
        tableView.target = self
        tableView.addTableColumn(NSTableColumn(identifier: ImportColumn.session))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.applySurface(
            fill: Design.Surface.panel,
            radius: Design.Radius.panel,
            border: Design.Surface.border
        )

        // The list is the content of this sheet, so it takes whatever height is left over.
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor
            .constraint(greaterThanOrEqualToConstant: ImportLayout.minimumListHeight)
            .isActive = true

        return scrollView
    }

    private func makeFooter() -> NSView {
        importButton.title = ImportStrings.importTitle
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"
        importButton.target = self
        importButton.action = #selector(confirm)

        let cancelButton = NSButton(
            title: ImportStrings.cancelTitle,
            target: self,
            action: #selector(cancel)
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [spacer, cancelButton, importButton])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small

        return footer
    }

    // MARK: - Actions

    private func applySearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)

        visible = query.isEmpty ? sessions : sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.kind.displayName.localizedCaseInsensitiveContains(query)
        }

        tableView.reloadData()
        updateSubheading()
        selectFirstRow()
    }

    @objc private func confirm() {
        let row = tableView.selectedRow
        guard row >= 0, row < visible.count else { return }
        onPick?(visible[row])
    }

    @objc private func cancel() {
        onPick?(nil)
    }

    // MARK: - Private Methods

    /// Keeps a row selected so Return always has something to act on.
    private func selectFirstRow() {
        guard !visible.isEmpty else {
            importButton.isEnabled = false
            return
        }

        tableView.selectRowIndexes([0], byExtendingSelection: false)
        importButton.isEnabled = true
    }

    private func updateSubheading() {
        subheadingLabel.stringValue = visible.count == sessions.count
            ? ImportStrings.subheading(count: sessions.count)
            : ImportStrings.filteredSubheading(shown: visible.count, of: sessions.count)
    }
}

// MARK: - NSSearchFieldDelegate

extension SessionImportViewController: NSSearchFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        applySearch()
    }
}

// MARK: - NSTableViewDataSource

extension SessionImportViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        visible.count
    }
}

// MARK: - NSTableViewDelegate

extension SessionImportViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visible.count else { return nil }
        return makeRow(for: visible[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        importButton.isEnabled = tableView.selectedRow >= 0
    }

    /// A row shows the agent it belongs to, what the conversation was about, and when it was
    /// last touched — which together are what distinguishes one past conversation from another.
    private func makeRow(for session: ImportableSession) -> NSView {
        let icon = NSImageView()
        icon.image = session.kind.icon
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        icon.contentTintColor = Design.Text.secondary

        let title = NSTextField(labelWithString: session.title)
        title.font = Design.Typography.body()
        title.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: detailText(for: session))
        detail.font = Design.Typography.subheading()
        detail.textColor = Design.Text.tertiary
        detail.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.hairline

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: Design.Spacing.small,
            bottom: 0, right: Design.Spacing.small
        )

        return row
    }

    /// Names the account only when it is not the default one, matching the sidebar.
    private func detailText(for session: ImportableSession) -> String {
        let when = Self.relativeDate.localizedString(for: session.lastActiveAt, relativeTo: Date())

        guard !session.accountHandle.isStandard,
              let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              )
        else { return when }

        return "\(account.displayName) · \(when)"
    }
}

// MARK: - Import Column

enum ImportColumn {
    static let session = NSUserInterfaceItemIdentifier("ImportSessionColumn")
}

// MARK: - Import Layout

enum ImportLayout {
    static let sheetWidth: CGFloat = 520
    static let sheetHeight: CGFloat = 460
    static let rowHeight: CGFloat = 44
    static let minimumListHeight: CGFloat = 240
}

// MARK: - Import Strings

enum ImportStrings {
    static let heading = "Import Conversation"
    static let searchPlaceholder = "Search conversations"
    static let importTitle = "Import"
    static let cancelTitle = "Cancel"

    static func subheading(count: Int) -> String {
        count == 1
            ? "1 conversation found in this folder"
            : "\(count) conversations found in this folder"
    }

    static func filteredSubheading(shown: Int, of total: Int) -> String {
        "\(shown) of \(total) conversations"
    }
}
