import AppKit

/// One account in the live-capacity fleet.
///
/// Kept as a value so discovery and usage reads happen once per refresh. The table can then ask
/// for any visible row without touching the filesystem or a provider endpoint.
struct AccountUsageFleetItem: Equatable {
    let account: AgentAccount
    let reading: AccountUsageReading
    let isCurrent: Bool
    let allowsHandoff: Bool
}

/// Aggregate language for unlike provider windows.
///
/// There is deliberately no average percentage: averaging a five-hour window with a weekly or
/// model-scoped window manufactures a number no provider enforces. The aggregate says how many
/// accounts are usable, under pressure, or not yet known, and names the next real reset.
struct AccountUsageFleetSummary: Equatable {
    let accountCount: Int
    let readyCount: Int
    let constrainedCount: Int
    let unknownCount: Int
    let nextReset: Date?

    init(items: [AccountUsageFleetItem], now: Date = Date()) {
        accountCount = items.count
        var ready = 0
        var constrained = 0
        var unknown = 0
        var resets: [Date] = []

        for item in items {
            guard let usage = item.reading.usage else {
                unknown += 1
                continue
            }
            let active = usage.allWindows.filter { !$0.isExpired(at: now) }
            resets.append(contentsOf: active.compactMap(\.resetsAt))
            let known = active.compactMap(\.fraction)
            guard !known.isEmpty else {
                unknown += 1
                continue
            }
            if known.contains(where: { $0 >= UsageDefaults.warningFraction }) {
                constrained += 1
            } else {
                ready += 1
            }
        }

        readyCount = ready
        constrainedCount = constrained
        unknownCount = unknown
        nextReset = resets.min()
    }

    fileprivate init(
        accountCount: Int,
        readyCount: Int,
        constrainedCount: Int,
        unknownCount: Int,
        nextReset: Date?
    ) {
        self.accountCount = accountCount
        self.readyCount = readyCount
        self.constrainedCount = constrainedCount
        self.unknownCount = unknownCount
        self.nextReset = nextReset
    }

    var statusText: String {
        var parts: [String] = []
        if readyCount > 0 { parts.append(L10n.format("%d ready", readyCount)) }
        if constrainedCount > 0 {
            parts.append(L10n.format("%d constrained", constrainedCount))
        }
        if unknownCount > 0 { parts.append(L10n.format("%d unknown", unknownCount)) }
        return parts.isEmpty ? L10n.string("No enabled accounts") : parts.joined(separator: " · ")
    }
}

/// Identity-indexed aggregate state for live fleet updates.
///
/// Counts change in O(1), while the next reset lives in an indexed min-heap and changes in
/// O(log n). A single account notification therefore cannot turn into another fleet-wide scan.
private struct AccountUsageFleetSummaryIndex {
    private enum Status { case ready, constrained, unknown }

    private struct Contribution {
        let status: Status
        let nextReset: Date?
    }

    private struct ResetNode {
        let accountID: AccountID
        var date: Date
    }

    private var contributions: [AccountID: Contribution] = [:]
    private var resetHeap: [ResetNode] = []
    private var resetPositions: [AccountID: Int] = [:]
    private(set) var readyCount = 0
    private(set) var constrainedCount = 0
    private(set) var unknownCount = 0

    var summary: AccountUsageFleetSummary {
        AccountUsageFleetSummary(
            accountCount: contributions.count,
            readyCount: readyCount,
            constrainedCount: constrainedCount,
            unknownCount: unknownCount,
            nextReset: resetHeap.first?.date
        )
    }

    mutating func rebuild(items: [AccountUsageFleetItem], now: Date) {
        self = AccountUsageFleetSummaryIndex()
        for item in items { update(item: item, now: now) }
    }

    mutating func update(item: AccountUsageFleetItem, now: Date) {
        let id = item.account.id
        if let previous = contributions[id] { remove(previous.status) }

        let contribution = Self.contribution(for: item, now: now)
        contributions[id] = contribution
        add(contribution.status)
        setReset(contribution.nextReset, for: id)
    }

    private static func contribution(
        for item: AccountUsageFleetItem,
        now: Date
    ) -> Contribution {
        guard let usage = item.reading.usage else {
            return Contribution(status: .unknown, nextReset: nil)
        }
        let active = usage.allWindows.filter { !$0.isExpired(at: now) }
        let known = active.compactMap(\.fraction)
        let status: Status
        if known.isEmpty {
            status = .unknown
        } else if known.contains(where: { $0 >= UsageDefaults.warningFraction }) {
            status = .constrained
        } else {
            status = .ready
        }
        return Contribution(
            status: status,
            nextReset: active.compactMap(\.resetsAt).min()
        )
    }

    private mutating func add(_ status: Status) {
        switch status {
        case .ready: readyCount += 1
        case .constrained: constrainedCount += 1
        case .unknown: unknownCount += 1
        }
    }

    private mutating func remove(_ status: Status) {
        switch status {
        case .ready: readyCount -= 1
        case .constrained: constrainedCount -= 1
        case .unknown: unknownCount -= 1
        }
    }

    private mutating func setReset(_ date: Date?, for accountID: AccountID) {
        if let index = resetPositions[accountID] {
            guard let date else {
                removeReset(at: index)
                return
            }
            let previous = resetHeap[index].date
            resetHeap[index].date = date
            if date < previous { siftUp(from: index) } else { siftDown(from: index) }
        } else if let date {
            resetHeap.append(ResetNode(accountID: accountID, date: date))
            let index = resetHeap.index(before: resetHeap.endIndex)
            resetPositions[accountID] = index
            siftUp(from: index)
        }
    }

    private mutating func removeReset(at index: Int) {
        let removedID = resetHeap[index].accountID
        let last = resetHeap.index(before: resetHeap.endIndex)
        if index != last { swapNodes(index, last) }
        resetHeap.removeLast()
        resetPositions.removeValue(forKey: removedID)
        guard index < resetHeap.count else { return }
        let parent = (index - 1) / 2
        if index > 0, isEarlier(resetHeap[index], than: resetHeap[parent]) {
            siftUp(from: index)
        } else {
            siftDown(from: index)
        }
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard isEarlier(resetHeap[child], than: resetHeap[parent]) else { break }
            swapNodes(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            guard left < resetHeap.count else { return }
            let right = left + 1
            let child = right < resetHeap.count
                && isEarlier(resetHeap[right], than: resetHeap[left]) ? right : left
            guard isEarlier(resetHeap[child], than: resetHeap[parent]) else { return }
            swapNodes(parent, child)
            parent = child
        }
    }

    private func isEarlier(_ lhs: ResetNode, than rhs: ResetNode) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.accountID.rawValue < rhs.accountID.rawValue
    }

    private mutating func swapNodes(_ lhs: Int, _ rhs: Int) {
        resetHeap.swapAt(lhs, rhs)
        resetPositions[resetHeap[lhs].accountID] = lhs
        resetPositions[resetHeap[rhs].accountID] = rhs
    }
}

/// A bounded, virtualized run of every enabled account's live usage windows.
///
/// Usage settings and the Option-click toolbar popover share this exact hierarchy. The header is
/// retained because it is constant-size; account cards are table rows, so provider/account
/// cardinality affects cheap values and scroll extent rather than view construction at open.
final class AccountUsageFleetView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    typealias LimitsProvider = @MainActor (AccountID) -> [CustomLimit]

    enum ScrollHost: Equatable {
        /// The fleet is the only vertical viewport, as in the pinned toolbar popover.
        case standalone
        /// The fleet is embedded in a vertically scrolling page, as in Usage settings.
        case nestedPage
    }

    private let maximumHeight: CGFloat
    private let scrollHost: ScrollHost
    private let limitsProvider: LimitsProvider
    private let summaryTitle = NSTextField(labelWithString: "")
    private let summaryStatus = NSTextField(labelWithString: "")
    private let summaryReset = NSTextField(labelWithString: "")
    private let limitLegend = UsageLimitLegendView()
    private let table = ThemedTableView()
    private let scroll = ThemedScrollView()
    private lazy var heightConstraint = scroll.heightAnchor.constraint(
        equalToConstant: Design.AccountUsageFleet.minimumViewportHeight
    )
    private var items: [AccountUsageFleetItem] = []
    private var indexByAccountID: [AccountID: Int] = [:]
    private var limitsByAccountID: [AccountID: [CustomLimit]] = [:]
    private var summaryIndex = AccountUsageFleetSummaryIndex()
    private var estimatedContentHeight: CGFloat = 0
    private var now = Date()

    var onHandoff: ((AgentAccount) -> Void)?

    var itemCountForTesting: Int { items.count }
    var visibleCellCountForTesting: Int {
        guard !table.visibleRect.isEmpty else { return 0 }
        return table.rows(in: table.visibleRect).length
    }
    var viewportHeightForTesting: CGFloat { heightConstraint.constant }
    var summaryForTesting: AccountUsageFleetSummary { summaryIndex.summary }
    var orderedAccountIDsForTesting: [AccountID] { items.map(\.account.id) }
    var verticalScrollHandoffForTesting: ThemedScrollView.VerticalScrollHandoff {
        scroll.verticalScrollHandoff
    }
    var showsLimitLegendForTesting: Bool { !limitLegend.isHidden }

    init(
        maximumHeight: CGFloat = Design.AccountUsageFleet.settingsMaximumHeight,
        scrollHost: ScrollHost = .standalone,
        limitsProvider: @escaping LimitsProvider = {
            CustomLimitSettings.shared.rules(for: $0)
        }
    ) {
        self.maximumHeight = maximumHeight
        self.scrollHost = scrollHost
        self.limitsProvider = limitsProvider
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ newItems: [AccountUsageFleetItem], at now: Date = Date()) {
        self.now = now
        items = Self.stablyOrdered(newItems)
        indexByAccountID = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { ($0.element.account.id, $0.offset) }
        )
        limitsByAccountID = Dictionary(uniqueKeysWithValues: items.map {
            ($0.account.id, limitsProvider($0.account.id))
        })
        summaryIndex.rebuild(items: items, now: now)
        estimatedContentHeight = items.reduce(CGFloat.zero) { partial, item in
            partial + estimatedHeight(for: item) + Design.AccountUsageFleet.accountGap
        }
        applySummary()
        applyLimitLegend()
        table.reloadData()
        applyViewportHeight()
    }

    /// Replaces one identity's reading without rediscovering, sorting, or rebuilding the fleet.
    /// Returns false when the account is not part of this presentation generation.
    @discardableResult
    func update(reading: AccountUsageReading, for accountID: AccountID) -> Bool {
        guard let index = indexByAccountID[accountID], items.indices.contains(index) else {
            return false
        }

        let previous = items[index]
        let updated = AccountUsageFleetItem(
            account: previous.account,
            reading: reading,
            isCurrent: previous.isCurrent,
            allowsHandoff: previous.allowsHandoff
        )
        items[index] = updated
        summaryIndex.update(item: updated, now: now)
        estimatedContentHeight += estimatedHeight(for: updated) - estimatedHeight(for: previous)
        applySummary()
        applyLimitLegend()
        applyViewportHeight()

        let rows = IndexSet(integer: index)
        table.noteHeightOfRows(withIndexesChanged: rows)
        table.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)
        )
        return true
    }

    private func applySummary() {
        let summary = summaryIndex.summary
        summaryTitle.stringValue = L10n.format("All Accounts · %d", summary.accountCount)
        summaryStatus.stringValue = summary.statusText
        summaryReset.stringValue = summary.nextReset.map {
            L10n.format("Next reset in %@", UsageFormat.remaining(until: $0, from: now))
        } ?? ""
    }

    private func applyLimitLegend() {
        limitLegend.isHidden = !items.contains { item in
            guard let usage = item.reading.usage else { return false }
            let visible = Array(usage.allWindows.lazy
                .filter { !$0.isExpired(at: self.now) }
                .prefix(Design.AccountUsageFleet.maximumWindowsPerAccount))
            return CustomLimitBounds.hasDrawableLine(
                in: visible,
                rules: limitsByAccountID[item.account.id] ?? [],
                at: now
            )
        }
    }

    static func stablyOrdered(_ items: [AccountUsageFleetItem]) -> [AccountUsageFleetItem] {
        items.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            let providerOrder = $0.account.provider.displayName.localizedStandardCompare(
                $1.account.provider.displayName
            )
            if providerOrder != .orderedSame { return providerOrder == .orderedAscending }
            let nameOrder = $0.account.displayName.localizedStandardCompare($1.account.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.account.id.rawValue < $1.account.id.rawValue
        }
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        summaryTitle.applyFont(.body)
        summaryTitle.textColor = Design.Text.label
        summaryStatus.applyFont(.subheading)
        summaryStatus.textColor = Design.Text.secondary
        summaryReset.applyFont(.caption)
        summaryReset.textColor = Design.Text.tertiary

        let summaryLabels = NSStackView(views: [summaryTitle, summaryStatus])
        summaryLabels.orientation = .vertical
        summaryLabels.alignment = .leading
        summaryLabels.spacing = Design.Spacing.hairline
        summaryLabels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let summaryRow = NSStackView(views: [summaryLabels, spacer, summaryReset])
        summaryRow.orientation = .horizontal
        summaryRow.alignment = .centerY
        summaryRow.spacing = Design.Spacing.medium

        // This view is asked for a fitting size before the popover has appeared in a window.
        // Seed the document at that known viewport width so AppKit's first automatic-height pass
        // measures the same lines it will actually paint. The autoresizing mask below takes over
        // as soon as a settings page or resized popover supplies a different clip width.
        table.frame = NSRect(
            x: 0,
            y: 0,
            width: Design.AccountUsageFleet.popoverWidth - Design.Spacing.inset * 2,
            height: Design.AccountUsageFleet.minimumViewportHeight
        )
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("UsageFleetAccount"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        // Account cards own their own insets and rounded surface. A plain/inset table adds a
        // second platform gutter around each recycled row, making this compact popover read like
        // a narrow list inside a list.
        table.style = .fullWidth
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: Design.AccountUsageFleet.accountGap)
        table.rowHeight = Design.AccountUsageFleet.estimatedBaseRowHeight
        // Every child has a bounded, fixed line shape. Returning that height from the cheap item
        // value avoids AppKit retaining an automatic-height measured at the table's pre-popover
        // fitting width, which otherwise leaves phantom space between recycled cards.
        table.usesAutomaticRowHeights = false
        // An NSTableView installed as a scroll view's document view does not inherit the clip
        // width through Auto Layout. Keep the document and its sole column tracking the viewport;
        // otherwise its launch-time fitting width becomes permanent, cards render too narrow,
        // and AppKit's automatic-height cache spaces later rows using those wrapped measurements.
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalScrollHandoff = scrollHost == .nestedPage ? .atContentEnds : .never

        let content = NSStackView(views: [summaryRow, scroll, limitLegend])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            summaryRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            limitLegend.widthAnchor.constraint(equalTo: content.widthAnchor),
            heightConstraint
        ])

        show([])
        setAccessibilityIdentifier("usage.current-capacity")
    }

    private func applyViewportHeight() {
        heightConstraint.constant = min(
            max(estimatedContentHeight, Design.AccountUsageFleet.minimumViewportHeight),
            maximumHeight
        )
    }

    override func layout() {
        super.layout()
        table.fitSoleColumnToWidth()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else {
            return Design.AccountUsageFleet.estimatedBaseRowHeight
        }
        return estimatedHeight(for: items[row])
    }

    private func estimatedHeight(for item: AccountUsageFleetItem) -> CGFloat {
        let windows = min(
            item.reading.usage?.allWindows.filter { !$0.isExpired(at: now) }.count ?? 0,
            Design.AccountUsageFleet.maximumWindowsPerAccount
        )
        let action = item.allowsHandoff ? Design.AccountUsageFleet.estimatedActionHeight : 0
        return Design.AccountUsageFleet.estimatedBaseRowHeight
            + CGFloat(windows) * Design.AccountUsageFleet.estimatedWindowRowHeight
            + action
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("UsageFleetVirtualAccount")
        let host = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        let item = items[row]
        let card = AccountUsageFleetCardView(
            item: item,
            now: now,
            limits: limitsByAccountID[item.account.id] ?? []
        )
        card.onHandoff = { [weak self] account in self?.onHandoff?(account) }
        host.install(
            card,
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            // These cards deliberately use a non-glowing panel surface, so the 48-point halo
            // clearance used by glowing settings panels would only become empty row padding.
            horizontalInset: Design.Spacing.hairline,
            topInset: Design.Spacing.hairline,
            bottomInset: Design.Spacing.hairline
        )
        return host
    }
}

private final class AccountUsageFleetCardView: NSView {
    private let item: AccountUsageFleetItem
    private let now: Date
    private let limits: [CustomLimit]
    var onHandoff: ((AgentAccount) -> Void)?

    init(item: AccountUsageFleetItem, now: Date, limits: [CustomLimit]) {
        self.item = item
        self.now = now
        self.limits = limits
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        wantsLayer = true
        applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)

        let icon = NSImageView(image: item.account.provider.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = Design.Text.secondary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(
            labelWithString: "\(item.account.provider.displayName) — \(item.account.displayName)"
        )
        title.applyFont(.body)
        title.textColor = Design.Text.label
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let details = [item.account.handle.name, item.reading.usage?.planLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let subtitle = NSTextField(labelWithString: details)
        subtitle.applyFont(.caption)
        subtitle.textColor = Design.Text.secondary
        subtitle.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        let status = NSTextField(labelWithString: item.isCurrent ? L10n.string("Current") : "")
        status.applyFont(.caption)
        status.textColor = Design.Text.tertiary

        let header = NSStackView(views: [icon, labels, status])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Design.Spacing.small

        var content: [NSView] = [header]
        if let usage = item.reading.usage {
            let activeWindows = usage.allWindows.filter { !$0.isExpired(at: now) }
            let windows = Array(activeWindows.prefix(
                Design.AccountUsageFleet.maximumWindowsPerAccount
            ))
            content.append(contentsOf: windows.map {
                UsageWindowRow(
                    window: $0,
                    now: now,
                    limits: limits
                )
            })
            if windows.isEmpty {
                content.append(caption(L10n.string("No active windows")))
            }
            let hidden = activeWindows.count - windows.count
            if hidden > 0 {
                content.append(caption(L10n.format("%d more windows", hidden)))
            }
        }

        content.append(caption(footerText))

        if item.allowsHandoff {
            let button = ThemedButton(
                title: L10n.string("Move to Account"),
                target: self,
                action: #selector(handoffClicked)
            )
            button.emphasis = .secondary
            button.setAccessibilityIdentifier("usage.handoff.\(item.account.id.rawValue)")
            content.append(button)
        }

        let stack = NSStackView(views: content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Design.AccountUsageFleet.providerIconSize),
            icon.heightAnchor.constraint(equalToConstant: Design.AccountUsageFleet.providerIconSize),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Design.AccountUsageFleet.accountCardInset
            ),
            stack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Design.AccountUsageFleet.accountCardInset
            ),
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.AccountUsageFleet.accountCardInset
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.AccountUsageFleet.accountCardInset
            )
        ])
        for row in content.dropFirst() {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(item.account.provider.displayName), \(item.account.displayName)")
    }

    private var footerText: String {
        if let usage = item.reading.usage {
            var parts = [L10n.format("Updated %@", UsageFormat.age(of: usage.observedAt))]
            if usage.source == .localCache {
                parts.append(L10n.string("via Claude's status-line feed"))
            }
            if case .stale = item.reading { parts.append(L10n.string("stale")) }
            return parts.joined(separator: " · ")
        }
        return item.reading.error?.message ?? L10n.string("Fetching usage…")
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    @objc private func handoffClicked() {
        onHandoff?(item.account)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
    }
}
