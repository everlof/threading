import AppKit
import ThreadingController

/// One remote worker's spend, read from its host's own ledger: by day (the host's daily cells,
/// exact), by task, by trigger and by mail chain (the receipts read so far), every receipt with
/// its coverage, and the worker's daily budget with an owner edit.
///
/// Reached from Automations ▸ Remote. Nothing here reads a transcript; the host's controller is
/// the authority and this sheet is a presentation of what it says (agent-usage-ledger.md).
@MainActor
final class RemoteWorkerUsageViewController: NSViewController {
    enum Section: Int, CaseIterable {
        case days, tasks, triggers, chains, receipts

        var title: String {
            switch self {
            case .days: return L10n.string("By day")
            case .tasks: return L10n.string("By task")
            case .triggers: return L10n.string("By trigger")
            case .chains: return L10n.string("By mail chain")
            case .receipts: return L10n.string("Receipts")
            }
        }
    }

    /// Receipt pages read per press of Read more (50 receipts each), and the total retained.
    static let receiptPagesPerRead = 10
    static let maximumRetainedReceipts = 5_000

    private let host: RemoteAgentUsageHost
    private let client: RemoteAgentUsageClient
    private let service: RemoteAgentUsageService
    private var workers: [(id: String, name: String)] = []
    private var selectedWorker: String?
    private var selectedDays = 30
    private var selectedSection = Section.days
    private var hostState: RemoteAgentUsageHostState?
    private var receipts: [UsageReceipt] = []
    private var receiptCursor: Int64 = 0
    private var receiptsExhausted = false
    private var budget: WorkerBudget?
    private var projection: RemoteWorkerUsageProjection?
    private var busy = false
    private var loadTask: Task<Void, Never>?

    private let titleLabel = NSTextField(labelWithString: "")
    private let freshnessLabel = NSTextField(wrappingLabelWithString: "")
    private let workerPopUp = ThemedPopUp()
    private let refreshButton = ThemedButton()
    private let budgetLabel = NSTextField(wrappingLabelWithString: "")
    private let budgetButton = ThemedButton()
    private let totalLabel = NSTextField(wrappingLabelWithString: "")
    private let rangeControl = ThemedSegmentedControl()
    private let sectionControl = ThemedSegmentedControl()
    private let table = ThemedLedgerTableView(visibleRows: 10)
    private let receiptsLabel = NSTextField(wrappingLabelWithString: "")
    private let moreButton = ThemedButton()
    private let status = NSTextField(wrappingLabelWithString: "")

    init(host: RemoteAgentUsageHost, initialWorker: String? = nil,
         client: RemoteAgentUsageClient = RemoteAgentUsageClient(), service: RemoteAgentUsageService = .shared) {
        self.host = host; self.client = client; self.service = service
        self.selectedWorker = initialWorker
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Testing

    var tableForTesting: ThemedLedgerTableView { table }
    var budgetTextForTesting: String { budgetLabel.stringValue }
    var freshnessTextForTesting: String { freshnessLabel.stringValue }
    var receiptsTextForTesting: String { receiptsLabel.stringValue }
    func selectSectionForTesting(_ section: Section) { selectSection(section) }

    /// Presents prepared values without a host round trip: the render tests' entry point.
    func showForTesting(workers: [(id: String, name: String)], state: RemoteAgentUsageHostState,
                        receipts: [UsageReceipt], budget: WorkerBudget?, now: Date) {
        _ = view
        self.workers = workers
        selectedWorker = selectedWorker ?? workers.first?.id
        configureWorkerPopUp()
        hostState = state
        self.receipts = receipts
        self.budget = budget
        receiptsExhausted = true
        reproject(now: now)
    }

    // MARK: - View

    override func loadView() {
        let surface = ThemedSurfaceView()
        surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        surface.frame = NSRect(x: 0, y: 0, width: Design.Size.settingsContentWidth + Design.Spacing.pane * 2,
                               height: Design.RemoteWorkerUsage.sheetHeight)
        view = surface

        titleLabel.applyFont(.heading)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        for label in [freshnessLabel, budgetLabel, totalLabel, receiptsLabel, status] {
            label.applyFont(.detail()); label.textColor = Design.Text.secondary
        }
        totalLabel.applyFont(.body); totalLabel.textColor = Design.Text.label

        workerPopUp.target = self; workerPopUp.action = #selector(workerChanged)
        workerPopUp.setAccessibilityLabel(L10n.string("Worker"))
        refreshButton.title = L10n.string("Refresh"); refreshButton.target = self; refreshButton.action = #selector(refreshPressed)
        budgetButton.title = L10n.string("Edit budget…"); budgetButton.target = self; budgetButton.action = #selector(editBudgetPressed)
        budgetButton.setAccessibilityIdentifier("worker.usage.budget.edit")
        moreButton.title = L10n.string("Read more receipts"); moreButton.target = self; moreButton.action = #selector(morePressed)

        rangeControl.configure(titles: ["7d", "30d", "90d"], selectedIndex: 1)
        rangeControl.setAccessibilityLabel(L10n.string("Usage date range"))
        rangeControl.onSelect = { [weak self] index in
            guard let self else { return }
            self.selectedDays = [7, 30, 90][min(max(index, 0), 2)]
            self.reproject(now: Date())
        }
        sectionControl.configure(titles: Section.allCases.map(\.title), selectedIndex: 0)
        sectionControl.setAccessibilityLabel(L10n.string("Worker usage breakdown"))
        sectionControl.onSelect = { [weak self] index in
            guard let section = Section(rawValue: index) else { return }
            self?.selectSection(section)
        }

        let done = ThemedButton(); done.title = L10n.string("Done"); done.target = self; done.action = #selector(donePressed)
        done.keyEquivalent = "\u{1b}"

        let workerRow = NSStackView(views: [workerPopUp, refreshButton, NSView()])
        workerRow.orientation = .horizontal; workerRow.spacing = Design.Spacing.small
        let budgetRow = NSStackView(views: [budgetLabel, budgetButton])
        budgetRow.orientation = .horizontal; budgetRow.spacing = Design.Spacing.medium; budgetRow.alignment = .centerY
        budgetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [sectionControl, NSView(), rangeControl])
        controls.orientation = .horizontal; controls.spacing = Design.Spacing.medium
        let receiptRow = NSStackView(views: [receiptsLabel, moreButton])
        receiptRow.orientation = .horizontal; receiptRow.spacing = Design.Spacing.medium; receiptRow.alignment = .centerY
        receiptsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, done])
        footer.orientation = .horizontal; footer.spacing = Design.Spacing.medium
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, freshnessLabel, workerRow, budgetRow, totalLabel, controls, table,
                                        receiptRow, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.pane),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -Design.Spacing.pane)
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        titleLabel.stringValue = L10n.format("Agent usage on %@", host.name)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard loadTask == nil, workers.isEmpty else { return }
        load(refreshingSummary: false)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        loadTask?.cancel()
    }

    // MARK: - Loading

    /// Worker names, the cached summary (read fresh when absent or asked), the budget and the
    /// first receipt pages. Every read is off the main actor; this only assigns results.
    private func load(refreshingSummary: Bool) {
        guard !busy else { return }
        busy = true
        status.stringValue = L10n.string("Reading the host's ledger…")
        let host = host, client = client, service = service
        loadTask = Task { [weak self] in
            defer { self?.busy = false; self?.loadTask = nil }
            do {
                var states = await service.states(for: [host])
                if refreshingSummary || states.first?.snapshot == nil {
                    await service.refresh(host: host)
                    states = await service.states(for: [host])
                }
                let state = states.first
                var names = state?.snapshot?.workerNames ?? [:]
                if names.isEmpty {
                    let read = try await client.workers(endpoint: host.endpoint, destination: host.destination)
                    names = Dictionary(read.map { ($0.id.description, $0.name) }, uniquingKeysWith: { first, _ in first })
                }
                guard let self, !Task.isCancelled else { return }
                self.hostState = state
                self.workers = names.map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
                if self.selectedWorker.map({ names[$0] == nil }) ?? true { self.selectedWorker = self.workers.first?.id }
                self.configureWorkerPopUp()
                self.status.stringValue = state?.lastFailure ?? ""
                self.busy = false
                await self.loadWorker()
            } catch {
                self?.status.stringValue = error.localizedDescription
            }
        }
    }

    /// The selected worker's budget and its first receipt pages.
    private func loadWorker() async {
        receipts = []; receiptCursor = 0; receiptsExhausted = false; budget = nil
        reproject(now: Date())
        guard let worker = selectedWorker.flatMap({ try? WorkerID($0) }) else { return }
        do {
            budget = try await client.budget(endpoint: host.endpoint, destination: host.destination, worker: worker)
        } catch {
            status.stringValue = error.localizedDescription
        }
        await readReceipts(worker)
    }

    private func readReceipts(_ worker: WorkerID) async {
        busy = true; moreButton.isEnabled = false
        defer { busy = false; moreButton.isEnabled = !receiptsExhausted }
        do {
            for _ in 0..<Self.receiptPagesPerRead {
                guard receipts.count < Self.maximumRetainedReceipts, !Task.isCancelled else { break }
                let page = try await client.receipts(endpoint: host.endpoint, destination: host.destination,
                                                     worker: worker, cursor: receiptCursor)
                guard selectedWorker == worker.description else { return }
                if page.items.isEmpty { receiptsExhausted = true; break }
                guard page.next > receiptCursor else { throw RemoteAgentUsageError.cursorDidNotAdvance }
                receipts.append(contentsOf: page.items.prefix(Self.maximumRetainedReceipts - receipts.count))
                receiptCursor = page.next
            }
        } catch {
            status.stringValue = error.localizedDescription
        }
        reproject(now: Date())
    }

    // MARK: - Presentation

    private func configureWorkerPopUp() {
        workerPopUp.removeAllItems()
        for worker in workers { workerPopUp.addItem(withTitle: worker.name) }
        if let index = workers.firstIndex(where: { $0.id == selectedWorker }) { workerPopUp.selectItem(at: index) }
        workerPopUp.isEnabled = !workers.isEmpty
        budgetButton.isEnabled = selectedWorker != nil
    }

    /// O(cells + receipts read) on the main actor: both are bounded (5,000 cells per host by
    /// the summary page budget, 5,000 receipts by `maximumRetainedReceipts`).
    private func reproject(now: Date) {
        guard let worker = selectedWorker.flatMap({ try? WorkerID($0) }) else {
            projection = nil
            table.show(columns: columns(for: selectedSection), rows: [], accessibilityLabel: selectedSection.title)
            totalLabel.stringValue = L10n.string("This host has no workers yet.")
            budgetLabel.stringValue = ""
            return
        }
        let projection = RemoteWorkerUsageProjection.make(
            worker: worker, cells: hostState?.snapshot?.cells ?? [], receipts: receipts, days: selectedDays, now: now)
        self.projection = projection
        freshnessLabel.stringValue = freshnessText(now: now)
        freshnessLabel.textColor = {
            if case .current = hostState?.freshness(now: now) { return Design.Text.secondary }
            return Design.Status.warning
        }()
        totalLabel.stringValue = L10n.format(
            "%@ · %@ tokens · %lld executions in the last %lld days",
            UsageFormat.currency(projection.total.costUSD), UsageFormat.tokens(projection.total.tokens.processed),
            projection.total.executions, Int64(selectedDays))
        budgetLabel.stringValue = budgetText(today: projection.today)
        let incomplete = projection.incompleteReceipts
        receiptsLabel.stringValue = (receiptsExhausted
            ? L10n.format("%lld receipts in range, all read.", Int64(projection.receiptsRead))
            : L10n.format("%lld receipts in range from the first %lld read; more are on the host.",
                          Int64(projection.receiptsRead), Int64(receipts.count)))
            + (incomplete > 0 ? " " + L10n.format("%lld are partial, failed or unavailable: their spend is missing or short.", Int64(incomplete)) : "")
        receiptsLabel.textColor = incomplete > 0 ? Design.Status.warning : Design.Text.secondary
        moreButton.isHidden = receiptsExhausted
        renderTable()
    }

    private func freshnessText(now: Date) -> String {
        guard let state = hostState else { return "" }
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .abbreviated
        switch state.freshness(now: now) {
        case .unread:
            return L10n.string("The host's daily totals have not been read yet.")
        case .current:
            let at = state.snapshot.map { formatter.localizedString(for: $0.fetchedAt, relativeTo: now) } ?? ""
            return L10n.format("Daily totals read %@. Days are UTC, as the host records them.", at)
        case .stale(let since):
            return L10n.format("Daily totals are from %@; the host could not be read since. They are its last summary, not zero.",
                               formatter.localizedString(for: since, relativeTo: now))
        }
    }

    private func budgetText(today: AgentUsageProjector.Total) -> String {
        guard let limit = budget?.tokensPerDay else {
            return L10n.format("No daily budget. Today: %@ budget tokens.", UsageFormat.tokens(today.budgetTokens))
        }
        let share = UsageFormat.share(limit > 0 ? Double(today.budgetTokens) / Double(limit) : 0)
        return L10n.format("Daily budget %@ tokens. Today: %@ (%@). New executions stop at the budget; running ones are never stopped.",
                           UsageFormat.tokens(limit), UsageFormat.tokens(today.budgetTokens), share)
    }

    private func selectSection(_ section: Section) {
        selectedSection = section
        sectionControl.selectedIndex = section.rawValue
        renderTable()
    }

    private func columns(for section: Section) -> [ThemedLedgerTableView.Column] {
        let cost = ThemedLedgerTableView.Column(title: L10n.string("Cost"), width: Design.UsageDashboard.breakdownCostColumnWidth)
        let tokens = ThemedLedgerTableView.Column(title: L10n.string("Tokens"), width: Design.UsageDashboard.breakdownTokensColumnWidth)
        let count = { (title: String) in ThemedLedgerTableView.Column(title: title, width: Design.RemoteWorkerUsage.countColumnWidth) }
        let name = { (title: String) in
            ThemedLedgerTableView.Column(title: title, width: Design.RemoteWorkerUsage.nameColumnWidth, alignment: .leading)
        }
        switch section {
        case .days: return [name(L10n.string("Day")), count(L10n.string("Executions")), count(L10n.string("Requests")), tokens, cost]
        case .tasks: return [name(L10n.string("Task")), count(L10n.string("Executions")), count(L10n.string("Incomplete")), tokens, cost]
        case .triggers: return [name(L10n.string("Trigger")), count(L10n.string("Executions")), count(L10n.string("Incomplete")), tokens, cost]
        case .chains: return [name(L10n.string("Mail chain")), count(L10n.string("Executions")), count(L10n.string("Incomplete")), tokens, cost]
        case .receipts:
            return [name(L10n.string("Ended")),
                    ThemedLedgerTableView.Column(title: L10n.string("Coverage"), width: Design.RemoteWorkerUsage.coverageColumnWidth,
                                                 alignment: .leading),
                    count(L10n.string("Task")), tokens, cost]
        }
    }

    private func renderTable() {
        let projection = projection
        let rows: [ThemedLedgerTableView.Row]
        switch selectedSection {
        case .days:
            rows = (projection?.days ?? []).map {
                .init(values: [$0.day, $0.total.executions.formatted(), $0.total.requests.formatted(),
                               UsageFormat.tokens($0.total.tokens.processed), UsageFormat.currency($0.total.costUSD)])
            }
        case .tasks:
            rows = (projection?.byTask ?? []).map { group(String($0.key.prefix(8)), $0) }
        case .triggers:
            rows = (projection?.byTrigger ?? []).map { group($0.key.isEmpty ? L10n.string("Not from a trigger") : $0.key, $0) }
        case .chains:
            rows = (projection?.byChain ?? []).map { group(String($0.key.prefix(8)), $0) }
        case .receipts:
            rows = (projection?.executions ?? []).map { execution in
                .init(values: [Self.endedText(execution.endedAt), Self.coverageText(execution.coverage),
                               String(execution.workID.prefix(8)), UsageFormat.tokens(execution.tokens),
                               UsageFormat.currency(execution.costUSD)],
                      warningColumns: execution.coverage == .complete ? [] : [1],
                      accessibilityDetail: execution.reason)
            }
        }
        table.show(columns: columns(for: selectedSection), rows: rows, accessibilityLabel: selectedSection.title)
    }

    private func group(_ name: String, _ group: RemoteWorkerUsageProjection.Group) -> ThemedLedgerTableView.Row {
        .init(values: [name, group.executions.formatted(), group.incomplete.formatted(),
                       UsageFormat.tokens(group.tokens), UsageFormat.currency(group.costUSD)],
              warningColumns: group.incomplete > 0 ? [2] : [])
    }

    static func coverageText(_ coverage: UsageCoverage) -> String {
        switch coverage {
        case .complete: return L10n.string("Complete")
        case .partial: return L10n.string("Partial")
        case .failed: return L10n.string("Failed")
        case .unavailable: return L10n.string("Unavailable")
        }
    }

    /// `2026-10-03T09:41:07Z` as `2026-10-03 09:41` — UTC, as the host wrote it.
    static func endedText(_ endedAt: String) -> String {
        String(endedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    // MARK: - Actions

    @objc private func workerChanged() {
        guard workers.indices.contains(workerPopUp.indexOfSelectedItem) else { return }
        selectedWorker = workers[workerPopUp.indexOfSelectedItem].id
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadWorker() }
    }

    @objc private func refreshPressed() { load(refreshingSummary: true) }

    @objc private func morePressed() {
        guard !busy, let worker = selectedWorker.flatMap({ try? WorkerID($0) }) else { return }
        Task { [weak self] in await self?.readReceipts(worker) }
    }

    @objc private func donePressed() { presentingViewController?.dismiss(self) }

    /// The owner mutation. The sheet that asks also takes the new value, names the worker, the
    /// host and the exact limit, and the controller refuses a stale revision.
    @objc private func editBudgetPressed() {
        guard !busy, let window = view.window,
              let workerText = selectedWorker, let worker = try? WorkerID(workerText) else { return }
        let name = workers.first { $0.id == workerText }?.name ?? workerText
        let field = ThemedTextField()
        field.placeholderString = L10n.string("No limit")
        field.stringValue = budget?.tokensPerDay.map(String.init) ?? ""
        field.setAccessibilityLabel(L10n.string("Daily budget in tokens"))
        field.widthAnchor.constraint(equalToConstant: Design.RemoteWorkerUsage.budgetFieldWidth).isActive = true
        let request = ConfirmationRequest(
            prompt: .changeWorkerBudget,
            title: L10n.format("Change the daily budget for “%@” on %@?", name, host.name),
            message: L10n.string("Budget tokens are uncached input, cache writes and output for the UTC day. At the budget the host's supervisor starts no new executions for this worker; running ones are never stopped. Leave the field empty for no limit."),
            confirmTitle: L10n.string("Set budget"),
            accessory: field
        )
        let expected = budget?.revision ?? 0
        ConfirmationAlert.ask(request, in: window) { [weak self] approved in
            guard let self, approved else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens: Int64?
            if text.isEmpty { tokens = nil } else if let value = Int64(text), value > 0 { tokens = value } else {
                self.status.stringValue = L10n.string("A daily budget is a whole number of tokens above zero, or empty for no limit.")
                return
            }
            self.setBudget(worker, expectedRevision: expected, tokensPerDay: tokens)
        }
    }

    private func setBudget(_ worker: WorkerID, expectedRevision: Int, tokensPerDay: Int64?) {
        busy = true
        status.stringValue = L10n.string("Saving the budget on the host…")
        let host = host, client = client
        Task { [weak self] in
            do {
                let saved = try await client.setBudget(endpoint: host.endpoint, destination: host.destination,
                                                       worker: worker, expectedRevision: expectedRevision, tokensPerDay: tokensPerDay)
                guard let self else { return }
                self.busy = false
                self.budget = saved
                self.status.stringValue = L10n.string("Budget saved on the host.")
                self.reproject(now: Date())
            } catch {
                guard let self else { return }
                self.busy = false
                // A conflict means someone else changed it: show theirs rather than retrying ours.
                self.status.stringValue = error.localizedDescription
                self.budget = try? await client.budget(endpoint: host.endpoint, destination: host.destination, worker: worker)
                self.reproject(now: Date())
            }
        }
    }
}
