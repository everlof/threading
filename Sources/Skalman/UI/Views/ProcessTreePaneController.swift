import AppKit

/// View controller for the process tree pane (horizontal layout - appears at top).
final class ProcessTreePaneController: NSViewController {

    // MARK: - Layout Constants

    private enum Layout {
        static let headerHeight: CGFloat = 28
        static let padding: CGFloat = 8
        static let buttonSize: CGFloat = 20
        static let summaryHeight: CGFloat = 20
    }

    // MARK: - Properties

    private var headerView: NSView!
    private var titleLabel: NSTextField!
    private var refreshButton: ThemedButton!
    private var closeButton: ThemedButton!
    private var contentSplitView: NSSplitView!
    private var processTreeView: ProcessTreeView!
    private var detailView: NSView!
    private var detailLabels: [NSTextField] = []
    private var summaryLabel: NSTextField!

    private var refreshTimer: Timer?
    private var rootPid: pid_t = 0

    /// Callback when the close button is pressed.
    var onClose: (() -> Void)?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startAutoRefresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopAutoRefresh()
    }

    // MARK: - Setup

    private func setupUI() {
        setupHeader()
        setupContentArea()
        setupSummaryLabel()
        setupConstraints()
    }

    private func setupHeader() {
        headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.applySurface(fill: Design.Surface.ground, radius: .fixed(0))

        titleLabel = NSTextField(labelWithString: "Process Tree")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = Design.Text.label

        refreshButton = ThemedButton(symbol: "arrow.clockwise", accessibility: "Refresh", target: self, action: #selector(refreshTree))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.isBordered = false

        closeButton = ThemedButton(symbol: "xmark", accessibility: "Close", target: self, action: #selector(closeTapped))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false

        headerView.addSubview(titleLabel)
        headerView.addSubview(refreshButton)
        headerView.addSubview(closeButton)
        view.addSubview(headerView)
    }

    private func setupContentArea() {
        // Process tree view (left/main area)
        processTreeView = ProcessTreeView()
        processTreeView.translatesAutoresizingMaskIntoConstraints = false
        processTreeView.onSelectionChanged = { [weak self] node in
            self?.updateDetailView(with: node)
        }

        // Detail view (right side)
        detailView = NSView()
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailView.applySurface(fill: Design.Surface.elevated, radius: .fixed(0))

        // Create detail labels
        let labels = ["PID:", "Command:", "Age:", "CPU Time:", "Memory:", "CWD:"]
        for (index, _) in labels.enumerated() {
            let label = NSTextField(labelWithString: "-")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = Design.Text.tertiary
            label.lineBreakMode = .byTruncatingMiddle
            label.tag = index
            detailView.addSubview(label)
            detailLabels.append(label)
        }

        // Use split view to allow resizing between tree and detail
        contentSplitView = NSSplitView()
        contentSplitView.translatesAutoresizingMaskIntoConstraints = false
        contentSplitView.isVertical = true  // Left-right split
        contentSplitView.dividerStyle = .thin
        contentSplitView.delegate = self
        contentSplitView.addSubview(processTreeView)
        contentSplitView.addSubview(detailView)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        view.addSubview(contentSplitView)
    }

    private func setupSummaryLabel() {
        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        summaryLabel.textColor = Design.Text.tertiary
        summaryLabel.alignment = .left
        view.addSubview(summaryLabel)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Header
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Layout.headerHeight),

            // Title
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: Layout.padding),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            // Close button
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -Layout.padding),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Layout.buttonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Layout.buttonSize),

            // Refresh button
            refreshButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            refreshButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: Layout.buttonSize),
            refreshButton.heightAnchor.constraint(equalToConstant: Layout.buttonSize),

            // Content split view
            contentSplitView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentSplitView.bottomAnchor.constraint(equalTo: summaryLabel.topAnchor, constant: -2),

            // Summary label
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.padding),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.padding),
            summaryLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            summaryLabel.heightAnchor.constraint(equalToConstant: Layout.summaryHeight)
        ])

        // Layout detail labels vertically within detail view
        for (index, label) in detailLabels.enumerated() {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: detailView.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: detailView.trailingAnchor, constant: -6),
                label.topAnchor.constraint(equalTo: detailView.topAnchor, constant: CGFloat(6 + index * 18))
            ])
        }

        updateDetailView(with: nil)
    }

    // MARK: - Public Methods

    /// Sets the root process ID to display.
    func setRootPid(_ pid: pid_t) {
        rootPid = pid
        refreshTree()
    }

    // MARK: - Detail View

    private func updateDetailView(with node: ProcessNode?) {
        guard !detailLabels.isEmpty else { return }

        if let node = node {
            detailLabels[0].stringValue = "PID: \(node.pid)"
            detailLabels[1].stringValue = "Cmd: \(node.command)"
            detailLabels[2].stringValue = "Age: \(node.formattedAge)"
            detailLabels[3].stringValue = "CPU: \(node.formattedCpuTime)"
            detailLabels[4].stringValue = "Mem: \(node.formattedMemory)"
            detailLabels[5].stringValue = "CWD: \(node.workingDirectory ?? "N/A")"

            for label in detailLabels {
                label.textColor = Design.Text.secondary
            }
        } else {
            detailLabels[0].stringValue = "PID: -"
            detailLabels[1].stringValue = "Cmd: -"
            detailLabels[2].stringValue = "Age: -"
            detailLabels[3].stringValue = "CPU: -"
            detailLabels[4].stringValue = "Mem: -"
            detailLabels[5].stringValue = "CWD: -"

            for label in detailLabels {
                label.textColor = Design.Text.tertiary
            }
        }
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: ProcessTreeDefaults.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshTree()
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Actions

    @objc private func refreshTree() {
        // Ensure view is loaded before accessing UI elements
        guard isViewLoaded, processTreeView != nil else { return }

        guard rootPid > 0 else {
            processTreeView.updateTree(nil)
            summaryLabel.stringValue = "No process"
            return
        }

        let tree = ProcessTreeBuilder.buildTree(rootPid: rootPid)
        processTreeView.updateTree(tree)

        if let tree = tree {
            let count = ProcessTreeBuilder.countNodes(tree)
            let totalMem = ProcessTreeBuilder.totalMemory(tree)
            let memStr = formatMemory(totalMem)
            summaryLabel.stringValue = "\(count) process\(count == 1 ? "" : "es") • \(memStr) total"
        } else {
            summaryLabel.stringValue = "Process terminated"
        }
    }

    @objc private func closeTapped() {
        onClose?()
    }

    // MARK: - Helpers

    private func formatMemory(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.0f KB", kb)
        }
        let mb = kb / 1024
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }
}

// MARK: - NSSplitViewDelegate

extension ProcessTreePaneController: NSSplitViewDelegate {

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Minimum width for the tree view (left side)
        return 200
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Maximum width for the tree view, leaving room for detail panel
        return splitView.bounds.width - 120
    }
}
