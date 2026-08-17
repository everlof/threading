import AppKit
import CryptoKit

typealias FileTreeActivityLookup = @MainActor (
    AgentWorkTarget,
    [AgentWorkTreePath],
    @escaping @MainActor @Sendable ([String: AgentWorkTreeItem]) -> Void
) -> Void

struct FileDirectoryEntry: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
}

struct FileDirectorySnapshot: Sendable {
    let entries: [FileDirectoryEntry]
    let signature: Data

    /// Directory enumeration, metadata reads and natural sorting are all filesystem/model work.
    /// The controller invokes this value-only boundary from a detached task; AppKit and the
    /// identity-bearing `FileNode` objects never cross that boundary.
    static func read(_ url: URL) -> FileDirectorySnapshot {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let entries = urls.map { entry in
            FileDirectoryEntry(
                url: entry,
                name: entry.lastPathComponent,
                isDirectory: (try? entry.resourceValues(
                    forKeys: [.isDirectoryKey]
                ))?.isDirectory ?? false
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.name < rhs.name
        }
        var signatureInput = Data()
        signatureInput.reserveCapacity(entries.reduce(0) { $0 + $1.name.utf8.count + 2 })
        for entry in entries {
            signatureInput.append(entry.isDirectory ? 1 : 0)
            signatureInput.append(contentsOf: entry.name.utf8)
            signatureInput.append(0)
        }
        return FileDirectorySnapshot(
            entries: entries,
            signature: Data(SHA256.hash(data: signatureInput))
        )
    }
}

typealias FileTreeDirectoryReader = @Sendable (URL) -> FileDirectorySnapshot

// MARK: - File Node

private struct FileNodeApplyResult {
    let accepted: Bool
    let changed: Bool

    static let stale = FileNodeApplyResult(accepted: false, changed: false)
    static let unchanged = FileNodeApplyResult(accepted: true, changed: false)
    static let changed = FileNodeApplyResult(accepted: true, changed: true)
}

/// One entry in the tree. A reference type because the outline view identifies rows by object,
/// and because a directory's children are discovered later than the directory itself.
@MainActor
final class FileNode: NSObject {

    let url: URL
    let isDirectory: Bool
    let name: String

    /// Nil until this directory has been read. The distinction matters: an unread directory is
    /// expandable on the strength of being a directory, while one that read as empty is not.
    private(set) var children: [FileNode]?
    private var loadGeneration = 0
    private var contentSignature: Data?

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

    var hasLoadedChildren: Bool { children != nil }

    /// Begins one value-snapshot read. The token makes a late worker result harmless when a newer
    /// refresh or disclosure for this same directory has already started.
    func beginLoad() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    /// Reconciles a worker-produced snapshot on the main actor. Directories first and natural name
    /// order were already decided in the snapshot, so this phase is only identity matching and
    /// allocation for genuinely new paths.
    /// Existing siblings are keyed by name, which is their stable path identity relative to this
    /// directory. Building canonical absolute paths here made a 20,000-row hot refresh pay for
    /// tens of thousands of URL standardizations it did not need.
    @discardableResult
    fileprivate func apply(
        _ snapshot: FileDirectorySnapshot,
        generation: Int
    ) -> FileNodeApplyResult {
        guard isDirectory, generation == loadGeneration else { return .stale }
        guard let existing = children else {
            children = snapshot.entries.map {
                FileNode(url: $0.url, isDirectory: $0.isDirectory)
            }
            contentSignature = snapshot.signature
            return .changed
        }

        guard contentSignature != snapshot.signature else { return .unchanged }

        // The worker sorted both generations with the same deterministic comparator. Most hot
        // refreshes are identical, and a changed directory usually differs by one or two names,
        // so a two-pointer merge preserves identity without rebuilding a 20,000-entry dictionary.
        var reconciled: [FileNode] = []
        reconciled.reserveCapacity(snapshot.entries.count)
        var oldIndex = 0
        var newIndex = 0
        var changed = existing.count != snapshot.entries.count

        while newIndex < snapshot.entries.count {
            let entry = snapshot.entries[newIndex]
            guard oldIndex < existing.count else {
                reconciled.append(FileNode(url: entry.url, isDirectory: entry.isDirectory))
                newIndex += 1
                changed = true
                continue
            }

            let node = existing[oldIndex]
            if node.name == entry.name {
                if node.isDirectory == entry.isDirectory {
                    reconciled.append(node)
                } else {
                    reconciled.append(FileNode(url: entry.url, isDirectory: entry.isDirectory))
                    changed = true
                }
                oldIndex += 1
                newIndex += 1
            } else if Self.precedes(
                lhsDirectory: node.isDirectory,
                lhsName: node.name,
                rhsDirectory: entry.isDirectory,
                rhsName: entry.name
            ) {
                // An old path disappeared. The new entry will be compared with its successor.
                oldIndex += 1
                changed = true
            } else {
                // A new path was inserted before the current old child.
                reconciled.append(FileNode(url: entry.url, isDirectory: entry.isDirectory))
                newIndex += 1
                changed = true
            }
        }
        if oldIndex != existing.count { changed = true }
        guard changed else {
            contentSignature = snapshot.signature
            return .unchanged
        }
        children = reconciled
        contentSignature = snapshot.signature
        return .changed
    }

    private static func precedes(
        lhsDirectory: Bool,
        lhsName: String,
        rhsDirectory: Bool,
        rhsName: String
    ) -> Bool {
        if lhsDirectory != rhsDirectory { return lhsDirectory }
        let comparison = lhsName.localizedStandardCompare(rhsName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhsName < rhsName
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

    private struct DirectoryReadRequest: Sendable {
        let index: Int
        let url: URL
    }

    private struct DirectoryReadResult: Sendable {
        let index: Int
        let snapshot: FileDirectorySnapshot
    }

    private struct DirectoryReadBatch: Sendable {
        let results: [DirectoryReadResult]
        let elapsedNanoseconds: UInt64
    }

    // MARK: - Properties

    let folderPath: String
    private let workTarget: AgentWorkTarget?
    private let activityLookup: FileTreeActivityLookup
    private let directoryReader: FileTreeDirectoryReader
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
    private var refreshGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshCompletions: [() -> Void] = []
    private var directoryLoadTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var pendingExpansionIDs: Set<ObjectIdentifier> = []
    private(set) var lastRefreshReadNanosecondsForTesting: UInt64 = 0
    private(set) var lastRefreshApplyNanosecondsForTesting: UInt64 = 0
    private(set) var maximumDisclosureApplyNanosecondsForTesting: UInt64 = 0
    var pendingDirectoryLoadCountForTesting: Int { directoryLoadTasks.count }
    /// Holds the row context menu while it is up; released from its own dismissal.
    private var contextMenuSession: AnyObject?

    // MARK: - Initialization

    init(
        folderPath: String,
        workTarget: AgentWorkTarget? = nil,
        activityLookup: FileTreeActivityLookup? = nil,
        directoryReader: @escaping FileTreeDirectoryReader = {
            FileDirectorySnapshot.read($0)
        }
    ) {
        self.folderPath = folderPath
        self.workTarget = workTarget
        self.directoryReader = directoryReader
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

    deinit {
        refreshTask?.cancel()
        directoryLoadTasks.values.forEach { $0.cancel() }
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
    func refresh(completion: (() -> Void)? = nil) {
        guard isViewLoaded else {
            completion?()
            return
        }
        if let completion { refreshCompletions.append(completion) }

        // Capture only the small set of open directory identities on the main actor. Their URLs
        // become Sendable requests; enumeration, metadata reads and sorting happen off-main.
        let expanded = hasLoaded ? expandedNodes() : []
        let nodes = [root] + expanded
        let targets = nodes.map { node in
            (node: node, generation: node.beginLoad())
        }
        let requests = nodes.enumerated().map {
            DirectoryReadRequest(index: $0.offset, url: $0.element.url)
        }
        let reader = directoryReader

        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { [weak self, requests] in
            let batch = await Task.detached(priority: .userInitiated) {
                let started = DispatchTime.now().uptimeNanoseconds
                let results = requests.map { request in
                    DirectoryReadResult(
                        index: request.index,
                        snapshot: reader(request.url)
                    )
                }
                return DirectoryReadBatch(
                    results: results,
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started
                )
            }.value
            guard !Task.isCancelled, let self,
                  generation == self.refreshGeneration else { return }

            let applyStarted = DispatchTime.now().uptimeNanoseconds
            var rootResult = FileNodeApplyResult.stale
            var changedDirectories: [FileNode] = []
            for result in batch.results where targets.indices.contains(result.index) {
                let target = targets[result.index]
                let applied = target.node.apply(
                    result.snapshot,
                    generation: target.generation
                )
                if result.index == 0 {
                    rootResult = applied
                } else if applied.changed {
                    changedDirectories.append(target.node)
                }
            }
            guard rootResult.accepted else { return }
            self.hasLoaded = true
            if rootResult.changed {
                self.outlineView.reloadData()
                expanded.forEach { self.outlineView.expandItem($0) }
            } else {
                for directory in changedDirectories
                    where self.outlineView.row(forItem: directory) >= 0 {
                    self.outlineView.reloadItem(directory, reloadChildren: true)
                }
            }
            self.lastRefreshReadNanosecondsForTesting = batch.elapsedNanoseconds
            self.lastRefreshApplyNanosecondsForTesting =
                DispatchTime.now().uptimeNanoseconds - applyStarted
            self.refreshTask = nil
            let completions = self.refreshCompletions
            self.refreshCompletions.removeAll(keepingCapacity: true)
            completions.forEach { $0() }
        }
    }

    // MARK: - Private Methods

    private func loadForDisclosure(_ node: FileNode) {
        let identifier = ObjectIdentifier(node)
        pendingExpansionIDs.insert(identifier)
        guard directoryLoadTasks[identifier] == nil else { return }

        let generation = node.beginLoad()
        let url = node.url
        let reader = directoryReader
        directoryLoadTasks[identifier] = Task { [weak self, weak node] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                reader(url)
            }.value
            guard let self else { return }
            self.directoryLoadTasks[identifier] = nil
            guard !Task.isCancelled, let node else {
                self.pendingExpansionIDs.remove(identifier)
                return
            }
            let applyStarted = DispatchTime.now().uptimeNanoseconds
            let result = node.apply(snapshot, generation: generation)
            let shouldExpand = self.pendingExpansionIDs.remove(identifier) != nil
            guard result.accepted else { return }
            if result.changed {
                self.outlineView.reloadItem(node, reloadChildren: true)
            }
            if shouldExpand, self.outlineView.row(forItem: node) >= 0 {
                self.outlineView.expandItem(node)
            }
            self.maximumDisclosureApplyNanosecondsForTesting = max(
                self.maximumDisclosureApplyNanosecondsForTesting,
                DispatchTime.now().uptimeNanoseconds - applyStarted
            )
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
        guard let node = item as? FileNode else { return false }
        guard node.hasLoadedChildren else {
            loadForDisclosure(node)
            return false
        }
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
        let observed = item.work.observedChanges
        var compact = item.isDirectory
            ? L10n.format("%d files · R %d · E %d", item.touchedFileCount, reads, edits)
            : L10n.format("R %d · E %d", reads, edits)
        var spoken = item.isDirectory
            ? L10n.format(
                "%d files, %d reads, %d edits", item.touchedFileCount, reads, edits
            )
            : L10n.format("%d reads, %d edits", reads, edits)

        // Appended rather than folded into the edit total: a turn's tree pair shows that a file
        // changed, which is a different fact from a tool saying it wrote one, and the row is the
        // one place a person reads the two numbers side by side.
        if observed > 0 {
            compact += L10n.format(" · C %d", observed)
            spoken += ", " + L10n.format("%d observed changes", observed)
        }
        activityLabel.stringValue = compact
        activityLabel.textColor = edits > 0 ? Design.Text.secondary : Design.Text.tertiary
        activityLabel.isHidden = false
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
