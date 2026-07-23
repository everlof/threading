import AppKit

/// A view that displays a process tree using NSOutlineView.
final class ProcessTreeView: NSView {

    // MARK: - Layout Constants

    private enum Layout {
        static let pidColumnWidth: CGFloat = 120  // Wide enough for indentation + PID
        static let commandColumnWidth: CGFloat = 150
        static let ageColumnWidth: CGFloat = 70
        static let cpuColumnWidth: CGFloat = 70
        static let memColumnWidth: CGFloat = 80
        static let rowHeight: CGFloat = 18
    }

    // MARK: - Column Identifiers

    private enum Column {
        static let pid = NSUserInterfaceItemIdentifier("pid")
        static let command = NSUserInterfaceItemIdentifier("command")
        static let age = NSUserInterfaceItemIdentifier("age")
        static let cpu = NSUserInterfaceItemIdentifier("cpu")
        static let memory = NSUserInterfaceItemIdentifier("memory")
    }

    // MARK: - Properties

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var rootNode: ProcessNode?

    /// Currently selected PID (preserved across reloads)
    private var selectedPid: pid_t = 0

    /// Callback when selection changes
    var onSelectionChanged: ((ProcessNode?) -> Void)?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        setupOutlineView()
        setupScrollView()
    }

    private func setupOutlineView() {
        outlineView = ThemedOutlineView()
        outlineView.rowHeight = Layout.rowHeight
        outlineView.indentationPerLevel = 16
        outlineView.autoresizesOutlineColumn = false
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.style = .plain
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing

        // Enable column resizing via header
        let headerView = ThemedTableHeaderView()
        outlineView.headerView = headerView

        // PID column (outline column - needs extra width for indentation)
        let pidColumn = NSTableColumn(identifier: Column.pid)
        pidColumn.title = "PID"
        pidColumn.width = Layout.pidColumnWidth
        pidColumn.minWidth = 80
        pidColumn.maxWidth = 200
        pidColumn.resizingMask = .userResizingMask
        outlineView.addTableColumn(pidColumn)
        outlineView.outlineTableColumn = pidColumn

        // Command column
        let commandColumn = NSTableColumn(identifier: Column.command)
        commandColumn.title = "Command"
        commandColumn.width = Layout.commandColumnWidth
        commandColumn.minWidth = 60
        commandColumn.maxWidth = 400
        commandColumn.resizingMask = .userResizingMask
        outlineView.addTableColumn(commandColumn)

        // Age column
        let ageColumn = NSTableColumn(identifier: Column.age)
        ageColumn.title = "Age"
        ageColumn.width = Layout.ageColumnWidth
        ageColumn.minWidth = 50
        ageColumn.maxWidth = 120
        ageColumn.resizingMask = .userResizingMask
        outlineView.addTableColumn(ageColumn)

        // CPU column
        let cpuColumn = NSTableColumn(identifier: Column.cpu)
        cpuColumn.title = "CPU"
        cpuColumn.width = Layout.cpuColumnWidth
        cpuColumn.minWidth = 40
        cpuColumn.maxWidth = 120
        cpuColumn.resizingMask = .userResizingMask
        outlineView.addTableColumn(cpuColumn)

        // Memory column
        let memColumn = NSTableColumn(identifier: Column.memory)
        memColumn.title = "Mem"
        memColumn.width = Layout.memColumnWidth
        memColumn.minWidth = 50
        memColumn.maxWidth = 150
        memColumn.resizingMask = .userResizingMask
        outlineView.addTableColumn(memColumn)
    }

    private func setupScrollView() {
        scrollView = ThemedScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Public Methods

    /// Updates the tree with new data, preserving selection.
    func updateTree(_ node: ProcessNode?) {
        rootNode = node
        outlineView.reloadData()

        // Expand all items
        if let root = rootNode {
            expandAll(root)
            restoreSelection(in: root)
        }
    }

    /// Returns the currently selected node.
    func selectedNode() -> ProcessNode? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? ProcessNode
    }

    private func expandAll(_ node: ProcessNode) {
        outlineView.expandItem(node)
        for child in node.children {
            expandAll(child)
        }
    }

    private func restoreSelection(in node: ProcessNode) {
        guard selectedPid > 0 else { return }

        if let nodeToSelect = findNode(withPid: selectedPid, in: node) {
            let row = outlineView.row(forItem: nodeToSelect)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    private func findNode(withPid pid: pid_t, in node: ProcessNode) -> ProcessNode? {
        if node.pid == pid {
            return node
        }
        for child in node.children {
            if let found = findNode(withPid: pid, in: child) {
                return found
            }
        }
        return nil
    }
}

// MARK: - NSOutlineViewDataSource

extension ProcessTreeView: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootNode != nil ? 1 : 0
        }
        guard let node = item as? ProcessNode else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNode!
        }
        guard let node = item as? ProcessNode else { fatalError("Invalid item") }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ProcessNode else { return false }
        return !node.children.isEmpty
    }
}

// MARK: - NSOutlineViewDelegate

extension ProcessTreeView: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ProcessNode, let column = tableColumn else { return nil }

        let identifier = column.identifier
        let cellIdentifier = NSUserInterfaceItemIdentifier("Cell_\(identifier.rawValue)")

        var textField: NSTextField
        if let existing = outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTextField {
            textField = existing
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = cellIdentifier
            textField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textField.lineBreakMode = .byTruncatingTail
        }

        switch identifier {
        case Column.pid:
            textField.stringValue = "\(node.pid)"
            textField.textColor = Design.Text.secondary
        case Column.command:
            textField.stringValue = node.command
            textField.textColor = Design.Text.label
        case Column.age:
            textField.stringValue = node.formattedAge
            textField.textColor = Design.Text.tertiary
        case Column.cpu:
            textField.stringValue = node.formattedCpuTime
            textField.textColor = Design.Text.tertiary
        case Column.memory:
            textField.stringValue = node.formattedMemory
            textField.textColor = Design.Text.tertiary
        default:
            textField.stringValue = ""
        }

        return textField
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let node = selectedNode()
        selectedPid = node?.pid ?? 0
        onSelectionChanged?(node)
    }

    func outlineView(_ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, item: Any, mouseLocation: NSPoint) -> String {
        guard let node = item as? ProcessNode else { return "" }

        var tooltip = "PID: \(node.pid)\nCommand: \(node.command)"
        if let cwd = node.workingDirectory {
            tooltip += "\nCWD: \(cwd)"
        }
        tooltip += "\nCPU Time: \(node.formattedCpuTime)"
        tooltip += "\nMemory: \(node.formattedMemory)"

        return tooltip
    }
}
