import AppKit

/// Detail behind the toolbar's usage pill: every rate-limit window for the account, each
/// with its bar, percentage and reset countdown.
///
/// Content is rebuilt from the service whenever the account's entry changes, so a refresh
/// completing while the popover is open lands in front of the user rather than behind the
/// next click.
final class AccountUsagePopoverViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate {

    typealias LimitsProvider = @MainActor (AccountID) -> [CustomLimit]

    // MARK: - Properties

    private var account: AgentAccount
    private let isEmbedded: Bool
    private let readingProvider: (AgentAccount) -> AccountUsageReading
    private let limitsProvider: LimitsProvider
    private let nowProvider: () -> Date
    private var renderedAt = Date()
    private var windows: [AccountUsage.Window] = []
    private var limits: [CustomLimit] = []
    private let contentStack = NSStackView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let planLabel = NSTextField(labelWithString: "")
    private let limitLegend = UsageLimitLegendView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let keychainAccess: ClaudeKeychainAccess
    /// Said beside the stale reading it explains, so the cure sits where the symptom is.
    private let grantNotice = NSTextField(wrappingLabelWithString: "")
    private lazy var grantButton: ThemedButton = {
        let button = ThemedButton(
            title: UsageFormat.keychainGrantAction,
            target: self,
            action: #selector(grantClicked)
        )
        button.emphasis = .secondary
        button.setAccessibilityIdentifier("usage.keychainGrant")
        return button
    }()
    private lazy var grantRow: NSStackView = {
        let row = NSStackView(views: [grantNotice, grantButton])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = Design.Spacing.tight
        return row
    }()
    private let appEvents = AppEventObservations()

    private lazy var tableView: ThemedTableView = {
        let table = ThemedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("AccountUsageWindowContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: Design.Spacing.medium)
        table.rowHeight = UsagePopoverDefaults.estimatedWindowHeight
        table.usesAutomaticRowHeights = true
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = tableView
        return scroll
    }()

    private lazy var windowListHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)

    /// Fired as the pointer enters and leaves the popover, so the owning pill can keep a
    /// hover-opened popover alive while the pointer is inside it.
    var onHoverChange: ((Bool) -> Void)?

    // MARK: - Initialization

    init(
        account: AgentAccount,
        isEmbedded: Bool = false,
        readingProvider: ((AgentAccount) -> AccountUsageReading)? = nil,
        limitsProvider: @escaping LimitsProvider = {
            CustomLimitSettings.shared.rules(for: $0)
        },
        nowProvider: @escaping () -> Date = Date.init,
        keychainAccess: ClaudeKeychainAccess = .shared
    ) {
        self.account = account
        self.isEmbedded = isEmbedded
        self.keychainAccess = keychainAccess
        self.readingProvider = readingProvider ?? { AccountUsageService.shared.reading(for: $0) }
        self.limitsProvider = limitsProvider
        self.nowProvider = nowProvider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container: NSView
        if isEmbedded {
            container = NSView()
        } else {
            let trackingContainer = HoverTrackingView()
            trackingContainer.onHoverChange = { [weak self] hovering in
                self?.onHoverChange?(hovering)
            }
            container = trackingContainer
        }
        let inset = isEmbedded ? 0 : Design.Spacing.inset

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Design.Spacing.medium
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.applyFont(.control)
        nameLabel.textColor = Design.Text.label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        planLabel.applyFont(.caption)
        planLabel.textColor = Design.Text.secondary
        planLabel.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [nameLabel, planLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Design.Spacing.small

        footerLabel.applyFont(.caption)
        footerLabel.textColor = Design.Text.tertiary
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.maximumNumberOfLines = 0

        grantNotice.applyFont(.caption)
        grantNotice.textColor = Design.Text.secondary
        grantNotice.maximumNumberOfLines = 0
        grantNotice.stringValue = UsageFormat.keychainGrantNotice

        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(scrollView)
        contentStack.addArrangedSubview(limitLegend)
        contentStack.setCustomSpacing(Design.Spacing.tight, after: limitLegend)
        contentStack.addArrangedSubview(footerLabel)
        contentStack.addArrangedSubview(grantRow)
        grantNotice.widthAnchor.constraint(equalTo: grantRow.widthAnchor).isActive = true
        for arranged in [header, scrollView, limitLegend, footerLabel, grantRow] {
            arranged.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        windowListHeight.isActive = true

        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: inset
            ),
            contentStack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: inset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -inset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -inset
            ),
            contentStack.widthAnchor.constraint(
                equalToConstant: UsagePopoverDefaults.contentWidth
            )
        ])

        view = container
        render()

        appEvents.observe(AccountPreferencesDidChange.self) { [weak self] _ in
            guard let self else { return }
            if let refreshed = AgentAccountDiscovery.allAccounts(for: account.provider)
                .first(where: { $0.id == self.account.id }) {
                account = refreshed
            }
            render()
        }
        appEvents.observe(AccountUsageDidChange.self) { [weak self] event in
            self?.usageDidChange(event)
        }
        appEvents.observe(ClaudeKeychainAccessDidChange.self) { [weak self] event in
            guard let self, event.configPath == account.configPath else { return }
            render()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.fitSoleColumnToWidth()
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ThemedVirtualTableCell)?.setColumnWidth(width)
            }
        }
        fitWindowListToDocument()
    }

    // MARK: - Private Methods

    private func measuredWindowHeight() -> CGFloat? {
        guard let window = windows.first else { return nil }
        let row = UsageWindowRow(window: window, now: renderedAt, limits: limits)
        row.appearance = view.effectiveAppearance
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: UsagePopoverDefaults.contentWidth).isActive = true
        return row.fittingSize.height
    }

    private func fitWindowListToDocument() {
        guard !windows.isEmpty,
              windows.count <= UsagePopoverDefaults.maximumFittedWindowCount else { return }
        let rowExtent = tableView.rect(ofRow: windows.count - 1).maxY
        let height = min(rowExtent, UsagePopoverDefaults.maximumWindowListHeight)
        guard height > 0, windowListHeight.constant != height else { return }
        // Row rectangles include intercell spacing. The document frame also fills its viewport,
        // so using that frame would retain any excess height from the initial estimate.
        windowListHeight.constant = height
    }

    private func usageDidChange(_ event: AccountUsageDidChange) {
        guard event.accountID == account.id else { return }
        render()
    }

    private func render() {
        let origin = scrollView.contentView.bounds.origin
        let reading = readingProvider(account)
        let usage = reading.usage
        renderedAt = nowProvider()
        limits = limitsProvider(account.id)

        nameLabel.stringValue = L10n.format("%@ — %@", account.provider.displayName, account.presentation(in: .usage).visibleName)
        planLabel.stringValue = usage?.planLabel ?? ""
        planLabel.isHidden = planLabel.stringValue.isEmpty
        footerLabel.stringValue = footerText(reading: reading, now: renderedAt)
        grantRow.isHidden = !keychainAccess.offersGrant(for: account)

        // Provider-scoped model windows have no product cardinality ceiling. Keep all of their
        // value identities so the user can reach every limit, but let AppKit own the native
        // controls intersecting this bounded viewport. A fixed visible prefix would hide the
        // actual limit; a stack inside a scroll view would retain the same eager cost.
        windows = usage?.allWindows ?? []
        limitLegend.isHidden = !CustomLimitBounds.hasDrawableLine(
            in: windows,
            rules: limits,
            at: renderedAt
        )
        // Measure one row before the popover asks for its fitting size. The row's fixed three-
        // line anatomy follows live typography and bar metrics without constructing the list.
        let rowHeight = measuredWindowHeight() ?? UsagePopoverDefaults.estimatedWindowHeight
        tableView.rowHeight = rowHeight
        tableView.reloadData()
        scrollView.isHidden = windows.isEmpty
        windowListHeight.constant = min(
            CGFloat(windows.count) * (rowHeight + tableView.intercellSpacing.height),
            UsagePopoverDefaults.maximumWindowListHeight
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { windows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard windows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("AccountUsageVirtualWindow")
        let host = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        host.install(
            UsageWindowRow(
                window: windows[row],
                now: renderedAt,
                limits: limits
            ),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width
        )
        return host
    }

    /// The freshness line, with the source named when the reading is second-hand — a cached
    /// value observed an hour ago should say so rather than posing as live.
    private func footerText(reading: AccountUsageReading, now: Date) -> String {
        if let usage = reading.usage {
            let parts = [
                L10n.format("Updated %@", UsageFormat.age(of: usage.observedAt, at: now)),
                UsageFormat.sourceNote(usage.source)
            ]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }

        return reading.error?.message ?? L10n.string("Fetching usage…")
    }

    @objc private func grantClicked() {
        keychainAccess.requestAccess(for: [account])
    }

    // MARK: - Testing

    var virtualWindowCountForTesting: Int { windows.count }

    var materializedWindowCountForTesting: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                count += cell.subviews.lazy.compactMap { $0 as? UsageWindowRow }.count
            }
        }
        return count
    }

    var windowScrollOriginForTesting: NSPoint { scrollView.contentView.bounds.origin }
    var showsLimitLegendForTesting: Bool { !limitLegend.isHidden }
    var offersKeychainGrantForTesting: Bool { !grantRow.isHidden }
    var footerTextForTesting: String { footerLabel.stringValue }

    func scrollWindowToVisibleForTesting(_ row: Int) {
        guard windows.indices.contains(row) else { return }
        tableView.scrollRowToVisible(row)
    }

    func refreshForTesting() { render() }
}

// MARK: - Usage Popover Defaults

enum UsagePopoverDefaults {
    static let contentWidth: CGFloat = 240
    static let width = contentWidth + 2 * Design.Spacing.inset
    static let estimatedWindowHeight: CGFloat = 52
    static let maximumWindowListHeight: CGFloat = 312
    static let maximumFittedWindowCount = Int(maximumWindowListHeight / estimatedWindowHeight)
}
