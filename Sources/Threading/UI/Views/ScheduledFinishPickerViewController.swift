import AppKit

// MARK: - Finish Trigger Candidate

/// One live conversation whose current turn can be used as a scheduling trigger.
///
/// Strings are resolved while the menu opens, leaving the searchable value `Sendable` so a
/// large candidate set can be filtered away from the main actor. The session id remains the
/// durable answer; every other field is presentation.
struct ScheduledFinishCandidate: Equatable, Sendable, Identifiable {
    let id: SessionID
    let title: String
    let projectName: String
    let agentName: String
    let agentKind: AgentKind

    nonisolated func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || projectName.localizedCaseInsensitiveContains(query)
            || agentName.localizedCaseInsensitiveContains(query)
            || id.uuidString.localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Candidate Discovery

@MainActor
enum ScheduledFinishCandidates {

    /// Reads every stored session once when the schedule menu opens, but materializes values only
    /// for conversations that are both mid-turn and report their own boundaries. Expected scale
    /// is 2–12 live turns; the 5,000-session sidebar stress scale remains a cheap value scan, and
    /// the picker below owns only viewport row views even if hundreds are live at once.
    static func current() -> [ScheduledFinishCandidate] {
        make(
            projects: ProjectStore.shared.projects,
            runtime: { AgentRuntime.shared.runtimeSnapshot(sessionID: $0) }
        )
    }

    static func make(
        projects: [Project],
        runtime: (SessionID) -> SessionRuntimeSnapshot
    ) -> [ScheduledFinishCandidate] {
        var candidates: [ScheduledFinishCandidate] = []
        for project in projects {
            for session in project.sessions where !session.isArchived {
                let snapshot = runtime(session.id)
                guard snapshot.hasPendingOutcome, snapshot.reportsOwnTurns else { continue }
                let agentName = session.accountHandle.isStandard
                    ? session.kind.displayName
                    : "\(session.kind.displayName) · \(session.accountHandle.name)"
                candidates.append(ScheduledFinishCandidate(
                    id: session.id,
                    title: session.displayTitle,
                    projectName: project.name,
                    agentName: agentName,
                    agentKind: session.kind
                ))
            }
        }
        return candidates
    }
}

// MARK: - Finish Trigger Picker

/// Picks the conversation whose current turn must finish before a scheduled send is owed.
///
/// This is a sheet rather than a menu because session cardinality is external. Rows are virtual,
/// and search over a stress-scale live set runs off the main actor before replacing the value
/// model shown by the table.
@MainActor
final class ScheduledFinishPickerViewController: NSViewController {

    // MARK: - Properties

    private let candidates: [ScheduledFinishCandidate]
    private var visible: [ScheduledFinishCandidate]
    private var query = ""
    private var selectedID: SessionID?
    private var filterGeneration = 0
    private var filterTask: Task<Void, Never>?
    private var isRewritingList = false

    private let headingLabel = NSTextField(labelWithString: "")
    private let subheadingLabel = NSTextField(labelWithString: "")
    private let searchField = ThemedSearchField()
    private let tableView = ThemedTableView()
    private let scheduleButton = ThemedButton()
    private let appEvents = AppEventObservations()

    /// The selected conversation, or nil when Cancel closes the sheet.
    var onPick: ((ScheduledFinishCandidate?) -> Void)?

    // MARK: - Initialization

    init(candidates: [ScheduledFinishCandidate]) {
        self.candidates = candidates
        self.visible = candidates
        self.selectedID = candidates.first?.id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        filterTask?.cancel()
    }

    // MARK: - Lifecycle

    override func loadView() {
        let surface = ThemedSurfaceView()
        surface.frame = NSRect(
            x: 0,
            y: 0,
            width: ScheduledFinishPickerLayout.sheetWidth,
            height: ScheduledFinishPickerLayout.sheetHeight
        )
        surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        view = surface
        setupViews()
        updateSubheading()
        rewritingList {
            tableView.reloadData()
            restoreSelection()
        }
        refreshScheduleButton()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
        applyTheme()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Setup

    private func setupViews() {
        headingLabel.stringValue = ScheduledFinishPickerStrings.heading
        headingLabel.applyFont(.heading)

        subheadingLabel.applyFont(.subheading)

        let headings = NSStackView(views: [headingLabel, subheadingLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = Design.Spacing.hairline

        searchField.placeholderString = ScheduledFinishPickerStrings.searchPlaceholder
        searchField.applyFont(.body)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(confirm)

        let stack = NSStackView(views: [headings, searchField, makeTable(), makeFooter()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: headings)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            stack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.pane
            )
        ])
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeTable() -> NSView {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = ScheduledFinishPickerLayout.rowHeight
        tableView.style = .inset
        tableView.doubleAction = #selector(confirm)
        tableView.target = self
        tableView.setAccessibilityLabel(ScheduledFinishPickerStrings.listAccessibilityLabel)
        tableView.addTableColumn(NSTableColumn(identifier: ScheduledFinishPickerColumn.session))

        let scrollView = ThemedScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: ScheduledFinishPickerLayout.minimumListHeight
        ).isActive = true
        return scrollView
    }

    private func makeFooter() -> NSView {
        scheduleButton.title = ScheduledFinishPickerStrings.scheduleTitle
        scheduleButton.isProminent = true
        scheduleButton.keyEquivalent = "\r"
        scheduleButton.target = self
        scheduleButton.action = #selector(confirm)

        let cancelButton = ThemedButton(
            title: ScheduledFinishPickerStrings.cancelTitle,
            target: self,
            action: #selector(cancel)
        )
        cancelButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [spacer, cancelButton, scheduleButton])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small
        return footer
    }

    // MARK: - Searching And Selection

    func updateSearchQuery(_ value: String) {
        searchField.stringValue = value
        applySearch()
    }

    var visibleSessionIDs: [SessionID] { visible.map(\.id) }
    var selectedSessionIDForTesting: SessionID? { selectedID }
    var scheduleButtonIsEnabledForTesting: Bool { scheduleButton.isEnabled }

    func selectSession(_ sessionID: SessionID) {
        selectedID = sessionID
        restoreSelection()
        refreshScheduleButton()
    }

    private func applySearch() {
        query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        filterTask?.cancel()
        filterGeneration += 1
        let generation = filterGeneration

        guard !query.isEmpty else {
            applyFiltered(candidates, generation: generation)
            return
        }

        let candidates = self.candidates
        let query = self.query
        filterTask = Task { [weak self] in
            let filtered = await Task.detached(priority: .userInitiated) {
                candidates.filter { $0.matches(query) }
            }.value
            guard !Task.isCancelled else { return }
            self?.applyFiltered(filtered, generation: generation)
        }
    }

    private func applyFiltered(_ filtered: [ScheduledFinishCandidate], generation: Int) {
        guard generation == filterGeneration else { return }
        visible = filtered
        if selectedID.map({ id in visible.contains { $0.id == id } }) != true {
            selectedID = visible.first?.id
        }
        rewritingList {
            tableView.reloadData()
            restoreSelection()
        }
        updateSubheading()
        refreshScheduleButton()
    }

    private func restoreSelection() {
        guard let selectedID,
              let row = visible.firstIndex(where: { $0.id == selectedID }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func rewritingList(_ work: () -> Void) {
        isRewritingList = true
        work()
        isRewritingList = false
    }

    private func updateSubheading() {
        subheadingLabel.stringValue = visible.count == candidates.count
            ? ScheduledFinishPickerStrings.subheading(count: candidates.count)
            : ScheduledFinishPickerStrings.filteredSubheading(
                shown: visible.count,
                of: candidates.count
            )
    }

    private func refreshScheduleButton() {
        scheduleButton.isEnabled = selectedID != nil
    }

    // MARK: - Theme

    private func applyTheme() {
        headingLabel.textColor = Design.Text.label
        subheadingLabel.textColor = Design.Text.secondary
        tableView.rowHeight = ScheduledFinishPickerLayout.rowHeight
        // The labels restyle themselves, but each row's template icon resolves its tint once.
        // Row height also follows the theme's two line boxes; Cyberpunk's larger monospace face
        // cannot fit the fixed 44pt that System can. Rebuilding only the viewport keeps both
        // changes honest without materializing the external-cardinality list.
        rewritingList {
            tableView.reloadData()
            restoreSelection()
        }
    }

    // MARK: - Actions

    @objc func confirm() {
        guard let selectedID,
              let candidate = candidates.first(where: { $0.id == selectedID }) else { return }
        onPick?(candidate)
    }

    @objc func cancel() {
        onPick?(nil)
    }

    // MARK: - Rows

    private func makeRow(for candidate: ScheduledFinishCandidate) -> NSView {
        let icon = NSImageView()
        icon.image = candidate.agentKind.icon
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        icon.contentTintColor = Design.Text.secondary

        let title = SearchMatchLabel(role: .body)
        title.show(candidate.title, matching: query)

        let detail = SearchMatchLabel(role: .subheading, ink: { Design.Text.tertiary })
        detail.show(
            L10n.format("%@ · %@", candidate.projectName, candidate.agentName),
            matching: query
        )

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Design.Spacing.small,
            bottom: 0,
            right: Design.Spacing.small
        )
        return row
    }
}

// MARK: - Search Field

extension ScheduledFinishPickerViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        applySearch()
    }
}

// MARK: - Table

extension ScheduledFinishPickerViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
}

extension ScheduledFinishPickerViewController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard visible.indices.contains(row) else { return nil }
        return makeRow(for: visible[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRewritingList else { return }
        let row = tableView.selectedRow
        selectedID = visible.indices.contains(row) ? visible[row].id : nil
        refreshScheduleButton()
    }
}

// MARK: - Constants

enum ScheduledFinishPickerColumn {
    static let session = NSUserInterfaceItemIdentifier("ScheduledFinishSessionColumn")
}

@MainActor
enum ScheduledFinishPickerLayout {
    static let sheetWidth: CGFloat = 520
    static let sheetHeight: CGFloat = 460
    static let minimumRowHeight: CGFloat = 44
    static var rowHeight: CGFloat {
        max(
            minimumRowHeight,
            Design.Typography.lineHeight(of: Design.Typography.body())
                + Design.Typography.lineHeight(of: Design.Typography.subheading())
                + Design.Spacing.hairline
                + 2 * Design.Spacing.small
        )
    }
    static let minimumListHeight: CGFloat = 240
}

enum ScheduledFinishPickerStrings {
    static var heading: String { L10n.string("When a conversation finishes") }
    static var searchPlaceholder: String { L10n.string("Search working conversations") }
    static var listAccessibilityLabel: String { L10n.string("Working conversations") }
    static var scheduleTitle: String { L10n.string("Schedule") }
    static var cancelTitle: String { L10n.string("Cancel") }

    static func subheading(count: Int) -> String {
        count == 1
            ? L10n.string("Choose the conversation whose current turn should finish first.")
            : L10n.format(
                "Choose among %lld conversations whose current turns are still running.",
                Int64(count)
            )
    }

    static func filteredSubheading(shown: Int, of total: Int) -> String {
        L10n.format("%lld of %lld working conversations", Int64(shown), Int64(total))
    }
}
