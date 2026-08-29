import AppKit

/// Compact run-plan chrome shared by the terminal status card and native composer status row.
@MainActor
final class RunPlanDisclosureView: NSView, ThemedComponent {
    var preferredEdge: NSRectEdge = .maxY
    var contentTintColor: NSColor? {
        get { button.contentTintColor }
        set { button.contentTintColor = newValue }
    }
    var hoverFill: NSColor? {
        get { button.hoverFill }
        set { button.hoverFill = newValue }
    }

    private let button = ThemedButton(
        symbol: "checklist",
        accessibility: L10n.string("Show plan"),
        target: nil,
        action: nil
    )
    private var progress: RunProgress?
    private var popover: ThemedPopover?
    private weak var detailController: RunPlanDetailViewController?

    var titleForTesting: String { button.title }
    var isPopoverShownForTesting: Bool { popover?.isShown == true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.emphasis = .tertiary
        button.contentAlignment = .leading
        button.showsSubmenuIndicator = true
        button.target = self
        button.action = #selector(togglePopover)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ progress: RunProgress?) {
        self.progress = progress
        isHidden = progress == nil
        guard let progress else {
            closePopover()
            return
        }
        button.title = progress.compactLabel
        button.toolTip = progress.steps.map(\.title).joined(separator: "\n")
        button.setAccessibilityLabel(L10n.string("Show plan"))
        button.setAccessibilityValue(progress.compactLabel)
        detailController?.update(progress)
    }

    @objc private func togglePopover() {
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover()
        }
    }

    /// Builds the same bounded, virtualized detail surface used by the transient popover.
    /// Evidence fixtures can mount it in deterministic popover chrome without ordering a
    /// separate AppKit window on the test runner's screen.
    func makeDetailSurface() -> NSViewController? {
        guard let progress, !progress.steps.isEmpty else { return nil }
        return RunPlanDetailViewController(progress: progress)
    }

    private func showPopover() {
        guard let controller = makeDetailSurface() as? RunPlanDetailViewController else {
            return
        }
        let popover = HostPopoverFactory.make(.sessionRunPlan)
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.initialFirstResponder = controller.initialFirstResponder
        popover.onClose = { [weak self] in
            self?.popover = nil
            self?.detailController = nil
        }
        popover.show(relativeTo: bounds, of: self, preferredEdge: preferredEdge)
        self.popover = popover
        detailController = controller
    }

    func closePopover() {
        popover?.close()
        popover = nil
        detailController = nil
    }
}

@MainActor
private final class RunPlanDetailViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate {
    private enum Layout {
        static let width: CGFloat = 380
        static let rowHeight: CGFloat = 34
        static let maximumVisibleRows: CGFloat = 9
    }

    private let titleLabel = NSTextField(labelWithString: L10n.string("Plan"))
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = ThemedScrollView()
    private let table = ThemedTableView()
    private var progress: RunProgress

    var initialFirstResponder: NSResponder { table }

    init(progress: RunProgress) {
        self.progress = progress
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.applyFont(.heading)
        titleLabel.textColor = Design.Text.label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.applyFont(.caption)
        countLabel.textColor = Design.Text.secondary
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = Layout.rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(L10n.string("Plan steps"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RunPlan.Step"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        view.addSubview(titleLabel)
        view.addSubview(countLabel)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Layout.width),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.inset),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.inset),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: Design.Spacing.medium),
            countLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.inset),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Design.Spacing.small),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.small),
        ])
        update(progress)
    }

    func update(_ progress: RunProgress) {
        self.progress = progress
        guard isViewLoaded else { return }
        countLabel.stringValue = L10n.format(
            "%lld of %lld complete",
            Int64(progress.completed),
            Int64(progress.total)
        )
        table.reloadData()
        let visibleRows = min(CGFloat(max(1, progress.steps.count)), Layout.maximumVisibleRows)
        preferredContentSize = NSSize(
            width: Layout.width,
            height: 52 + visibleRows * Layout.rowHeight
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { progress.steps.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        RunPlanStepRowView(step: progress.steps[row])
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

@MainActor
private final class RunPlanStepRowView: NSTableCellView {
    init(step: RunProgress.Step) {
        super.init(frame: .zero)
        let presentation = Self.presentation(for: step.status)
        let mark = ThemedFloatingGlyphView(
            systemSymbolName: presentation.symbol,
            classicGlyph: .status,
            pointSize: Design.Symbol.control,
            accessibilityDescription: presentation.status
        )
        mark.tintColor = presentation.color
        mark.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: step.title)
        title.applyFont(.body)
        title.textColor = step.status == .pending ? Design.Text.secondary : Design.Text.label
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: presentation.status)
        status.applyFont(.caption)
        status.textColor = Design.Text.tertiary
        status.alignment = .right
        status.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mark)
        addSubview(title)
        addSubview(status)
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: Design.Spacing.small),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: Design.Spacing.medium),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            status.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(step.title)
        setAccessibilityValue(presentation.status)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func presentation(
        for status: RunProgress.Step.Status
    ) -> (symbol: String, status: String, color: NSColor) {
        switch status {
        case .pending:
            return ("circle", L10n.string("Pending"), Design.Text.tertiary)
        case .inProgress:
            return ("circle.inset.filled", L10n.string("Active"), Design.Status.warning)
        case .completed:
            return ("checkmark.circle.fill", L10n.string("Complete"), Design.Status.positive)
        }
    }
}
