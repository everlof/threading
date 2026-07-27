import AppKit

// MARK: - File Node

/// One entry in the tree. A reference type because the outline view identifies rows by object,
/// and because a directory's children are discovered later than the directory itself.
final class FileNode: NSObject {

    let url: URL
    let isDirectory: Bool

    /// Nil until this directory has been read. The distinction matters: an unread directory is
    /// expandable on the strength of being a directory, while one that read as empty is not.
    private(set) var children: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var name: String { url.lastPathComponent }

    /// Reads this directory's entries once. Cheap to call repeatedly; `reload` is what re-reads.
    func loadChildrenIfNeeded() {
        guard isDirectory, children == nil else { return }
        children = Self.read(url)
    }

    func reload() {
        guard isDirectory else { return }
        children = Self.read(url)
    }

    /// Directories first, then case-insensitive by name — the order every file browser uses, and
    /// the only one in which a deep tree can be scanned by eye.
    ///
    /// Dotfiles are skipped. A project root is full of them (`.git`, `.build`, every tool's
    /// config) and none of it is what someone opening a file tree came to find.
    private static func read(_ url: URL) -> [FileNode] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .map { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileNode(url: entry, isDirectory: isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

// MARK: - File Tree View Controller

/// The project's files, as a lazily-loaded tree.
///
/// Lazy is the whole design: a project root reached recursively is unbounded — `node_modules`
/// alone can be a hundred thousand entries — so a directory is read when it is opened and not
/// before. That is also why the root's own children are read on first appearance rather than at
/// construction: a tab restored into a background session costs nothing until it is looked at.
final class FileTreeViewController: NSViewController {

    // MARK: - Properties

    let folderPath: String

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var root: FileNode!
    private var hasLoaded = false

    // MARK: - Initialization

    init(folderPath: String) {
        self.folderPath = folderPath
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
        root = FileNode(url: URL(fileURLWithPath: folderPath), isDirectory: true)
        setupOutlineView()
    }

    // MARK: - Setup

    private func setupOutlineView() {
        outlineView = ThemedOutlineView()
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = FileTreeDefaults.indentationPerLevel
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.menu = makeContextMenu()

        let column = NSTableColumn(identifier: FileTreeDefaults.columnIdentifier)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView = ThemedScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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
        node.children?.forEach { reloadExpanded(from: $0) }
    }

    private func expandedNodes() -> [FileNode] {
        (0..<outlineView.numberOfRows)
            .compactMap { outlineView.item(atRow: $0) as? FileNode }
            .filter { outlineView.isItemExpanded($0) }
    }

    private var clickedNode: FileNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FileNode
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

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openClicked), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealClicked), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPathClicked), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func openClicked() {
        guard let node = clickedNode else { return }
        NSWorkspace.shared.open(node.url)
    }

    @objc private func revealClicked() {
        guard let node = clickedNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPathClicked() {
        guard let node = clickedNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
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
        return FileTreeRowView(node: node)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        FileTreeDefaults.rowHeight
    }
}

// MARK: - Row

/// One row: the file's own icon and its name.
///
/// The icon is the system's, not a symbol of ours — a file tree is the one place where matching
/// what Finder shows is more useful than matching the app, since the user is looking for a file
/// they already recognise by its icon.
private final class FileTreeRowView: NSView {

    init(node: FileNode) {
        super.init(frame: .zero)

        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: node.name)
        label.applyFont(.caption)
        label.textColor = node.isDirectory ? Design.Text.label : Design.Text.secondary
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: FileTreeDefaults.iconSize),
            icon.heightAnchor.constraint(equalToConstant: FileTreeDefaults.iconSize),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Design.Spacing.tight),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
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
