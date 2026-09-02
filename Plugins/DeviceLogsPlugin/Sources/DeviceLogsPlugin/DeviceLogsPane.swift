import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

/// The pane the host is given.
///
/// Everything visible here is a real Threading component resolving the host's own theme, so the
/// pane is not a plugin-shaped approximation of the window — it is the window's vocabulary,
/// compiled into the bundle.
final class DeviceLogsPane: NSView {

    private let sources: [LogStreamSource] = [
        LogStreamSource(title: "This Mac", arguments: ["log", "stream", "--style=ndjson", "--level=info"]),
        LogStreamSource(title: "Booted Simulator",
                        arguments: ["simctl", "spawn", "booted", "log", "stream", "--style=ndjson", "--level=info"]),
    ]
    private var active: LogStreamSource?
    private var rows: [LogRow] = []
    private var filtered: [LogRow] = []
    private var timer: Timer?
    private var follows = true

    private let chooser = ThemedPopUp()
    private let filterField = ThemedSearchField()
    private let followButton = ThemedButton()
    private let spinner = ThemedSpinner()
    private let status = ThemedTextField(labelWithString: "")
    private let table = ThemedTableView()
    private let scroll = ThemedScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Design.Surface.ground.cgColor
        buildControls()
        buildTable()
        layOut()
        select(index: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate(); sources.forEach { $0.stop() } }

    // MARK: - Construction

    private func buildControls() {
        for source in sources { chooser.addItem(withTitle: source.title) }
        chooser.target = self
        chooser.action = #selector(sourceChanged)

        filterField.placeholderString = "Filter"
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.widthAnchor.constraint(
            equalToConstant: LogStreamDefaults.filterWidth
        ).isActive = true
        filterField.target = self
        filterField.action = #selector(filterChanged)

        followButton.title = "Following"
        followButton.emphasis = .primary
        followButton.target = self
        followButton.action = #selector(toggleFollow)

        status.font = Design.Typography.compactCode()
        status.textColor = Design.Text.secondary
    }

    private func buildTable() {
        table.rowHeight = LogStreamDefaults.rowHeight
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        for (identifier, width) in [("time", LogStreamDefaults.timeColumnWidth),
                                    ("process", LogStreamDefaults.processColumnWidth),
                                    ("message", LogStreamDefaults.messageColumnMinimumWidth)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.width = width
            column.minWidth = identifier == "message"
                ? LogStreamDefaults.messageColumnMinimumWidth : width
            column.maxWidth = identifier == "message" ? .greatestFiniteMagnitude : width
            table.addTableColumn(column)
        }
        // The message is the content; the two fixed columns are its margin notes.
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
    }

    private func layOut() {
        let controls = ControlRowView(leading: [chooser, filterField],
                                      trailing: [spinner, followButton])
        for view in [controls, scroll, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = Design.Spacing.medium
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: Design.Spacing.small),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Design.Spacing.tight),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.tight),
        ])
    }

    override func layout() {
        super.layout()
        table.sizeLastColumnToFit()
    }

    // MARK: - Theme

    func apply(_ theme: PluginTheme) {
        // The host's whole theme when it could send one; the tokens beside it are the floor.
        try? HostThemeHandoff.install(encoded: theme.encodedTheme)
        layer?.backgroundColor = Design.Surface.ground.cgColor
        status.textColor = Design.Text.secondary
        table.reloadData()
        needsDisplay = true
    }

    // MARK: - Actions

    @objc private func sourceChanged() { select(index: chooser.indexOfSelectedItem) }

    @objc private func filterChanged() { refilter(); table.reloadData(); scrollIfFollowing() }

    @objc private func toggleFollow() {
        follows.toggle()
        followButton.title = follows ? "Following" : "Follow"
        followButton.emphasis = follows ? .primary : .secondary
        scrollIfFollowing()
    }

    private func select(index: Int) {
        guard sources.indices.contains(index) else { return }
        active?.stop()
        rows.removeAll(); filtered.removeAll(); table.reloadData()
        let source = sources[index]
        source.start()
        active = source
        spinner.isAnimating = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: LogStreamDefaults.drainInterval,
                                     repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
    }

    // MARK: - The stream

    private func drain() {
        guard let active else { return }
        let arrived = active.drain()
        guard !arrived.isEmpty else { return updateStatus() }
        rows.append(contentsOf: arrived)
        if rows.count > LogStreamDefaults.rowCapacity {
            rows.removeFirst(rows.count - LogStreamDefaults.rowCapacity)
        }
        refilter()
        table.reloadData()
        scrollIfFollowing()
        updateStatus()
    }

    private func refilter() {
        let needle = filterField.stringValue.lowercased()
        filtered = needle.isEmpty ? rows : rows.filter {
            $0.message.lowercased().contains(needle) || $0.process.lowercased().contains(needle)
        }
    }

    private func scrollIfFollowing() {
        guard follows, filtered.count > 0 else { return }
        table.scrollRowToVisible(filtered.count - 1)
    }

    private func updateStatus() {
        let dropped = active?.dropped ?? 0
        let shown = filtered.count
        var text = "\(shown) rows"
        if shown != rows.count { text += " of \(rows.count)" }
        if dropped > 0 { text += " · \(dropped) dropped" }
        status.stringValue = text
    }
}

// MARK: - Table

extension DeviceLogsPane: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row), let column else { return nil }
        let entry = filtered[row]
        // A plain label, not a themed field: a field draws its own well, and a table of them
        // renders every cell as a plate — which is what the first render of this pane looked
        // like. The row's ground belongs to the table.
        let label = NSTextField(labelWithString: "")
        label.drawsBackground = false
        label.isBordered = false
        label.lineBreakMode = .byTruncatingTail
        label.font = Design.Typography.compactCode()
        switch column.identifier.rawValue {
        case "time":
            label.stringValue = entry.time
            label.textColor = Design.Text.tertiary
        case "process":
            label.stringValue = entry.process
            label.textColor = Design.Text.secondary
        default:
            label.stringValue = entry.message
            label.textColor = colour(for: entry.level)
        }
        return label
    }

    /// The level decides the ink, through the theme's own roles rather than a palette of its own.
    private func colour(for level: String) -> NSColor {
        switch level {
        case "Error", "Fault": return AppThemePalette.color(.statusNegative)
        case "Debug": return Design.Text.tertiary
        default: return Design.Text.label
        }
    }
}
