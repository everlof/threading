import AppKit

typealias FileTreeActivityLookup = @MainActor (
    AgentWorkTarget,
    [AgentWorkTreePath],
    @escaping @MainActor @Sendable ([String: AgentWorkTreeItem]) -> Void
) -> Void

// MARK: - File Node

/// One entry in the tree. A reference type because the outline view identifies rows by object,
/// and because a directory's children are discovered later than the directory itself.
final class FileNode: NSObject {

    let url: URL
    let isDirectory: Bool
    let name: String

    /// Nil until this directory has been read. The distinction matters: an unread directory is
    /// expandable on the strength of being a directory, while one that read as empty is not.
    private(set) var children: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        name = url.lastPathComponent
    }

    /// What handing this row to another app means. A directory is a place to work in; a file is
    /// a file, and this tree knows no line inside it.
    var openInTarget: ExternalAppTarget {
        isDirectory ? .folder(url) : .file(url, line: nil)
    }

    /// Reads this directory's entries once. Cheap to call repeatedly; `reload` is what re-reads.
    func loadChildrenIfNeeded() {
        guard isDirectory, children == nil else { return }
        children = Self.read(url)
    }

    func reload() {
        guard isDirectory else { return }
        children = Self.read(url, reusing: children ?? [])
    }

    /// Directories first, then case-insensitive by name — the order every file browser uses, and
    /// the only one in which a deep tree can be scanned by eye.
    /// Existing siblings are keyed by name, which is their stable path identity relative to this
    /// directory. Building canonical absolute paths here made a 20,000-row hot refresh pay for
    /// tens of thousands of URL standardizations it did not need.
    ///
    /// Dotfiles are skipped. A project root is full of them (`.git`, `.build`, every tool's
    /// config) and none of it is what someone opening a file tree came to find.
    private static func read(_ url: URL, reusing existing: [FileNode] = []) -> [FileNode] {
        let existingByName = Dictionary(
            existing.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .map { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if let existing = existingByName[entry.lastPathComponent],
                   existing.isDirectory == isDirectory {
                    return existing
                }
                return FileNode(url: entry, isDirectory: isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

// MARK: - File Tree View Controller

/// The project's files and the selected session's observed work, as a lazily-loaded tree.
///
/// Lazy is the whole design: a project root reached recursively is unbounded — `node_modules`
/// alone can be a hundred thousand entries — so a directory is read when it is opened and not
/// before. That is also why the root's own children are read on first appearance rather than at
/// construction: a tab restored into a background session costs nothing until it is looked at.
final class FileTreeViewController: NSViewController {

    private enum Limits {
        /// Several screenfuls, enough to avoid churn during short scrolls and independent of the
        /// number of expanded files.
        static let activityRows = 256
    }

    // MARK: - Properties

    let folderPath: String
    private let workTarget: AgentWorkTarget?
    private let activityLookup: FileTreeActivityLookup
    private let appEvents = AppEventObservations()

    private lazy var root = FileNode(
        url: URL(fileURLWithPath: folderPath),
        isDirectory: true
    )
    private lazy var outlineView: NSOutlineView = {
        let outline = ThemedOutlineView()
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = FileTreeDefaults.indentationPerLevel
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.onContextMenu = { [weak self] row, anchor in
            self?.presentContextMenu(forRow: row, anchor: anchor) ?? false
        }

        let column = NSTableColumn(identifier: FileTreeDefaults.columnIdentifier)
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        return outline
    }()
    private lazy var scrollView: NSScrollView = {
        let scroll = ThemedScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()
    private lazy var workSummary = AgentWorkSummaryView(target: workTarget)
    private let summarySeparator = SeparatorView()
    private var hasLoaded = false
    private var activityCache: [String: AgentWorkTreeItem] = [:]
    private var resolvedActivityPaths: Set<String> = []
    private var activityCacheOrder: [String] = []
    private var pendingActivityPaths: [String: AgentWorkTreePath] = [:]
    private var isActivityRequestScheduled = false
    private var activityGeneration = 0
    /// Holds the row context menu while it is up; released from its own dismissal.
    private var contextMenuSession: AnyObject?

    // MARK: - Initialization

    init(
        folderPath: String,
        workTarget: AgentWorkTarget? = nil,
        activityLookup: FileTreeActivityLookup? = nil
    ) {
        self.folderPath = folderPath
        self.workTarget = workTarget
        self.activityLookup = activityLookup ?? { target, paths, completion in
            AgentWorkTraceStore.shared.treeItems(
                for: target, paths: paths, completion: completion
            )
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupOutlineView()
        observeActivity()
    }

    // MARK: - Setup

    private func setupOutlineView() {
        view.addSubview(scrollView)

        guard workTarget != nil else {
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            return
        }

        workSummary.setAccessibilityIdentifier("activity.summary")
        summarySeparator.setAccessibilityIdentifier("activity.summary-separator")
        view.addSubview(workSummary)
        view.addSubview(summarySeparator)
        NSLayoutConstraint.activate([
            workSummary.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Design.Spacing.inset
            ),
            workSummary.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            workSummary.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            summarySeparator.topAnchor.constraint(
                equalTo: workSummary.bottomAnchor,
                constant: Design.Spacing.inset
            ),
            summarySeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summarySeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: summarySeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func observeActivity() {
        guard let workTarget else { return }
        appEvents.observe(AgentWorkDidChange.self) { [weak self] event in
            guard let self,
                  event.projectID == workTarget.projectID,
                  workTarget.sessionID == nil || workTarget.sessionID == event.sessionID else {
                return
            }
            self.invalidateActivityRows()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The single column does not track the pane's width on its own, so names would truncate
        // while empty space remained beside them.
        outlineView.sizeLastColumnToFit()
    }

    // MARK: - Public Methods

    /// Reads the root on first show, and re-reads what is open on later calls.
    ///
    /// Called by the pane when the tab is activated, the same deferred rule the browser's page
    /// and the review's git call follow.
    func refresh() {
        guard isViewLoaded else { return }

        if !hasLoaded {
            hasLoaded = true
            root.loadChildrenIfNeeded()
            outlineView.reloadData()
            return
        }

        // Re-read every directory currently open, so a file an agent just wrote appears without
        // the user collapsing and reopening its folder. A closed directory is left alone: it
        // will read itself when it is next opened.
        reloadExpanded(from: root)
        let expanded = expandedNodes()
        outlineView.reloadData()
        expanded.forEach { outlineView.expandItem($0) }
    }

    // MARK: - Private Methods

    private func reloadExpanded(from node: FileNode) {
        guard node.isDirectory else { return }
        let isRoot = node === root
        guard isRoot || outlineView.isItemExpanded(node) else { return }

        node.reload()
        for child in node.children ?? [] where child.isDirectory {
            reloadExpanded(from: child)
        }
    }

    private func expandedNodes() -> [FileNode] {
        var result: [FileNode] = []
        collectExpandedDirectories(from: root, into: &result)
        return result
    }

    /// Expansion is a directory property. Walking every visible file row made refresh O(all
    /// expanded files) just to discover the much smaller set of open folders.
    private func collectExpandedDirectories(from node: FileNode, into result: inout [FileNode]) {
        for child in node.children ?? [] where child.isDirectory {
            guard outlineView.isItemExpanded(child) else { continue }
            result.append(child)
            collectExpandedDirectories(from: child, into: &result)
        }
    }

    private var clickedNode: FileNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FileNode
    }

    private func relativePath(for node: FileNode) -> String? {
        if let direct = AgentWorkPath.relative(node.url.path, root: folderPath) {
            return direct
        }
        // Foundation can canonicalize `/var` to `/private/var` while enumerating a directory.
        // Resolve both sides only as a fallback so a symlink *inside* an ordinary project keeps
        // the checkout-relative identity the agent reported.
        let resolvedRoot = URL(fileURLWithPath: folderPath).resolvingSymlinksInPath().path
        let resolvedPath = node.url.resolvingSymlinksInPath().path
        return AgentWorkPath.relative(resolvedPath, root: resolvedRoot)
    }

    /// Coalesces AppKit's row requests into one worker lookup on the next main-loop turn.
    private func scheduleActivity(for node: FileNode) {
        guard workTarget != nil, let path = relativePath(for: node),
              !resolvedActivityPaths.contains(path) else { return }
        pendingActivityPaths[path] = AgentWorkTreePath(
            relativePath: path, isDirectory: node.isDirectory
        )
        guard !isActivityRequestScheduled else { return }
        isActivityRequestScheduled = true
        DispatchQueue.main.async { [weak self] in self?.requestPendingActivity() }
    }

    private func requestPendingActivity() {
        isActivityRequestScheduled = false
        guard let workTarget, !pendingActivityPaths.isEmpty else { return }
        let paths = Array(pendingActivityPaths.values)
        pendingActivityPaths.removeAll(keepingCapacity: true)
        let generation = activityGeneration
        activityLookup(workTarget, paths) { [weak self] items in
            guard let self, self.activityGeneration == generation else { return }
            for path in paths {
                self.resolvedActivityPaths.insert(path.relativePath)
                self.activityCacheOrder.removeAll { $0 == path.relativePath }
                self.activityCacheOrder.append(path.relativePath)
                self.activityCache[path.relativePath] = items[path.relativePath]
            }
            self.trimActivityCache()
            self.applyActivityToVisibleRows()
        }
    }

    private func trimActivityCache() {
        while activityCacheOrder.count > Limits.activityRows {
            let path = activityCacheOrder.removeFirst()
            resolvedActivityPaths.remove(path)
            activityCache.removeValue(forKey: path)
        }
    }

    private func invalidateActivityRows() {
        activityGeneration += 1
        activityCache.removeAll(keepingCapacity: true)
        resolvedActivityPaths.removeAll(keepingCapacity: true)
        activityCacheOrder.removeAll(keepingCapacity: true)
        pendingActivityPaths.removeAll(keepingCapacity: true)
        requestVisibleActivity()
    }

    private func requestVisibleActivity() {
        let rows = outlineView.rows(in: outlineView.visibleRect)
        guard rows.location != NSNotFound else { return }
        for row in rows.location..<(rows.location + rows.length) {
            guard let node = outlineView.item(atRow: row) as? FileNode else { continue }
            scheduleActivity(for: node)
        }
    }

    /// Never enumerates all expanded rows: only views intersecting the scroll viewport are read.
    private func applyActivityToVisibleRows() {
        let rows = outlineView.rows(in: outlineView.visibleRect)
        guard rows.location != NSNotFound else { return }
        for row in rows.location..<(rows.location + rows.length) {
            guard let node = outlineView.item(atRow: row) as? FileNode,
                  let path = relativePath(for: node),
                  let rowView = outlineView.view(
                    atColumn: 0, row: row, makeIfNecessary: false
                  ) as? FileTreeRowView else { continue }
            rowView.setActivity(activityCache[path])
        }
    }

    // MARK: - Actions

    /// A directory toggles; a file opens in whichever app owns it. Opening elsewhere rather than
    /// in the pane is deliberate — this is a way *to* the file, not a second editor.
    @objc private func rowDoubleClicked() {
        guard let node = clickedNode else { return }

        guard node.isDirectory else {
            NSWorkspace.shared.open(node.url)
            return
        }

        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    /// The row menu, built per click for the row under the pointer.
    ///
    /// It used to be a fixture built once with the outline view, which was right while every
    /// item meant the same thing for every row. "Open in" does not: its list is the apps
    /// installed *now*, and which of them may be offered depends on whether the clicked row is
    /// a file or a folder — a terminal takes a directory and would *run* a file. The node is
    /// captured into each row's closure, so the menu cannot act on a row clicked after it
    /// opened.
    private func presentContextMenu(forRow row: Int, anchor: ThemedMenuAnchor) -> Bool {
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else {
            return false
        }

        var entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: L10n.string("Open"),
                onChoose: { NSWorkspace.shared.open(node.url) }
            ))
        ]
        if let openIn = OpenInMenu.submenuEntry(for: node.openInTarget) {
            entries.append(openIn)
        }
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Reveal in Finder"),
            onChoose: { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        )))
        entries.append(.separator)
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Copy Path"),
            onChoose: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
        )))

        let source = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            ?? outlineView
        contextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: OpenInMenuDefaults.menuWidth),
            from: source,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
        return contextMenuSession != nil
    }
}

// MARK: - Data Source

extension FileTreeViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(for: item)?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(for: item)?.children?[index] ?? FileNode(url: URL(fileURLWithPath: "/"), isDirectory: false)
    }

    /// A directory is expandable before it has been read — which is what lets the read happen on
    /// expansion rather than up front.
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        (item as? FileNode)?.loadChildrenIfNeeded()
        return true
    }

    private func node(for item: Any?) -> FileNode? {
        item == nil ? root : item as? FileNode
    }
}

// MARK: - Delegate

extension FileTreeViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let row = FileTreeRowView(node: node)
        if let path = relativePath(for: node) {
            row.setActivity(activityCache[path])
        }
        scheduleActivity(for: node)
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        FileTreeDefaults.rowHeight
    }
}

// MARK: - Row

/// One row: the file's themed icon, name, and exact observed read/edit totals. System keeps Finder
/// artwork; authored themes use the semantic renderer described in `ThemedFileIconView`.
final class FileTreeRowView: NSView {

    private let node: FileNode
    private let activityLabel = NSTextField(labelWithString: "")

    init(node: FileNode) {
        self.node = node
        super.init(frame: .zero)

        let icon = ThemedFileIconView(url: node.url, isDirectory: node.isDirectory)

        let label = NSTextField(labelWithString: node.name)
        label.applyFont(.caption)
        label.textColor = node.isDirectory ? Design.Text.label : Design.Text.secondary
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false

        activityLabel.applyFont(.numericDetail())
        activityLabel.textColor = Design.Text.tertiary
        activityLabel.lineBreakMode = .byTruncatingTail
        activityLabel.usesSingleLineMode = true
        activityLabel.isHidden = true
        activityLabel.setContentHuggingPriority(.required, for: .horizontal)
        activityLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        activityLabel.setAccessibilityIdentifier("activity.file-status")
        activityLabel.translatesAutoresizingMaskIntoConstraints = false

        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(icon)
        addSubview(label)
        addSubview(activityLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: FileTreeDefaults.iconSize),
            icon.heightAnchor.constraint(equalToConstant: FileTreeDefaults.iconSize),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Design.Spacing.tight),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: activityLabel.leadingAnchor,
                constant: -Design.Spacing.small
            ),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            activityLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            activityLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func setActivity(_ item: AgentWorkTreeItem?) {
        guard let item, item.work.isTouched else {
            activityLabel.stringValue = ""
            activityLabel.isHidden = true
            activityLabel.setAccessibilityLabel("")
            setAccessibilityLabel(node.name)
            return
        }

        let reads = item.work.readCount
        let edits = item.work.editCount
        let compact = item.isDirectory
            ? L10n.format("%d files · R %d · E %d", item.touchedFileCount, reads, edits)
            : L10n.format("R %d · E %d", reads, edits)
        activityLabel.stringValue = compact
        activityLabel.textColor = edits > 0 ? Design.Text.secondary : Design.Text.tertiary
        activityLabel.isHidden = false

        let spoken = item.isDirectory
            ? L10n.format(
                "%d files, %d reads, %d edits", item.touchedFileCount, reads, edits
            )
            : L10n.format("%d reads, %d edits", reads, edits)
        activityLabel.setAccessibilityLabel(spoken)
        setAccessibilityLabel(node.name + ", " + spoken)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Defaults

enum FileTreeDefaults {
    static let columnIdentifier = NSUserInterfaceItemIdentifier("FileTreeColumn")
    static let indentationPerLevel: CGFloat = 12
    static let rowHeight: CGFloat = 20
    static let iconSize: CGFloat = 14
}
