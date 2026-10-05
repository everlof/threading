import AppKit

@MainActor
final class TriggerCenterViewController: NSViewController {
    private enum Page: Int { case triggers, activity, sources, remote }

    private enum Layout {
        /// The page's column, centred in whatever pane it is given.
        ///
        /// The Settings canvas's content measure plus the inset `PanelListView` keeps its own
        /// content on, so this destination's ink stands on the same edges as every Settings page
        /// beside it. It was the 620-point readable measure, chosen when a row was one line and
        /// a pane-wide row put its button a thousand points from its name; at that width an
        /// automation's page was a narrow strip in the middle of a wide window, and the facts on
        /// an automation's own page wrapped to a third of the room they had.
        static let contentWidth: CGFloat =
            Design.Size.settingsContentWidth + Design.Spacing.inset * 2

        /// How many runs an automation's page lists before pointing at Activity.
        static let recentRunLimit = 10

        /// How many catalogue rows one page constructs.
        static let pageSize = 25
    }

    private(set) var projectID: ProjectID?
    private var discoveryErrors: [ProjectAutomationFiles.Entry] = []
    private let titleLabel = NSTextField(labelWithString: "")
    private var fileDiagnostics: [TriggerID: String] = [:]
    private let store: TriggerStore
    private let pages = ThemedSegmentedControl()
    private let primaryAction = ThemedButton()
    private let list = PanelListView(rowSpacing: Design.Spacing.small)
    private let status = NSTextField(labelWithString: "")
    private let column = NSView()
    private let events = AppEventObservations()
    private var page: Page = .triggers
    private var pageOffset = 0
    private var reloadTask: Task<Void, Never>?
    private var historyCursors: [Int64] = [Int64.max]
    private var nextHistoryCursor: Int64?
    private var remoteController: RemoteAutomationsViewController?
    /// The automation whose own page is showing, or nil for the list.
    private var detailID: TriggerID?

    /// Opens the chat a run started in. Set by the window, which owns the sidebar's selection.
    var onOpenSession: ((SessionID) -> Void)?

    init(store: TriggerStore = .shared) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        events.observe(.triggersDidChange) { [weak self] in self?.reload() }
        reload()
    }

    func showProject(_ id: ProjectID?) {
        guard projectID != id || !isViewLoaded else { return }
        projectID = id
        page = .triggers
        detailID = nil
        pageOffset = 0
        historyCursors = [Int64.max]
        discoveryErrors = []
        if isViewLoaded {
            pages.configure(titles: pageTitles)
            pages.selectedIndex = 0
            titleLabel.stringValue = id.flatMap { ProjectStore.shared.project(withID: $0)?.name }.map { L10n.format("%@ · Automations", $0) } ?? L10n.string("Automations")
            reload()
        }
    }

    private func catalogue() async throws -> [Pair] {
        if let id = projectID, let project = ProjectStore.shared.project(withID: id) {
            discoveryErrors = try await store.discoverProjectAutomations(projectID: id, checkout: project.folderPath).filter { $0.snapshot == nil }
        }
        let pairs = try await store.triggers().filter { projectID == nil || $0.revision.projectID == projectID }
            .sorted { left, right in
                let leftName = ProjectStore.shared.project(withID: left.revision.projectID)?.name ?? ""
                let rightName = ProjectStore.shared.project(withID: right.revision.projectID)?.name ?? ""
                return leftName == rightName ? left.definition.name < right.definition.name : leftName < rightName
            }
        let importedIDs = Set(pairs.compactMap { $0.revision.projectAutomation?.automationID })
        discoveryErrors.removeAll { importedIDs.contains($0.id) }
        fileDiagnostics = [:]
        for pair in pairs.dropFirst(pageOffset).prefix(Layout.pageSize) {
            if let binding = try await store.projectAutomationBinding(pair.definition.id) {
                fileDiagnostics[pair.definition.id] = binding.diagnostic
                if let owner = try await store.projectAutomationOwner(pair.definition.id) {
                    fileDiagnostics[pair.definition.id] = L10n.format("Schedule owned by %@", owner)
                }
            }
        }
        return pairs
    }

    private var pageTitles: [String] {
        [L10n.string("Automations"), L10n.string("Activity")]
            + (projectID == nil ? [L10n.string("Sources"), L10n.string("Remote")] : [])
    }

    private func build() {
        let title = titleLabel
        title.stringValue = projectID.flatMap { ProjectStore.shared.project(withID: $0)?.name }.map { L10n.format("%@ · Automations", $0) } ?? L10n.string("Automations")
        title.applyFont(.heading)
        title.textColor = Design.Text.label

        let subtitle = NSTextField(labelWithString: L10n.string(
            "Run saved tasks on a schedule or when an event arrives."
        ))
        subtitle.applyFont(.subheading)
        subtitle.textColor = Design.Text.secondary
        subtitle.lineBreakMode = .byTruncatingTail

        status.applyFont(.detail())
        status.textColor = Design.Text.tertiary
        status.alignment = .natural

        pages.configure(titles: pageTitles)
        pages.onSelect = { [weak self] index in
            guard let self, let page = Page(rawValue: index) else { return }
            self.page = page
            self.pageOffset = 0
            self.detailID = nil
            self.historyCursors = [Int64.max]
            self.reload()
        }
        // Four pages, and their words change with the theme's typeface and the text size, so the
        // run measures its own titles rather than taking a number from here.
        pages.sizesToTitles = true
        pages.setContentHuggingPriority(.required, for: .horizontal)
        pages.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        primaryAction.setAccessibilityIdentifier("automation.new")
        primaryAction.title = L10n.string("Connect Source")
        primaryAction.emphasis = .primary
        primaryAction.target = self
        primaryAction.action = #selector(connectSourcePressed)
        primaryAction.isHidden = true

        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = Design.Spacing.tight
        heading.translatesAutoresizingMaskIntoConstraints = false

        // The count stands next to the tabs it counts rather than at the far end of the title
        // line: "No automations" is about the page you are on, and at the other end of a wide window
        // it read as an unrelated word in the opposite corner.
        let controls = NSStackView(views: [pages, status, NSView(), primaryAction])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = Design.Spacing.medium
        controls.translatesAutoresizingMaskIntoConstraints = false

        list.translatesAutoresizingMaskIntoConstraints = false

        // One centred column, so the header block, the tabs and the rows' ink stand on the same
        // line whatever the window is doing. `PanelListView` insets its own content by
        // `Spacing.inset`, and the header block matches it rather than choosing a second margin.
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(heading)
        column.addSubview(controls)
        column.addSubview(list)
        SettingsUI.install(page: column, in: view, width: Layout.contentWidth)

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: column.topAnchor, constant: Design.Spacing.large),
            heading.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            heading.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            controls.topAnchor.constraint(
                equalTo: heading.bottomAnchor,
                constant: Design.Spacing.large
            ),
            controls.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            controls.trailingAnchor.constraint(
                equalTo: column.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            list.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: Design.Spacing.medium),
            list.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
    }

    private func reload() {
        status.stringValue = L10n.string("Updating…")
        updatePrimaryAction()
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            // A store transaction can publish several receipts together. Project its final
            // state once rather than queueing a catalogue read for every notification.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            do {
                switch page {
                case .triggers:
                    let pairs = try await catalogue()
                    if let detail = try await loadDetail(in: pairs) {
                        guard !Task.isCancelled else { return }
                        renderDetail(detail)
                    } else {
                        let readings = try await loadReadings(pairs)
                        guard !Task.isCancelled else { return }
                        renderTriggers(pairs, readings: readings)
                    }
                case .remote: renderRemote()
                case .activity:
                    let result = try await store.runPage(projectID: projectID, before: historyCursors.last)
                    let pairs = try await catalogue()
                    guard !Task.isCancelled else { return }
                    nextHistoryCursor = result.next
                    renderRuns(result.items, triggers: pairs)
                case .sources:
                    let sources = try await store.sources()
                    let daemonStatusTask = Task.detached(priority: .utility) {
                        try TriggerDaemonStatusStore.statuses()
                    }
                    let registrationTask = Task.detached(priority: .utility) {
                        TriggerDaemonRegistrationCoordinator.currentStatus()
                    }
                    let daemonStatuses = (try? await daemonStatusTask.value) ?? [:]
                    let registration = await registrationTask.value
                    guard !Task.isCancelled else { return }
                    renderSources(sources, daemonStatuses: daemonStatuses, registrationStatus: registration)
                }
            } catch {
                guard !Task.isCancelled else { return }
                list.clear()
                list.addNote(error.localizedDescription)
                status.stringValue = L10n.string("Unavailable")
            }
        }
    }

    #if DEBUG
    /// What a wide pane may not take for itself. A run of tabs with no intrinsic width and a
    /// list pinned to the window will each swallow every point on offer, which is a defect the
    /// renders showed and no assertion here was making.
    static var expectedColumnWidth: CGFloat { Layout.contentWidth }
    var expectedPagesWidth: CGFloat { pages.intrinsicContentSize.width }
    var drawnPagesWidth: CGFloat { pages.frame.width }
    var drawnColumnWidth: CGFloat { column.frame.width }
    var drawnRowCount: Int { list.rows.count }
    var drawnRows: [NSView] { list.rows }
    var isShowingDetail: Bool { detailID != nil }

    /// Deterministic render-test seam: the shipping segmented control owns the same selection,
    /// while the evidence test awaits the async store projection before capturing pixels.
    func prepareEvidencePage(index: Int) async throws {
        guard let page = Page(rawValue: index) else { return }
        reloadTask?.cancel()
        self.page = page
        detailID = nil
        pages.selectedIndex = index
        updatePrimaryAction()
        switch page {
        case .remote: renderRemote()
        case .triggers:
            let pairs = try await catalogue()
            renderTriggers(pairs, readings: try await loadReadings(pairs))
        case .activity:
            let result = try await store.runPage(projectID: projectID)
            nextHistoryCursor = result.next
            renderRuns(result.items, triggers: try await store.triggers())
        case .sources:
            renderSources(
                try await store.sources(),
                daemonStatuses: [:],
                registrationStatus: .enabled
            )
        }
    }

    /// Opens one automation's own page, the way its row's Details button does, and waits for
    /// the store projection before returning so a render captures the finished page.
    func prepareEvidenceDetail(_ id: TriggerID) async throws {
        reloadTask?.cancel()
        page = .triggers
        pages.selectedIndex = Page.triggers.rawValue
        detailID = id
        updatePrimaryAction()
        if let detail = try await loadDetail(in: try await store.triggers()) { renderDetail(detail) }
    }
    #endif

    private typealias Pair = (definition: TriggerDefinition, revision: TriggerRevision)

    /// What a list row reads beyond its own record: when it runs next and how it last ran.
    private struct Readings {
        var nextDates: [TriggerID: Date] = [:]
        var lastRuns: [TriggerID: TriggerRun] = [:]
    }

    /// Everything one automation's page shows, read before anything is drawn.
    private struct Detail {
        let pair: Pair
        let summary: AutomationSummary
        let review: AutomationReview
        let runs: [TriggerRun]
    }

    private func updatePrimaryAction() {
        primaryAction.isHidden = page == .activity || page == .remote || detailID != nil
        primaryAction.title = page == .sources ? L10n.string("Connect Source") : L10n.string("New automation")
    }

    /// One page of rows' readings: two indexed reads per visible row, never per definition.
    private func loadReadings(_ pairs: [Pair]) async throws -> Readings {
        var readings = Readings()
        for pair in pairs.dropFirst(pageOffset).prefix(Layout.pageSize) {
            let id = pair.definition.id
            readings.nextDates[id] = try await store.nextAutomationDate(id)
            readings.lastRuns[id] = try await store.runs(triggerID: id, limit: 1).first
        }
        return readings
    }

    /// The open automation's page, or nil when none is open — or when the one that was open has
    /// since been deleted, which returns the page to the list rather than to an empty detail.
    private func loadDetail(in pairs: [Pair]) async throws -> Detail? {
        guard let id = detailID else { return nil }
        guard let pair = pairs.first(where: { $0.definition.id == id }) else {
            detailID = nil
            updatePrimaryAction()
            return nil
        }
        let next = try await store.nextAutomationDate(id)
        let runs = try await store.runs(triggerID: id, limit: Layout.recentRunLimit)
        let sourceName = pair.revision.automation?.schedule == nil
            ? (try? await store.source(id: pair.revision.sourceInstallationID))?.displayName
            : nil
        return Detail(
            pair: pair,
            summary: .make(definition: pair.definition, revision: pair.revision, nextRun: next, lastRun: runs.first),
            review: .make(pair.revision, purpose: .activate, context: .live(sourceName: sourceName)),
            runs: runs
        )
    }

    private func renderTriggers(_ pairs: [Pair], readings: Readings) {
        list.clear()
        status.stringValue = pairs.isEmpty && discoveryErrors.isEmpty
            ? L10n.string("No automations")
            : L10n.format("%lld configured", Int64(pairs.count + discoveryErrors.count))
        list.addSection(L10n.string("Configured automations"))
        if let projectID, let project = ProjectStore.shared.project(withID: projectID) {
            list.addRow(TriggerCenterRowView(title: L10n.string("Project files"),
                detail: ".threading/automations/", actionTitle: L10n.string("Open configuration folder"),
                onAction: { [weak self] in self?.openConfigurationFolder(checkout: project.folderPath) },
                secondaryActionTitle: nil, onSecondaryAction: nil))
        }
        for entry in discoveryErrors.dropFirst(max(0, pageOffset - pairs.count)).prefix(max(0, Layout.pageSize - pairs.dropFirst(pageOffset).prefix(Layout.pageSize).count)) {
            list.addNote("\(entry.id): \(entry.diagnostic ?? "")")
        }
        if pairs.isEmpty && discoveryErrors.isEmpty {
            list.addNote(L10n.string(
                "Create an automation here or ask an agent to set one up. Choose a schedule, task, and what happens after success."
            ))
            return
        }
        var group: ProjectID?
        for pair in pairs.dropFirst(pageOffset).prefix(Layout.pageSize) {
            if projectID == nil, group != pair.revision.projectID {
                group = pair.revision.projectID
                list.addSection(ProjectStore.shared.project(withID: pair.revision.projectID)?.name ?? L10n.string("Unknown project"))
            }
            let summary = AutomationSummary.make(
                definition: pair.definition,
                revision: pair.revision,
                nextRun: readings.nextDates[pair.definition.id],
                lastRun: readings.lastRuns[pair.definition.id]
            )
            list.addRow(TriggerCenterRowView(
                title: pair.definition.name,
                status: .init(words: summary.stateWords, tone: summary.stateTone),
                detail: fileDiagnostics[pair.definition.id] ?? (summary.timingAndMode + "\n" + summary.runs),
                actionTitle: summary.stateActionTitle,
                onAction: { [weak self] in self?.act(on: pair) },
                secondaryActionTitle: L10n.string("Details"),
                onSecondaryAction: { [weak self] in self?.showDetail(pair.definition.id) },
                identifier: "automation.row.\(pair.definition.id.uuidString)"
            ))
        }
        if pageOffset > 0 || pageOffset + Layout.pageSize < pairs.count + discoveryErrors.count {
            list.addRow(TriggerCenterRowView(title: L10n.string("More automations"), detail: "",
                actionTitle: pageOffset + Layout.pageSize < pairs.count + discoveryErrors.count ? L10n.string("Next") : nil,
                onAction: { [weak self] in self?.pageOffset += Layout.pageSize; self?.reload() },
                secondaryActionTitle: pageOffset > 0 ? L10n.string("Previous") : nil,
                onSecondaryAction: { [weak self] in
                    self?.pageOffset = max(0, (self?.pageOffset ?? 0) - Layout.pageSize); self?.reload()
                }))
        }
    }

    private func showDetail(_ id: TriggerID) {
        detailID = id
        list.scrollToTop()
        reload()
    }

    private func showList() {
        detailID = nil
        list.scrollToTop()
        reload()
    }

    /// One automation's own page: what it is, every action on it, the exact settings a run
    /// uses, its instructions in full, and its recent runs.
    private func renderDetail(_ detail: Detail) {
        list.clear()
        status.stringValue = ""
        let pair = detail.pair
        let header = AutomationDetailHeaderView(summary: detail.summary)
        header.onBack = { [weak self] in self?.showList() }
        header.onStateAction = { [weak self] in self?.act(on: pair) }
        header.onRunNow = { [weak self] in self?.runNow(pair) }
        header.onEdit = { [weak self] in self?.editAutomation(pair) }
        header.onDelete = { [weak self] in self?.deleteAutomation(pair) }
        list.addRow(header)

        if let diagnostic = fileDiagnostics[pair.definition.id] { list.addNote(diagnostic) }
        if let files = pair.revision.projectAutomation {
            list.addRow(TriggerCenterRowView(title: L10n.string("Saved in project"), detail: files.automationID,
                actionTitle: L10n.string("Open configuration folder"),
                onAction: { [weak self] in self?.openConfigurationFolder(checkout: files.checkoutPath, id: files.automationID) },
                secondaryActionTitle: nil, onSecondaryAction: nil))
        } else { list.addNote(L10n.string("Saved locally on this Mac")) }
        list.addSection(L10n.string("Settings"))
        list.addRow(FactSheetView(facts: detail.review.facts))

        list.addSection(L10n.string("Instructions"))
        let instructions = NSTextField(wrappingLabelWithString: detail.review.instructions)
        instructions.applyFont(.body)
        instructions.textColor = Design.Text.label
        instructions.isSelectable = true
        instructions.setAccessibilityIdentifier("automation.detail.instructions")
        list.addRow(instructions)

        list.addSection(L10n.string("Recent runs"))
        guard !detail.runs.isEmpty else {
            list.addNote(L10n.string("No runs yet. Each scheduled time, matching event or manual run adds one here."))
            return
        }
        for run in detail.runs {
            list.addRow(runRow(
                run,
                title: (run.startedAt ?? run.queuedAt).formatted(date: .abbreviated, time: .shortened),
                automationName: pair.definition.name
            ))
        }
        if detail.runs.count == Layout.recentRunLimit {
            list.addFootnote(L10n.string("Older runs are listed under Activity."))
        }
    }

    /// One run as a row: its state in the state's ink, what it reported and when, and the two
    /// places to go from it — its receipt and the chat it ran in.
    private func runRow(_ run: TriggerRun, title: String, automationName: String?) -> TriggerCenterRowView {
        let detail = [
            run.result?.summary ?? run.boundedDiagnostic,
            AutomationInk.relativeDate.localizedString(for: run.queuedAt, relativeTo: Date()),
        ].compactMap { $0 }.joined(separator: "  ·  ")
        let chat = run.sessionID.flatMap { id in
            onOpenSession != nil && ProjectStore.shared.session(withID: id) != nil ? id : nil
        }
        return TriggerCenterRowView(
            title: title,
            status: .init(words: run.state.displayTitle, tone: run.state.tone),
            detail: detail,
            actionTitle: L10n.string("Details"),
            onAction: { [weak self] in self?.showRun(run, automationName: automationName) },
            secondaryActionTitle: chat == nil ? nil : L10n.string("Open chat"),
            onSecondaryAction: { [weak self] in
                guard let chat else { return }
                self?.onOpenSession?(chat)
            }
        )
    }

    private func renderRuns(
        _ runs: [TriggerRun],
        triggers: [(definition: TriggerDefinition, revision: TriggerRevision)]
    ) {
        list.clear()
        status.stringValue = runs.isEmpty
            ? L10n.string("No activity")
            : L10n.format("%lld recent", Int64(runs.count))
        list.addSection(L10n.string("Recent activity"))
        guard !runs.isEmpty else {
            list.addNote(L10n.string("Matched events and their agent runs will appear here."))
            return
        }
        let triggerNames = Dictionary(uniqueKeysWithValues: triggers.map {
            ($0.definition.id, $0.definition.name)
        })
        for run in runs {
            let name = triggerNames[run.triggerID]
            list.addRow(runRow(run, title: name ?? run.id.uuidString, automationName: name))
        }
        if historyCursors.count > 1 || nextHistoryCursor != nil {
            list.addRow(TriggerCenterRowView(title: L10n.string("Activity"), detail: "",
                actionTitle: nextHistoryCursor == nil ? nil : L10n.string("Next"),
                onAction: { [weak self] in
                    guard let self, let nextHistoryCursor else { return }
                    historyCursors.append(nextHistoryCursor); reload()
                },
                secondaryActionTitle: historyCursors.count > 1 ? L10n.string("Previous") : nil,
                onSecondaryAction: { [weak self] in
                    guard let self, historyCursors.count > 1 else { return }
                    historyCursors.removeLast(); reload()
                }))
        }
    }

    /// A run's receipt: when it ran and what it reported, as the fact sheet an approval uses.
    private func showRun(_ run: TriggerRun, automationName: String?) {
        let alert = ThemedAlert()
        alert.messageText = automationName ?? run.state.displayTitle
        alert.accessoryView = AutomationReviewView(
            review: AutomationRunReview.make(run, automationName: nil),
            instructionsTitle: L10n.string("Summary")
        )
        alert.addButton(withTitle: L10n.string("OK"))
        if let window = view.window { alert.beginSheetModal(for: window) }
    }

    private func renderSources(
        _ sources: [TriggerSourceInstallation],
        daemonStatuses: [TriggerSourceInstallationID: TriggerDaemonSourceStatus],
        registrationStatus: TriggerDaemonRegistrationStatus
    ) {
        // A deleted probe is a tombstone kept for history; it is not a source any more.
        let sources = sources.filter { !$0.isDeleted }
        list.clear()
        status.stringValue = sources.isEmpty
            ? L10n.string("No sources")
            : (sources.count == 1
                ? L10n.string("1 source")
                : L10n.format("%lld sources", Int64(sources.count)))
        list.addSection(L10n.string("Background listener"))
        list.addRow(TriggerCenterRowView(
            title: L10n.string("Runs while Threading is closed"),
            detail: registrationStatus.displayTitle,
            actionTitle: registrationStatus.actionTitle,
            onAction: registrationStatus.actionTitle == nil ? nil : { [weak self] in
                guard let self else { return }
                if registrationStatus == .requiresApproval {
                    TriggerDaemonRegistrationCoordinator.openLoginItemsSettings()
                } else {
                    TriggerDaemonRegistrationCoordinator.shared.reconcile(shouldRun: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.reload()
                    }
                }
            },
            secondaryActionTitle: nil,
            onSecondaryAction: nil
        ))
        let probes = sources.filter { $0.sourceType == TriggerProbeDefaults.sourceType && !$0.isDeleted }
        let connected = sources.filter { $0.sourceType != TriggerProbeDefaults.sourceType }
        defer { renderProbes(probes, daemonStatuses: daemonStatuses) }
        guard !connected.isEmpty else {
            list.addSection(L10n.string("Event sources"))
            list.addNote(L10n.string(
                "Sources run through Threading’s background listener, so events can wake the app even when its window is closed."
            ))
            return
        }
        list.addSection(L10n.string("Event sources"))
        for source in connected {
            let daemonStatus = daemonStatuses[source.id].flatMap {
                $0.lastCheckedAt >= source.updatedAt ? $0 : nil
            }
            let checked = (daemonStatus?.lastCheckedAt ?? source.lastCheckedAt).map {
                AutomationInk.relativeDate.localizedString(for: $0, relativeTo: Date())
            }
            let health = source.enabled ? (daemonStatus?.health ?? source.health) : .disconnected
            let detail = [source.sourceType, health.displayTitle, checked,
                          daemonStatus?.boundedDiagnostic ?? source.boundedDiagnostic]
                .compactMap { $0 }.joined(separator: "  ·  ")
            list.addRow(TriggerCenterRowView(
                title: source.displayName,
                detail: detail,
                actionTitle: source.credentialReference == nil
                    ? L10n.string("Reconnect")
                    : (source.enabled ? L10n.string("Pause") : L10n.string("Resume")),
                onAction: { [weak self] in
                    if source.credentialReference == nil {
                        self?.connectSource(replacing: source)
                    } else {
                        self?.toggleSource(source)
                    }
                },
                secondaryActionTitle: source.credentialReference == nil
                    ? nil : L10n.string("Disconnect"),
                onSecondaryAction: { [weak self] in self?.disconnectSource(source) }
            ))
        }
    }

    /// Probe sources: programs a person (or an agent, as a draft) wrote, run unsandboxed on the
    /// probe contract. Every row says whether it is approved and offers Run now once it is.
    private func renderProbes(
        _ probes: [TriggerSourceInstallation],
        daemonStatuses: [TriggerSourceInstallationID: TriggerDaemonSourceStatus]
    ) {
        list.addSection(L10n.string("Probe sources"))
        list.addRow(TriggerCenterRowView(
            title: L10n.string("Your own programs"),
            detail: L10n.string(
                "A probe checks something on a schedule and reports events without starting a model. It runs unsandboxed, as you, so each one needs your approval."
            ),
            actionTitle: L10n.string("New Probe…"),
            onAction: { [weak self] in self?.editProbe(nil) },
            secondaryActionTitle: nil,
            onSecondaryAction: nil,
            identifier: "probe.new"
        ))
        for source in probes.prefix(25) {
            let status = daemonStatuses[source.id].flatMap { $0.lastCheckedAt >= source.updatedAt ? $0 : nil }
            let row = TriggerProbePresentation.row(source, daemonStatus: status)
            var extras: [(title: String, handler: () -> Void)] = [
                (L10n.string("Edit…"), { [weak self] in self?.editProbe(source) }),
            ]
            if row.hasSecrets {
                extras.append((L10n.string("Secrets…"), { [weak self] in self?.setProbeSecrets(source) }))
            }
            extras.append((L10n.string("Delete…"), { [weak self] in self?.deleteProbe(source) }))
            list.addRow(TriggerCenterRowView(
                title: row.title,
                detail: row.detail,
                actionTitle: row.primaryTitle,
                onAction: { [weak self] in self?.actOnProbe(source, state: row.state) },
                secondaryActionTitle: row.canRunNow ? L10n.string("Run now") : nil,
                onSecondaryAction: { [weak self] in self?.runProbe(source) },
                extraActions: extras,
                identifier: "probe.\(source.id.uuidString)"
            ))
        }
    }

    private func editProbe(_ existing: TriggerSourceInstallation?) {
        let form = TriggerProbeEditorForm(spec: existing?.probe?.spec)
        let request = TriggerProbePresentation.editorRequest(form, editing: existing?.displayName)
        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard approved, let self else { return }
            Task { @MainActor in
                do {
                    let spec = try form.spec()
                    try await TriggerProbeSourceCommands.configure(
                        id: existing?.id, expectedRevision: existing?.probe?.revision ?? 0, spec: spec, store: self.store)
                } catch { self.presentSourceFailure(error.localizedDescription) }
            }
        }
    }

    private func actOnProbe(_ source: TriggerSourceInstallation, state: TriggerProbePresentation.State) {
        switch state {
        case .needsApproval, .changed: reviewProbe(source)
        case .paused, .listening:
            Task { @MainActor [weak self] in
                guard let self, let revision = source.probe?.revision else { return }
                do {
                    try await TriggerProbeSourceCommands.setEnabled(
                        !source.enabled, id: source.id, expectedRevision: revision, store: self.store)
                } catch { self.presentSourceFailure(error.localizedDescription) }
            }
        }
    }

    /// The host approval sheet: the only path that approves or enables a probe.
    private func reviewProbe(_ original: TriggerSourceInstallation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let source = try await TriggerProbeSourceCommands.prepareReview(original.id, store: self.store)
                guard let probe = source.probe else { return }
                let names = Array(Set(probe.spec.secrets.values))
                let stored = await Task.detached(priority: .utility) {
                    Set(names.filter(TriggerProbeSecretStore.exists))
                }.value
                let request = TriggerProbePresentation.approvalRequest(source, storedSecrets: stored)
                ConfirmationAlert.ask(request, in: self.view.window) { [weak self] approved in
                    guard approved, let self else { return }
                    Task { @MainActor in
                        do {
                            try await TriggerProbeSourceCommands.approve(
                                source.id, expectedRevision: probe.revision, reviewedHash: probe.hash,
                                enable: true, store: self.store)
                        } catch { self.presentSourceFailure(error.localizedDescription) }
                    }
                }
            } catch { self.presentSourceFailure(error.localizedDescription) }
        }
    }

    private func deleteProbe(_ source: TriggerSourceInstallation) {
        let request = ConfirmationRequest(
            prompt: .connectTriggerSource,
            title: L10n.format("Delete “%@”?", source.displayName),
            message: L10n.string(
                "Threading stops polling this probe and removes it from this page. Events it already reported and the runs they started stay in Activity. Its files and Keychain secrets are not touched."
            ),
            confirmTitle: L10n.string("Delete")
        )
        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard approved, let self, let revision = source.probe?.revision else { return }
            Task { @MainActor in
                do {
                    try await TriggerProbeSourceCommands.delete(source.id, expectedRevision: revision, store: self.store)
                } catch { self.presentSourceFailure(error.localizedDescription) }
            }
        }
    }

    private func runProbe(_ source: TriggerSourceInstallation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await TriggerProbeSourceCommands.runNow(source.id, store: self.store)
                self.status.stringValue = L10n.string("Poll requested")
            } catch { self.presentSourceFailure(error.localizedDescription) }
        }
    }

    /// One secure field per secret name. A blank field leaves that value as it is; nothing is
    /// read back, so a stored value is never shown.
    private func setProbeSecrets(_ source: TriggerSourceInstallation) {
        let names = Array(Set(source.probe.map { Array($0.spec.secrets.values) } ?? [])).sorted()
        guard !names.isEmpty else { return }
        let fields = names.map { name -> ThemedSecureField in
            let field = ThemedSecureField()
            field.placeholderString = name
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: TriggerProbeEditorForm.Layout.fieldWidth).isActive = true
            return field
        }
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        let request = ConfirmationRequest(
            prompt: .connectTriggerSource,
            title: L10n.format("Secrets for “%@”", source.displayName),
            message: L10n.string(
                "Values are stored in your Keychain and handed only to this probe's environment when it runs. Leave a field blank to keep its current value."
            ),
            confirmTitle: L10n.string("Save"),
            accessory: stack
        )
        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard approved else { return }
            let values = zip(names, fields.map(\.stringValue)).filter { !$0.1.isEmpty }
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .utility) {
                        for (name, value) in values { try TriggerProbeSecretStore.save(value, name: name) }
                    }.value
                } catch { self?.presentSourceFailure(error.localizedDescription) }
            }
        }
    }

    @objc private func connectSourcePressed() {
        if page == .sources { connectSource(replacing: nil) }
        else { editAutomation(nil) }
    }

    private func renderRemote() {
        list.clear()
        let controller = remoteController ?? RemoteAutomationsViewController()
        if remoteController == nil {
            addChild(controller); remoteController = controller
            controller.view.heightAnchor.constraint(equalToConstant: 540).isActive = true
        }
        list.addRow(controller.view)
        controller.refreshHosts()
        status.stringValue = ""
    }

    private func editAutomation(_ pair: (definition: TriggerDefinition, revision: TriggerRevision)?) {
        let config = pair.map { AutomationConfiguration(definition: $0.definition, revision: $0.revision) } ?? projectID.map { AutomationConfiguration(projectID: $0) }
        let automationID = pair?.definition.id ?? TriggerID()
        Task { @MainActor in
        let sources = ((try? await store.sources()) ?? []).filter { !$0.isDeleted }
        let editor = AutomationEditorViewController(configuration: config, sources: sources)
        editor.lockedProjectID = projectID ?? pair?.revision.projectAutomation.map { _ in pair!.revision.projectID }
        editor.availableHeight = view.window.map { $0.contentLayoutRect.height - Design.Spacing.pane * 2 }
        editor.onSave = { [weak self] config, _ in
            guard let self, let config else { return }
            _ = try await AutomationCommands.execute(.init(operation: "configure", id: automationID.uuidString,
                expectedRevision: pair?.revision.id.uuidString, configuration: config,
                folder: pair == nil ? ProjectStore.shared.project(withID: config.projectID)?.folderPath : nil), store: store)
            reload()
        }
        presentAsSheet(editor)
        }
    }

    /// Runs once, now. An approved revision runs on the press — the person is acting, and the
    /// page above the button is the settings it runs with. A draft has never been approved, so
    /// its first run goes through the same review an agent's run request raises.
    private func runNow(_ pair: Pair) {
        guard pair.definition.draftRevisionID == pair.revision.id else {
            perform("run", on: pair)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sourceName = pair.revision.automation?.schedule == nil
                ? (try? await self.store.source(id: pair.revision.sourceInstallationID))?.displayName
                : nil
            let request = ConfirmationRequest(
                prompt: .approveTriggerActivation,
                title: L10n.format("Run “%@” once?", pair.definition.name),
                message: L10n.string(
                    "This draft has not been activated. Running it once uses exactly these settings and leaves it a draft."
                ),
                confirmTitle: L10n.string("Run once"),
                accessory: Self.reviewAccessory(
                    for: pair.revision, purpose: .runNow, context: .live(sourceName: sourceName)
                )
            )
            ConfirmationAlert.ask(request, in: self.view.window) { [weak self] approved in
                guard approved else { return }
                self?.perform("run", on: pair)
            }
        }
    }

    private func deleteAutomation(_ pair: Pair) {
        let request = ConfirmationRequest(
            prompt: .approveTriggerActivation,
            title: L10n.format("Delete “%@”?", pair.definition.name),
            message: L10n.string(
                "It stops running and leaves this page. Its past runs and their results stay in Activity."
            ),
            confirmTitle: L10n.string("Delete")
        )
        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard approved, let self else { return }
            if self.detailID == pair.definition.id { self.detailID = nil }
            self.perform("delete", on: pair)
        }
    }

    /// The host's own run and delete, through the same operation the agent tool calls. The
    /// press is the authority, so no approver is passed.
    private func perform(_ operation: String, on pair: Pair) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await AutomationCommands.execute(.init(operation: operation,
                    id: pair.definition.id.uuidString, expectedRevision: pair.revision.id.uuidString,
                    requestKey: UUID().uuidString), store: self.store)
                self.reload()
            } catch {
                self.presentFailure(
                    operation == "run"
                        ? L10n.string("The automation did not start")
                        : L10n.string("The automation was not deleted"),
                    detail: error.localizedDescription
                )
            }
        }
    }

    private func connectSource(replacing existing: TriggerSourceInstallation?) {
        let name = ThemedTextField()
        name.placeholderString = L10n.string("Sonda Demo")
        name.stringValue = existing?.displayName ?? ""
        let baseURL = ThemedTextField()
        // localization-ignore: HTTPS format example, not presentation prose.
        baseURL.placeholderString = "https://demo.example.com"
        if case .string(let configuredURL)? = existing?.configuration["base_url"] {
            baseURL.stringValue = configuredURL
        }
        let credential = ThemedSecureField()
        credential.placeholderString = L10n.string("Scoped API key")

        let adapter = NSTextField(labelWithString: L10n.string(
            "Adapter: Sonda review-required events"
        ))
        adapter.applyFont(.detail())
        adapter.textColor = Design.Text.secondary
        let fields = NSStackView(views: [adapter, name, baseURL, credential])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = Design.Spacing.small
        for field in [name, baseURL, credential] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }

        let request = ConfirmationRequest(
            prompt: .connectTriggerSource,
            title: L10n.string("Connect an Event Source"),
            message: L10n.string(
                "Threading stores the scoped key in your Keychain. Its background listener uses it only to read bounded event metadata from this exact HTTPS service."
            ),
            confirmTitle: L10n.string("Connect"),
            accessory: fields
        )
        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard approved else { return }
            self?.saveSondaSource(
                name: name.stringValue,
                baseURL: baseURL.stringValue,
                credential: credential.stringValue,
                replacing: existing
            )
        }
    }

    private func saveSondaSource(
        name rawName: String,
        baseURL rawURL: String,
        credential: String,
        replacing existing: TriggerSourceInstallation?
    ) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 160,
              !credential.isEmpty,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            presentSourceFailure(L10n.string(
                "Enter a short name, a full HTTPS URL without embedded credentials, and a scoped API key."
            ))
            return
        }

        let sourceID = existing?.id ?? TriggerSourceInstallationID()
        let credentialReference = UUID().uuidString.lowercased()
        let now = Date()
        let source = TriggerSourceInstallation(
            id: sourceID,
            sourceType: "sonda",
            displayName: name,
            configuration: ["base_url": .string(url.absoluteString)],
            credentialReference: credentialReference,
            enabled: true,
            health: .checking,
            lastCheckedAt: nil,
            lastEventAt: nil,
            boundedDiagnostic: nil,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .utility) {
                    try TriggerSourceCredentialStore.save(
                        credential,
                        reference: credentialReference
                    )
                }.value
                try await store.saveSource(source)
                if let previous = existing?.credentialReference,
                   previous != credentialReference {
                    try? await Task.detached(priority: .utility) {
                        try TriggerSourceCredentialStore.delete(reference: previous)
                    }.value
                }
            } catch {
                let persistedReference = (try? await store.source(id: sourceID))?
                    .credentialReference
                if persistedReference != credentialReference {
                    try? await Task.detached(priority: .utility) {
                        try TriggerSourceCredentialStore.delete(reference: credentialReference)
                    }.value
                }
                presentSourceFailure(error.localizedDescription)
            }
        }
    }

    private func presentSourceFailure(_ detail: String) {
        presentFailure(L10n.string("The source was not connected"), detail: detail)
    }

    private func openConfigurationFolder(checkout: String, id: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let folder = try await store.projectAutomationConfigurationFolder(checkout: checkout, id: id)
                NSWorkspace.shared.open(folder)
            } catch {
                presentFailure(L10n.string("Open configuration folder"), detail: error.localizedDescription)
            }
        }
    }

    private func presentFailure(_ title: String, detail: String) {
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.string("OK"))
        if let window = view.window { alert.beginSheetModal(for: window) }
    }

    private func toggleSource(_ original: TriggerSourceInstallation) {
        guard original.credentialReference != nil else {
            connectSource(replacing: original)
            return
        }
        var source = original
        source.enabled.toggle()
        source.health = source.enabled ? .checking : .disconnected
        source.updatedAt = Date()
        source.boundedDiagnostic = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await store.saveSource(source)
                if source.enabled { try? await TriggerRuntime.shared.releaseQueue() }
            } catch {
                presentSourceFailure(error.localizedDescription)
            }
        }
    }

    private func disconnectSource(_ original: TriggerSourceInstallation) {
        let request = ConfirmationRequest(
            prompt: .connectTriggerSource,
            title: L10n.format("Disconnect “%@”?", original.displayName),
            message: L10n.string(
                "Threading will stop this listener and remove its scoped key from Keychain. Existing trigger definitions and run history stay visible, but they cannot receive new events until you reconnect the source."
            ),
            confirmTitle: L10n.string("Disconnect")
        )
        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard approved, let self else { return }
            Task { @MainActor in
                var source = original
                let credentialReference = source.credentialReference
                source.credentialReference = nil
                source.enabled = false
                source.health = .disconnected
                source.updatedAt = Date()
                source.boundedDiagnostic = nil
                do {
                    try await self.store.saveSource(source)
                    if let credentialReference {
                        try await Task.detached(priority: .utility) {
                            try TriggerSourceCredentialStore.delete(reference: credentialReference)
                        }.value
                    }
                } catch {
                    self.presentSourceFailure(error.localizedDescription)
                }
            }
        }
    }

    private func act(
        on pair: (definition: TriggerDefinition, revision: TriggerRevision)
    ) {
        if pair.definition.draftRevisionID == pair.revision.id || (pair.revision.projectAutomation != nil && !pair.definition.enabled) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sourceName = pair.revision.automation?.schedule == nil
                    ? (try? await self.store.source(id: pair.revision.sourceInstallationID))?.displayName
                    : nil
                let request = ConfirmationRequest(
                    prompt: .approveTriggerActivation,
                    title: L10n.format("Activate “%@”?", pair.definition.name),
                    message: L10n.string(
                        "Review the schedule or event, project, instructions, and permissions below. Enabling permits future runs with these settings."
                    ),
                    confirmTitle: L10n.string("Activate"),
                    accessory: Self.reviewAccessory(
                        for: pair.revision, purpose: .activate, context: .live(sourceName: sourceName)
                    )
                )
                ConfirmationAlert.ask(request, in: self.view.window) { [weak self] approved in
                    guard approved else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        do {
                            try await self.store.activate(triggerID: pair.definition.id, revisionID: pair.revision.id)
                        } catch { self.presentFailure(L10n.string("The automation was not activated"), detail: error.localizedDescription) }
                    }
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            try? await self?.store.setEnabled(
                !pair.definition.enabled,
                triggerID: pair.definition.id,
                expectedRevision: pair.revision.id
            )
        }
    }

    /// The exact revision under review: shared by the Activate sheet and the sheet an agent's
    /// enable or run request raises, so both show the same facts before anything runs.
    static func reviewAccessory(
        for revision: TriggerRevision,
        purpose: AutomationReview.Purpose = .activate,
        context: AutomationReview.Context = .live()
    ) -> NSView {
        AutomationReviewView(review: .make(revision, purpose: purpose, context: context))
    }

}

extension TriggerCheckoutPolicy {
    var displayTitle: String {
        switch self {
        case .projectCheckout: return L10n.string("Existing project checkout")
        case .managedWorktree: return L10n.string("Isolated managed worktree")
        case .automationWorkspace: return L10n.string("Automation workspace")
        }
    }
}

@MainActor
private final class TriggerCenterRowView: NSView {
    /// A state word set beside the title in its state's ink — an automation's Active or Draft,
    /// a run's Failed — so the one thing a person scans the list for is not the third phrase of
    /// a grey line.
    struct Status {
        let words: String
        let tone: AutomationInk.Tone
    }

    private let onAction: (() -> Void)?
    private let onSecondaryAction: (() -> Void)?
    private let extraActions: [(title: String, handler: () -> Void)]

    /// `extraActions` are quieter actions drawn before the secondary one, for a row with more
    /// than two things to do (a probe's Edit and Secrets).
    init(
        title: String,
        status: Status? = nil,
        detail: String,
        actionTitle: String?,
        onAction: (() -> Void)?,
        secondaryActionTitle: String?,
        onSecondaryAction: (() -> Void)?,
        extraActions: [(title: String, handler: () -> Void)] = [],
        identifier: String? = nil
    ) {
        self.onAction = onAction
        self.onSecondaryAction = onSecondaryAction
        self.extraActions = extraActions
        super.init(frame: .zero)
        if let identifier { setAccessibilityIdentifier(identifier) }
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.applyFont(.emphasizedBody)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var titleViews: [NSView] = [titleLabel]
        if let status {
            let statusLabel = NSTextField(labelWithString: status.words)
            statusLabel.applyFont(.detail(weight: .semibold))
            statusLabel.textColor = AutomationInk.color(status.tone)
            statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            statusLabel.setContentHuggingPriority(.required, for: .horizontal)
            statusLabel.setAccessibilityIdentifier("row.status")
            titleViews.append(statusLabel)
        }
        let titleLine = NSStackView(views: titleViews)
        titleLine.orientation = .horizontal
        titleLine.alignment = .firstBaseline
        titleLine.spacing = Design.Spacing.medium

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.applyFont(.detail())
        detailLabel.textColor = Design.Text.secondary
        detailLabel.maximumNumberOfLines = Self.detailLineLimit

        let copy = NSStackView(views: [titleLine, detailLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = Design.Spacing.tight

        var views: [NSView] = [copy]
        for (index, extra) in extraActions.enumerated() {
            let button = ThemedButton()
            button.title = extra.title
            button.emphasis = .tertiary
            button.tag = index
            button.target = self
            button.action = #selector(extraPressed(_:))
            views.append(button)
        }
        if let secondaryActionTitle {
            let button = ThemedButton()
            button.title = secondaryActionTitle
            button.emphasis = .tertiary
            button.target = self
            button.action = #selector(secondaryPressed)
            views.append(button)
        }
        if let actionTitle {
            let button = ThemedButton()
            button.title = actionTitle
            button.emphasis = .secondary
            button.target = self
            button.action = #selector(pressed)
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // The copy has to *ask* for the row, the way `ControlRowView` does: a wrapping label has
        // no intrinsic width to hug with, so a spacer beside it took the slack and the detail
        // line broke after two words with half the row still empty. One step under a button's
        // compression resistance, so the actions keep their size and the copy takes the rest.
        let stretch = copy.widthAnchor.constraint(equalTo: row.widthAnchor)
        stretch.priority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultHigh.rawValue - 1
        )

        // A hairline under the row runs from its name to its actions. At the page's measure the
        // two stand most of a window apart, and the line is what says they are one row.
        let rule = SeparatorView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        NSLayoutConstraint.activate([
            stretch,
            row.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: row.bottomAnchor, constant: Design.Spacing.medium),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Two facts lines — when and how, then next and last run — and room for either to wrap once.
    private static let detailLineLimit = 3

    @objc private func pressed() { onAction?() }
    @objc private func secondaryPressed() { onSecondaryAction?() }
    @objc private func extraPressed(_ sender: NSButton) {
        guard extraActions.indices.contains(sender.tag) else { return }
        extraActions[sender.tag].handler()
    }

}

extension TriggerExecutionMode {
    var displayTitle: String {
        switch self {
        case .taskReadOnly: return L10n.string("Read-only task")
        case .taskLocalEdits: return L10n.string("Task with local edits")
        case .assessOnly: return L10n.string("Assess only")
        case .assessThenFix: return L10n.string("Assess, then fix if straightforward")
        }
    }
}

extension TriggerCondition {
    var reviewDescription: String {
        let comparisonText = comparison.rawValue
        guard let value else { return "\(attribute)  \(comparisonText)" }
        return "\(attribute)  \(comparisonText)  \(value.reviewDescription)"
    }
}

private extension TriggerAttributeValue {
    var reviewDescription: String {
        switch self {
        case .string(let value): return String(reflecting: value)
        case .integer(let value): return String(value)
        case .decimal(let value): return String(value)
        case .boolean(let value): return String(value)
        case .timestamp(let value): return value.formatted(.iso8601)
        }
    }
}

extension TriggerSourceHealth {
    var displayTitle: String {
        switch self {
        case .disconnected: return L10n.string("Disconnected")
        case .healthy: return L10n.string("Healthy")
        case .checking: return L10n.string("Checking")
        case .backingOff: return L10n.string("Backing off")
        case .authenticationRequired: return L10n.string("Authentication required")
        case .failed: return L10n.string("Failed")
        case .changed: return L10n.string("Changed since approval")
        }
    }
}

private extension TriggerDaemonRegistrationStatus {
    var displayTitle: String {
        switch self {
        case .enabled:
            return L10n.string("Enabled in Login Items")
        case .requiresApproval:
            return L10n.string("Waiting for approval in System Settings ▸ General ▸ Login Items")
        case .notRegistered, .notFound, .unknown:
            return L10n.string("Not running; retry registration to keep listening in the background")
        case .missingHelper:
            return L10n.string("The background listener is unavailable in this build")
        }
    }

    var actionTitle: String? {
        switch self {
        case .requiresApproval: return L10n.string("Open Login Items…")
        case .notRegistered, .notFound, .unknown: return L10n.string("Retry")
        case .enabled, .missingHelper: return nil
        }
    }
}
