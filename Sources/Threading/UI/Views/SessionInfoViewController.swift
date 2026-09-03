import AppKit

/// What a session is actually running: where it is, the processes it has spawned, and the ports
/// those processes are listening on.
///
/// The panel exists because the terminal answers none of this. An agent that started a dev
/// server three turns ago has scrolled the port out of view, and "is it on 3000 or 5173, and can
/// the phone on my desk reach it" is a question the scrollback can only answer by being read
/// backwards. The bind address is half that answer and the half a port number omits.
///
/// Two things shape the implementation:
///
/// - **It polls, and only while it is on screen.** Processes and ports raise no filesystem
///   event, so unlike the review pane there is nothing to watch — the only honest option is to
///   ask again. `WindowAwareView` gates that on the tab being visible, so a panel nobody is
///   looking at costs nothing.
/// - **A poll rebuilds rows only when the *shape* changed.** CPU and memory move every tick, so
///   rebuilding on every reading would throw away the hover under the pointer and the scroll
///   position several times a second. The row set is rebuilt when a process or port appears or
///   goes away; otherwise the numbers are written into the rows already on screen.
final class SessionInfoViewController: NSViewController {

    private enum UsageRowID: Hashable {
        case total
        case mainAgent
        case subagents
        case input
        case cache
        case output
        case cost
        case pending
        case model(String)
    }

    private struct UsageRowPresentation {
        let id: UsageRowID
        let primary: String
        let secondary: String
        let values: [String]

        var accessibilityLabel: String {
            ([primary, secondary] + values)
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }

    private struct UsagePresentation {
        let leading: [UsageRowPresentation]
        let breakdown: [UsageRowPresentation]
        let models: [UsageRowPresentation]
        let remainingModelCount: Int

        var rows: [UsageRowPresentation] { leading + breakdown + models }
    }

    // MARK: - Properties

    let sessionID: SessionID
    private let folderPath: String

    /// The shell drawer's root pid. It lives on the terminal container rather than in any
    /// singleton, so it is injected rather than reached for across the window.
    var shellRootProvider: (() -> pid_t?)?

    /// Opening a port hands the URL back to the pane, which has a browser tab to put it in.
    var onOpenURL: ((URL) -> Void)?

    /// Test seams at the user-decision boundary, the Sharing pane's pattern. Production leaves
    /// both nil: the alert goes through `ConfirmationAlert` and the signal through
    /// `SessionProcessTerminator`.
    var confirmStop: ((ConfirmationRequest) -> Bool)?
    var onStopProcess: ((pid_t, ProcessStartTime) -> Void)?

    private let reader = SessionInfoReader()
    private let pollTimer = MainRunLoopTimer()
    private let appEvents = AppEventObservations()

    /// What the rows currently on screen are drawn from. A reading with the same shape updates
    /// them in place; a different one rebuilds.
    private var renderedShape: String?
    private var processRows: [pid_t: SessionInfoRowView] = [:]
    private var lastSnapshot: SessionInfoSnapshot?
    private var lastIsRunning = false
    private var usageSnapshot: SessionUsageSnapshot?
    private var usageRows: [UsageRowID: SessionInfoRowView] = [:]
    private weak var remainingModelsNote: NSTextField?
    private weak var usageIndexNote: NSTextField?

    /// The processes whose rows are unfolded. Kept here rather than only on the rows because a
    /// rebuild replaces the rows: a person reading a launch command while a sibling process
    /// exits must not have it fold under them.
    private var expandedProcessIDs: Set<pid_t> = []

    private lazy var directoryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.compactCode)
        label.textColor = Design.Text.label
        label.lineBreakMode = .byTruncatingMiddle
        // A session path is unbounded input inside an edge pane. `fittingSize` resolves at
        // `.fittingSizeCompression`, so the ordinary label resistance still lends the split
        // item the whole path width. AppKit then grows the *window* when the pane is revealed,
        // moving the trailing toggle away from the pointer that revealed it. The line already
        // truncates in the middle; put that promise below the fitting-size pass as well.
        label.setContentCompressionResistancePriority(
            Design.Priority.belowFittingSize,
            for: .horizontal
        )
        return label
    }()
    /// The branch under the path, in the detail face: a qualifier of the line above it, not a
    /// heading of its own — caption's semibold made the branch louder than the path.
    private lazy var metaLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(
            Design.Priority.belowFittingSize,
            for: .horizontal
        )
        return label
    }()

    /// The two things to do with the directory, as quiet icon buttons trailing the path on its
    /// own line. Two titled, bordered buttons on a row of their own were the loudest thing in a
    /// panel whose content is a receipt and a process list, and cost a row that the receipt
    /// below could use.
    private lazy var revealButton: ThemedIconButton = {
        let title = L10n.string("Show this folder in Finder")
        let button = ThemedIconButton(
            symbolName: SessionInfoSymbols.reveal,
            accessibility: title,
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = title
        button.onPress = { [weak self] in self?.revealInFinder() }
        return button
    }()
    private lazy var copyButton: ThemedIconButton = {
        let title = L10n.string("Copy the folder path")
        let button = ThemedIconButton(
            symbolName: SessionInfoSymbols.copy,
            accessibility: title,
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = title
        button.onPress = { [weak self] in self?.copyDirectory() }
        return button
    }()
    private let list = PanelListView(rowSpacing: Design.Spacing.hairline)

    /// The list hangs from the branch line when there is one and from the path when there is
    /// not: a folder outside git has no second line, and an empty label still holds its height.
    private var listBelowMeta: NSLayoutConstraint?
    private var listBelowPath: NSLayoutConstraint?

    // MARK: - Initialization

    init(sessionID: SessionID, folderPath: String) {
        self.sessionID = sessionID
        self.folderPath = folderPath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = WindowAwareView()
        root.onWindowChange = { [weak self] window in
            window == nil ? self?.stopPolling() : self?.startPolling()
        }
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        setupBody()
        setupConstraints()
        appEvents.observe(SessionUsageDidChange.self) { [weak self] event in
            guard let self, event.sessionID == self.sessionID else { return }
            self.applyUsage(self.currentUsageSnapshot)
        }
        SessionUsageService.shared.refresh(sessionID)
        applyUsage(currentUsageSnapshot)
        refresh()
    }

    // MARK: - Setup

    private func setupHeader() {
        [directoryLabel, metaLabel, revealButton, copyButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
    }

    private func setupBody() {
        view.addSubview(list)
    }

    private func setupConstraints() {
        let inset = Design.Spacing.inset

        NSLayoutConstraint.activate([
            // The toolbar insets the safe area; pinning to the view's own top slides the header
            // underneath it. The buttons' frames carry invisible padding, so the top and
            // trailing margins are measured to their glyphs (`OpticalInsetProviding`), which
            // keeps the copy glyph on the pane's trailing ink column and the path's line where
            // the section headings under it start.
            directoryLabel.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Design.Spacing.medium
            ),
            directoryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            directoryLabel.trailingAnchor.constraint(
                equalTo: revealButton.leadingAnchor,
                constant: -(Design.Spacing.small - revealButton.opticalHorizontalInset)
            ),

            revealButton.centerYAnchor.constraint(equalTo: directoryLabel.centerYAnchor),
            copyButton.centerYAnchor.constraint(equalTo: directoryLabel.centerYAnchor),
            copyButton.leadingAnchor.constraint(
                equalTo: revealButton.trailingAnchor,
                constant: Design.Spacing.tight - revealButton.opticalHorizontalInset
                    - copyButton.opticalHorizontalInset
            ),
            copyButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -(inset - copyButton.opticalHorizontalInset)
            ),

            metaLabel.topAnchor.constraint(equalTo: directoryLabel.bottomAnchor, constant: Design.Spacing.hairline),
            metaLabel.leadingAnchor.constraint(equalTo: directoryLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),

            list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let belowMeta = list.topAnchor.constraint(
            equalTo: metaLabel.bottomAnchor,
            constant: Design.Spacing.small
        )
        let belowPath = list.topAnchor.constraint(
            equalTo: directoryLabel.bottomAnchor,
            constant: Design.Spacing.small
        )
        listBelowMeta = belowMeta
        listBelowPath = belowPath
        belowMeta.isActive = true
    }

    // MARK: - Public Methods

    /// Test seam at the reading boundary: when set, `refresh()` asks this for its snapshot
    /// instead of resolving live roots and walking the machine — so the poll re-applies the
    /// fixture rather than racing it with real processes. Production leaves it nil.
    var readSource: ((@escaping @MainActor (SessionInfoSnapshot) -> Void) -> Void)?

    /// Deterministic render seam. Production reads the shared off-main projection.
    var usageSource: (() -> SessionUsageSnapshot?)? {
        didSet {
            if isViewLoaded { applyUsage(currentUsageSnapshot) }
        }
    }

    /// Re-reads now, whatever the poll was going to do. Called when the tab is shown and when the
    /// session stops working, which is when an agent has most likely just started or killed
    /// something.
    func refresh() {
        guard isViewLoaded else { return }

        updateHeader()

        if let readSource {
            readSource { [weak self] snapshot in
                self?.apply(snapshot, isRunning: !snapshot.processes.isEmpty)
            }
            return
        }

        let agentRoot = agentRootPid
        let shellRoot = shellRootProvider?()

        reader.read(agentRoot: agentRoot, shellRoot: shellRoot) { [weak self] snapshot in
            // Whether the session is running is answered by what was *found*, not by whether a
            // root pid existed to look under. A pid can outlive its process — and a session
            // holding a stale one would otherwise draw "Processes 0" over empty sections, which
            // reads as "nothing is running here" while claiming to have looked properly.
            self?.apply(snapshot, isRunning: !snapshot.processes.isEmpty)
        }
    }

    // MARK: - Polling

    private func startPolling() {
        guard !pollTimer.isInstalled else { return }

        // A fresh rate measurement: the gap while the tab was hidden is not a sample.
        reader.reset()
        refresh()

        let timer = Timer(timeInterval: SessionInfoDefaults.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        // `.common`, or the panel stops updating for as long as a menu is open or a scroll is
        // in progress — which is exactly when someone is reading it.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer.install(timer)
    }

    private func stopPolling() {
        pollTimer.invalidate()
    }

    // MARK: - Rendering

    /// The path with the home directory folded to `~`: the forty characters every path on this
    /// machine starts with are not what anyone reads it for. The tooltip and the Copy button
    /// keep the real thing.
    private func updateHeader() {
        let directory = currentDirectory
        directoryLabel.stringValue = (directory.path as NSString).abbreviatingWithTildeInPath
        directoryLabel.toolTip = directory.path

        let description = gitDescription(for: directory)
        metaLabel.stringValue = description
        metaLabel.isHidden = description.isEmpty
        if description.isEmpty {
            listBelowMeta?.isActive = false
            listBelowPath?.isActive = true
        } else {
            listBelowPath?.isActive = false
            listBelowMeta?.isActive = true
        }
    }

    /// Installs a known reading. Kept internal for behavior/render tests — live refreshes use
    /// the exact same path after the reader walks the real machine.
    func apply(_ snapshot: SessionInfoSnapshot, isRunning: Bool) {
        lastSnapshot = snapshot
        lastIsRunning = isRunning
        let shape = self.shape(of: snapshot, isRunning: isRunning)

        guard shape != renderedShape else {
            updateValues(snapshot)
            return
        }

        renderedShape = shape
        rebuild(snapshot, isRunning: isRunning)
    }

    func applyUsage(_ snapshot: SessionUsageSnapshot?) {
        guard snapshot != usageSnapshot else { return }
        usageSnapshot = snapshot
        guard let lastSnapshot else { return }

        let shape = self.shape(of: lastSnapshot, isRunning: lastIsRunning)
        guard shape != renderedShape else {
            updateUsageValues(snapshot)
            return
        }

        renderedShape = shape
        rebuild(lastSnapshot, isRunning: lastIsRunning)
    }

    /// Everything about a reading except the facts that move. Two readings with the same shape
    /// describe the same rows. Depth is part of a row's identity — its indent is a constraint,
    /// set at construction — while state, readings and tooltips deliberately are not: a process
    /// stopping must not cost the pointer its hover or the panel its scroll position.
    private func shape(of snapshot: SessionInfoSnapshot, isRunning: Bool) -> String {
        var parts = ["running:\(isRunning)", usageShape(of: usageSnapshot)]

        for group in snapshot.processGroups {
            let pids = group.processes.map { "\($0.pid):\($0.depth):\($0.command)" }.joined(separator: ",")
            parts.append("p/\(group.origin.rawValue)/\(pids)")
        }

        for group in snapshot.portGroups {
            let ports = group.ports.map { "\($0.port):\($0.address):\($0.pid)" }.joined(separator: ",")
            parts.append("n/\(group.origin.rawValue)/\(ports)")
        }

        return parts.joined(separator: "|")
    }

    /// Row identity only. Counts, tokens, costs, provenance and freshness are values written
    /// into those rows; treating them as shape is what rebuilt the scroll document on every
    /// usage event.
    private func usageShape(of snapshot: SessionUsageSnapshot?) -> String {
        guard let snapshot else { return "u/indexing" }
        guard !snapshot.total.isEmpty else { return "u/empty" }

        var rows = ["u/full", "total"]
        if Self.hasDelegatedWork(snapshot) {
            rows.append(contentsOf: ["main", "subagents"])
        }
        rows.append(contentsOf: ["input", "cache", "output", "cost"])
        if snapshot.total.unindexedTokens > 0 { rows.append("pending") }
        if Self.listsModels(snapshot) {
            rows.append(contentsOf: snapshot.total.models.map { "model:\($0.name)" })
            rows.append("remaining:\(snapshot.total.remainingModelCount > 0)")
        }
        return rows.joined(separator: "/")
    }

    /// Whether the receipt has anything to split: without delegated work the main agent *is*
    /// the total, and a row restating the same numbers under a different name reads as two
    /// facts where there is one.
    private static func hasDelegatedWork(_ snapshot: SessionUsageSnapshot) -> Bool {
        !snapshot.children.isEmpty || !snapshot.subagents.isEmpty
    }

    /// A single model repeats the total's numbers as well, so it is named on the Total row
    /// instead; the Models section exists for a session that used more than one.
    private static func listsModels(_ snapshot: SessionUsageSnapshot) -> Bool {
        snapshot.total.models.count > 1 || snapshot.total.remainingModelCount > 0
    }

    private func updateValues(_ snapshot: SessionInfoSnapshot) {
        for process in snapshot.processes {
            processRows[process.pid]?.update(reading(for: process))
        }
    }

    /// One poll's moving facts for one process: the readings, the state the dot must not
    /// overstate, and the tooltip's fact lines.
    private func reading(for process: SessionProcess) -> SessionInfoRowView.Reading {
        var facts: [String] = []
        if process.state == .stopped {
            facts.append(L10n.string("Stopped"))
        }
        if let started = process.startDate {
            facts.append(L10n.format(
                "Started %@",
                Self.startFormatter.localizedString(for: started, relativeTo: Date())
            ))
        }
        if let directory = process.workingDirectory {
            facts.append(L10n.format(
                "Working directory: %@",
                PathAbbreviation.abbreviatingHome(in: directory)
            ))
        }
        if let path = process.executablePath {
            facts.append(L10n.format("Program: %@", PathAbbreviation.abbreviatingHome(in: path)))
        }

        let readings = [process.formattedCPU, process.formattedMemory]
        let spoken = process.state == .stopped
            ? [L10n.string("Stopped")] + readings
            : readings

        // A stopped process holds its memory and its ports while running nothing — the one
        // state the filled "alive" dot must not claim. Hollow, in the warning role: paused is a
        // fact worth noticing, not a failure.
        return SessionInfoRowView.Reading(
            valueSegments: readings,
            dotSymbolName: process.state == .stopped ? "circle" : SessionInfoSymbols.process,
            dotColor: process.state == .stopped ? Design.Status.warning : Design.Status.positive,
            factLines: facts,
            accessibilityValue: spoken.joined(separator: " · ")
        )
    }

    /// Relative, because "8 min ago" answers "did the agent just start this or is it left
    /// over" without the reader doing arithmetic against a clock.
    private static let startFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func rebuild(_ snapshot: SessionInfoSnapshot, isRunning: Bool) {
        list.clear()
        processRows.removeAll()
        usageRows.removeAll()
        remainingModelsNote = nil
        usageIndexNote = nil
        // A pid that left the tree is forgotten with it, so the set stays as small as the list.
        expandedProcessIDs.formIntersection(snapshot.processes.map(\.pid))

        addUsage(usageSnapshot)

        guard isRunning else {
            list.addNote(L10n.string("This session isn’t running."))
            return
        }

        list.addSection(L10n.string("Processes"))
        for (index, group) in snapshot.processGroups.enumerated() {
            if snapshot.namesProcessOrigins {
                add(originTitle: group.origin, breathes: index > 0)
            }
            group.processes.forEach(add(process:))
        }

        list.addSection(L10n.string("Ports"))
        if snapshot.ports.isEmpty {
            list.addNote(L10n.string("Nothing listening."))
        } else {
            for (index, group) in snapshot.portGroups.enumerated() {
                if snapshot.namesPortOrigins {
                    add(originTitle: group.origin, breathes: index > 0)
                }
                group.ports.forEach(add(port:))
            }
        }
    }

    private var currentUsageSnapshot: SessionUsageSnapshot? {
        usageSource?() ?? SessionUsageService.shared.snapshot(for: sessionID)
    }

    /// A fixed form over an unbounded ledger: the projector has already aggregated the full
    /// session and capped model rows before this method constructs any views.
    private func addUsage(_ snapshot: SessionUsageSnapshot?) {
        list.addSection(L10n.string("Usage"))
        guard let snapshot else {
            list.addNote(L10n.string("Session usage is being indexed."))
            return
        }

        let total = snapshot.total
        guard !total.isEmpty else {
            list.addNote(L10n.string("No usage recorded yet"))
            usageIndexNote = list.addFootnote(usageIndexText(snapshot))
            return
        }

        let presentation = usagePresentation(for: snapshot)
        presentation.leading.forEach(addUsageRow)

        addUsageSubheading(L10n.string("Token breakdown"))
        presentation.breakdown.forEach(addUsageRow)

        if !presentation.models.isEmpty {
            addUsageSubheading(L10n.string("Models"))
            presentation.models.forEach(addUsageRow)
            if presentation.remainingModelCount > 0 {
                remainingModelsNote = list.addNote(L10n.format(
                    "%lld more models are included in the total.",
                    Int64(presentation.remainingModelCount)
                ))
            }
        }
        usageIndexNote = list.addFootnote(usageIndexText(snapshot))
    }

    /// The receipt says each thing once. A session without delegated work has one reading, so
    /// Main agent and Subagents rows appear only when there is a split to show; a session on
    /// one model names it beside the total instead of repeating the total under "Models".
    private func usagePresentation(for snapshot: SessionUsageSnapshot) -> UsagePresentation {
        let total = snapshot.total
        let listsModels = Self.listsModels(snapshot)

        var totalSecondary = SessionUsageFormat.responseCount(total.records)
        if !listsModels, let model = total.models.first {
            totalSecondary += SessionInfoLayout.detailSeparator + ModelName.display(for: model.name)
        }

        var leading = [
            UsageRowPresentation(
                id: .total,
                primary: L10n.string("Total"),
                secondary: totalSecondary,
                values: usageValues(total)
            )
        ]
        if Self.hasDelegatedWork(snapshot) {
            leading.append(UsageRowPresentation(
                id: .mainAgent,
                primary: L10n.string("Main agent"),
                secondary: SessionUsageFormat.responseCount(snapshot.main.records),
                values: usageValues(snapshot.main)
            ))
            leading.append(UsageRowPresentation(
                id: .subagents,
                primary: L10n.string("Subagents"),
                secondary: SessionUsageFormat.responseCount(snapshot.subagents.records),
                values: usageValues(snapshot.subagents)
            ))
        }

        var breakdown = [
            UsageRowPresentation(
                id: .input,
                primary: L10n.string("Input"),
                secondary: L10n.string("Uncached input"),
                values: [SessionUsageFormat.tokenCount(total.tokens.uncachedInput)]
            ),
            UsageRowPresentation(
                id: .cache,
                primary: L10n.string("Cache"),
                secondary: L10n.format(
                    "%@ read · %@ written",
                    UsageFormat.tokens(total.tokens.cachedInput),
                    UsageFormat.tokens(total.tokens.cacheWrite)
                ),
                values: [SessionUsageFormat.tokenCount(
                    total.tokens.cachedInput + total.tokens.cacheWrite
                )]
            ),
            UsageRowPresentation(
                id: .output,
                primary: L10n.string("Output"),
                secondary: total.tokens.reasoning > 0
                    ? L10n.format("%@ reasoning", UsageFormat.tokens(total.tokens.reasoning))
                    : "",
                values: [SessionUsageFormat.tokenCount(total.tokens.output)]
            ),
            UsageRowPresentation(
                id: .cost,
                primary: L10n.string("Cost"),
                secondary: SessionUsageFormat.costProvenance(total),
                values: [SessionUsageFormat.costAmount(total)]
            )
        ]
        if total.unindexedTokens > 0 {
            breakdown.append(UsageRowPresentation(
                id: .pending,
                primary: L10n.string("Awaiting index"),
                secondary: L10n.string("Live child total; category and cost not available yet"),
                values: [SessionUsageFormat.tokenCount(total.unindexedTokens)]
            ))
        }

        let models = listsModels ? total.models.map { model in
            UsageRowPresentation(
                id: .model(model.name),
                primary: ModelName.display(for: model.name),
                secondary: SessionUsageFormat.responseCount(model.records),
                values: usageValues(SessionUsageSnapshot.Reading(
                    tokens: model.tokens,
                    cost: model.cost,
                    records: model.records
                ))
            )
        } : []
        return UsagePresentation(
            leading: leading,
            breakdown: breakdown,
            models: models,
            remainingModelCount: listsModels ? total.remainingModelCount : 0
        )
    }

    private func usageValues(_ reading: SessionUsageSnapshot.Reading) -> [String] {
        var values = [SessionUsageFormat.tokenCount(reading.processedTokens)]
        if let cost = SessionUsageFormat.compactCost(reading) { values.append(cost) }
        return values
    }

    /// A receipt row: no glyph — a different little symbol beside every line of a receipt was
    /// decoration the eye had to step over — but the glyph's slot kept, so the receipt's text
    /// stands on the same column as the process names under it.
    private func addUsageRow(_ presentation: UsageRowPresentation) {
        let row = SessionInfoRowView(
            symbolName: nil,
            symbolColor: Design.Text.secondary,
            primary: presentation.primary,
            secondary: presentation.secondary,
            valueSegments: presentation.values,
            face: .receipt,
            accessibilityLabel: presentation.accessibilityLabel
        )
        usageRows[presentation.id] = row
        list.addRow(row)
    }

    private func updateUsageValues(_ snapshot: SessionUsageSnapshot?) {
        guard let snapshot else { return }
        usageIndexNote?.stringValue = usageIndexText(snapshot)
        guard !snapshot.total.isEmpty else { return }

        let presentation = usagePresentation(for: snapshot)
        for value in presentation.rows {
            guard let row = usageRows[value.id] else {
                assertionFailure("Usage shape matched without row \(value.id)")
                continue
            }
            row.updateSummary(
                secondary: value.secondary,
                valueSegments: value.values,
                accessibilityLabel: value.accessibilityLabel
            )
        }
        if presentation.remainingModelCount > 0 {
            remainingModelsNote?.stringValue = L10n.format(
                "%lld more models are included in the total.",
                Int64(presentation.remainingModelCount)
            )
        }
    }

    private func addUsageSubheading(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Spacing.small),
            label.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.tight),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        list.addRow(host)
    }

    private func usageIndexText(_ snapshot: SessionUsageSnapshot) -> String {
        var parts: [String] = []
        switch snapshot.indexedRange {
        case .lifetime:
            parts.append(L10n.string("Lifetime transcript index"))
        case .lastNinetyDays:
            parts.append(L10n.string("Last 90 days; rebuilding lifetime index"))
        case .unavailable:
            parts.append(L10n.string("Transcript index unavailable"))
        }
        if let builtAt = snapshot.builtAt {
            parts.append(L10n.format("Updated %@", UsageFormat.age(of: builtAt)))
        }
        if let version = snapshot.pricingCatalogVersion {
            parts.append(L10n.format("Price catalog %@", version))
        }
        if let coverage = snapshot.coverage, coverage.state != .complete {
            parts.append(coverage.detail ?? L10n.string("Partial"))
        }
        guard let scope = parts.first else { return "" }
        let provenance = parts.dropFirst().joined(separator: " · ")
        return [scope, provenance].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func add(process: SessionProcess) {
        // The positive status role, not the accent: a running process is a *state*, and the
        // accent already means "this session wants you" in the sidebar it sits beside. A column
        // of accent dots said that about four processes doing nothing but running.
        let row = SessionInfoRowView(
            symbolName: SessionInfoSymbols.process,
            symbolColor: Design.Status.positive,
            primary: process.command,
            secondary: "\(process.pid)",
            valueSegments: [process.formattedCPU, process.formattedMemory],
            indentLevel: process.depth,
            commandLine: commandLine(for: process),
            isExpandable: true,
            accessibilityLabel: L10n.format("%@ · process %lld", process.command, Int64(process.pid))
        )
        row.update(reading(for: process))
        row.setAccessibilityIdentifier(SessionInfoDefaults.processRowIdentifier(process.pid))

        // The fold outlives the row: restored here after a rebuild, recorded when the user
        // changes it.
        let pid = process.pid
        row.setExpanded(expandedProcessIDs.contains(pid))
        row.onExpansionChange = { [weak self] expanded in
            if expanded {
                self?.expandedProcessIDs.insert(pid)
            } else {
                self?.expandedProcessIDs.remove(pid)
            }
        }

        // Never on a root — session teardown owns those — and never without the start identity
        // that authorises the signal: no identity, no kill.
        if !process.isRoot, let startTime = process.startTime {
            let command = process.command
            row.offerStop(titled: L10n.format("Stop %@", command)) { [weak self] in
                self?.requestStop(of: pid, command: command, startTime: startTime)
            }
        }

        processRows[process.pid] = row
        list.addRow(row)
    }

    /// Asks, signals, and lets the next poll show the truth. A skipped kill — the process
    /// already gone, or the pid meaning somebody else by now — is deliberately silent in the
    /// UI: the journal records it, and the refreshed list *is* the answer.
    private func requestStop(of pid: pid_t, command: String, startTime: ProcessStartTime) {
        let request = ConfirmationRequest(
            prompt: .stopSessionProcess,
            title: L10n.format("Stop %@?", command),
            message: L10n.format(
                "Process %lld receives a terminate signal. The session itself keeps running.",
                Int64(pid)
            ),
            confirmTitle: L10n.string("Stop")
        )

        let proceed: @MainActor (Bool) -> Void = { [weak self] allowed in
            guard allowed, let self else { return }
            if let onStopProcess = self.onStopProcess {
                onStopProcess(pid, startTime)
            } else {
                SessionProcessTerminator.terminate(pid: pid, expectedStart: startTime)
            }
            self.refresh()
        }

        if let confirmStop {
            proceed(confirmStop(request))
        } else {
            ConfirmationAlert.ask(request, in: view.window) { proceed($0) }
        }
    }

    /// What the row shows and what it can reveal. Display lines omit `argv[0]` — the primary
    /// label already names the process — while the tooltip carries the whole line. Secrets are
    /// hidden by `CommandLineRedactor` before anything is drawn; the raw vector survives only
    /// inside the row, behind its reveal.
    private func commandLine(for process: SessionProcess) -> SessionInfoRowView.CommandLine? {
        SessionInfoRowView.CommandLine(processArguments: process.arguments)
    }

    private func add(port: ListeningPort) {
        // Only a port localhost can actually reach is offered as a link; handing over a URL that
        // cannot connect would be worse than showing none.
        let url = port.localURL
        let row = SessionInfoRowView(
            symbolName: SessionInfoSymbols.port,
            symbolColor: Design.Text.secondary,
            primary: "\(port.port)",
            secondary: port.command,
            valueSegments: [port.interface.displayName],
            accessibilityLabel: L10n.format("Port %lld · %@", Int64(port.port), port.command),
            action: url.map { url in { [weak self] in self?.onOpenURL?(url) } }
        )
        row.toolTip = url.map {
            L10n.format(
                "Open %@ — bound to %@",
                $0.absoluteString,
                port.address
            )
        } ?? L10n.format(
            "Listening on %@:%lld",
            port.address,
            Int64(port.port)
        )
        list.addRow(row)
    }

    /// A sub-heading under a section: which of the session's two roots contributed the rows
    /// that follow. The section's own regular face — caption's semibold made "Agent" louder
    /// than the "Processes" over it, which read as the hierarchy inverted — one shade brighter
    /// than the section, and subordinated by *position*: indented one step onto the glyph
    /// column, with a breath above a second group so the division is felt before it is read.
    private func add(originTitle origin: SessionInfoOrigin, breathes: Bool) {
        if breathes {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: Design.Spacing.tight).isActive = true
            list.addRow(spacer)
        }

        let label = NSTextField(labelWithString: L10n.string(origin.rawValue))
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false

        let indented = NSView()
        indented.translatesAutoresizingMaskIntoConstraints = false
        indented.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: indented.leadingAnchor, constant: Design.Spacing.small),
            label.trailingAnchor.constraint(lessThanOrEqualTo: indented.trailingAnchor),
            label.topAnchor.constraint(equalTo: indented.topAnchor),
            label.bottomAnchor.constraint(equalTo: indented.bottomAnchor)
        ])
        list.addRow(indented)
    }

    // MARK: - Session State

    /// The session's live root process, whichever surface it runs on.
    ///
    /// A terminal session's root is the login shell that `exec`s the agent. A natively rendered
    /// one has no PTY at all — its process belongs to the stream transport — and asking only the
    /// terminal runtime is why the panel first reported every native conversation as "not
    /// running", which is the surface most of these sessions actually use.
    ///
    /// A terminal controller that exists but has not yet captured its child reads as pid 0, so
    /// that is treated as absent rather than passed on as a root.
    private var agentRootPid: pid_t? {
        if let terminal = AgentRuntime.shared.controller(for: sessionID)?.session.shellPid, terminal > 0 {
            return terminal
        }
        return AgentRuntime.shared.conversation(for: sessionID)?.stream.rootProcessIdentifier
    }

    /// Where the agent is *now*, not where the session began — the same rule the shell drawer
    /// follows, and for the same reason: an agent that has spent ten minutes inside a subpackage
    /// is running its servers from there.
    private var currentDirectory: URL {
        AgentRuntime.shared.controller(for: sessionID)?.session.effectiveWorkingDirectory()
            ?? URL(fileURLWithPath: folderPath)
    }

    private func gitDescription(for directory: URL) -> String {
        guard let branch = GitInfo.currentBranch(for: directory.path) else { return "" }
        guard let worktree = GitInfo.worktreeName(for: directory.path) else { return branch }
        return "\(branch) · \(worktree)"
    }

    // MARK: - Actions

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentDirectory])
    }

    private func copyDirectory() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentDirectory.path, forType: .string)
    }
}

// MARK: - Defaults

extension SessionInfoDefaults {
    /// The stable identity of a process row, for tests and assistive tooling. The spoken label
    /// is localized and groups the pid's digits, which is right for a person and wrong for a
    /// lookup.
    static func processRowIdentifier(_ pid: pid_t) -> String {
        "session-info.process.\(pid)"
    }
}

enum SessionInfoSymbols {
    /// The header's two directory actions: the folder in Finder, the path on the pasteboard.
    static let reveal = "folder"
    static let copy = "doc.on.doc"

    /// A process is a running thing, not a file — the filled dot is the status vocabulary the
    /// sidebar already uses for "alive".
    static let process = "circle.fill"

    /// A listening socket is reachable over the network, which is what the globe says.
    static let port = "globe"
}
