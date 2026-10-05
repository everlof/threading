import AppKit
import ThreadingController

/// Host-only editor. Both destinations submit value models to the same operations as MCP.
@MainActor
final class AutomationEditorViewController: NSViewController {
    var configuration: AutomationConfiguration?
    var remoteSpec: ControllerAutomationSpec?
    var onSave: ((AutomationConfiguration?, ControllerAutomationSpec?) async throws -> Void)?
    private let name = ThemedTextField()
    private let instructions = ThemedTextView.scrolling()
    private let target = ThemedPopUp()
    private let worker = ThemedTextField()
    private let workerChoice = ThemedPopUp()
    private let workers: [ControllerWorker]
    private var workerIDs: [WorkerID] = []
    private let agent = ThemedPopUp()
    private let mode = ThemedPopUp()
    private let checkout = ThemedPopUp()
    private let account = ThemedPopUp()
    private let model = ThemedPopUp()
    private let effort = ThemedPopUp()
    private let choices: AutomationAgentChoiceProvider
    private let events = AppEventObservations()
    private var accountValues: [String?] = [nil]
    private var modelValues: [String?] = [nil]
    private var effortValues: [String?] = [nil]
    private var discoveredAccounts: [AgentAccount] = []
    private var signInStatuses: [AccountID: AgentAccountSignInStatus] = [:]
    private var catalog = AutomationAgentCatalog(models: [], defaultModel: nil)
    private var accountTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var accountGeneration = 0
    private var catalogGeneration = 0
    /// The agent choices the automation was saved with. While their agent is selected each stays
    /// in its menu, as a custom entry when this Mac's catalog does not list it, so choosing
    /// something else and back never loses an identifier the catalog does not know.
    private struct SavedChoices {
        let agent: AgentKind
        let account: String?
        let model: String?
        let effort: String?
    }
    private let savedChoices: SavedChoices?
    private let runtime = ThemedTextField()
    private let scheduleFields: AutomationScheduleFields
    private let unattended = ThemedPopUp()
    private let rules = ThemedTextView.scrolling()
    private let source = ThemedPopUp()
    private let eventKind = ThemedTextField()
    private let sources: [TriggerSourceInstallation]
    private let missed = ThemedPopUp()
    private let archive = ThemedToggle()
    private let save = ThemedButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let projects: [Project]
    private let agents = AgentKind.allCases.filter { $0.supportsNativeUI && $0.supportsPermissionModes }
    private let modes = TriggerExecutionMode.allCases
    private let remoteMode: Bool
    var lockedProjectID: ProjectID?

    init(configuration: AutomationConfiguration? = nil, remoteSpec: ControllerAutomationSpec? = nil, remote: Bool = false, sources: [TriggerSourceInstallation] = [], workers: [ControllerWorker] = [], projects: [Project]? = nil, choices: AutomationAgentChoiceProvider = .live) {
        self.choices = choices
        self.workers = workers
        self.sources = sources
        self.configuration = configuration; self.remoteSpec = remoteSpec; self.remoteMode = remote
        savedChoices = configuration.map {
            SavedChoices(agent: $0.agent, account: AccountHandle(storedName: $0.account).persistedSessionName,
                         model: $0.model, effort: $0.reasoningEffort)
        }
        self.projects = projects ?? ProjectStore.shared.projects
        scheduleFields = AutomationScheduleFields(
            schedule: configuration?.options.schedule ?? remoteSpec?.schedule,
            alternative: remote ? L10n.string("Manual or event-driven") : L10n.string("Source event"),
            selectAlternative: remote
                ? (remoteSpec != nil && remoteSpec?.schedule == nil)
                : (configuration?.options.schedule == nil && configuration?.sourceID != nil))
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The tallest the sheet may be, from the window that presents it. Unset, the sheet keeps
    /// `Layout.preferredHeight`.
    var availableHeight: CGFloat?

    /// The sheet's measures. A field is as wide as what it holds: a name and instructions take
    /// the readable measure, a choice the width of its longest choice, and a number or a model
    /// name a short field, so the form reads down one label column instead of one ragged edge.
    enum Layout {
        static let controlWidth = Design.Size.readableWidth
        /// "Assess, then fix if straightforward", the longest choice, whole at the control size.
        static let choiceWidth: CGFloat = 320
        /// A time zone or a provider event kind.
        static let fieldWidth = SettingsUIDefaults.controlWidth
        /// A time, a count of minutes.
        static let numberWidth: CGFloat = 96
        /// Room for a brief of a few paragraphs without the field scrolling.
        static let instructionsHeight: CGFloat = 220
        static let rulesHeight: CGFloat = 110
        static let preferredHeight: CGFloat = 860
        static let minimumHeight: CGFloat = 480
    }

    /// The rows a choice shows or hides, kept so a change of choice can say which apply.
    private var timeRow: NSView?
    private var zoneRow: NSView?
    private var daysRow: NSView?
    private var intervalRow: NSView?
    private var missedRow: NSView?
    private var sourceRow: NSView?
    private var eventKindRow: NSView?
    private var rulesRow: NSView?
    private var grammarRow: NSView?
    private var fullPermissionRow: NSView?
    /// Every row's label, so the column can be as wide as the widest of them.
    private var rowLabels: [NSTextField] = []

    override func loadView() {
        let surface = ThemedSurfaceView()
        surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        view = surface

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = Design.Spacing.small
        // A field's border and a theme's glow reach a hair past its frame; the form keeps that
        // hair inside the scroll view's clip rather than shaving the trailing corners off.
        form.edgeInsets = NSEdgeInsets(
            top: 0, left: Design.Spacing.tight, bottom: Design.Spacing.large, right: Design.Spacing.tight)
        form.translatesAutoresizingMaskIntoConstraints = false
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let clip = FlippedClipView(); clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = form
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let isNew = (configuration == nil || configuration?.name.isEmpty == true) && remoteSpec == nil
        let heading = NSTextField(labelWithString: isNew ? L10n.string("New Automation") : L10n.string("Edit Automation"))
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        let lede = NSTextField(wrappingLabelWithString: L10n.string(
            "Saving pauses the automation. Enable it when you are ready. Results remain in Activity after a successful run is archived."))
        lede.applyFont(.subheading)
        lede.textColor = Design.Text.secondary
        form.addArrangedSubview(heading)
        form.addArrangedSubview(lede)
        form.setCustomSpacing(Design.Spacing.tight, after: heading)

        name.setAccessibilityIdentifier("automation.name")
        instructions.textView.setAccessibilityIdentifier("automation.instructions")
        save.setAccessibilityIdentifier("automation.save")
        name.stringValue = configuration?.name ?? remoteSpec?.name ?? ""
        instructions.textView.string = configuration?.instructions ?? remoteSpec?.instruction ?? ""
        instructions.heightAnchor.constraint(equalToConstant: Layout.instructionsHeight).isActive = true
        Self.applyFieldSurface(to: instructions, font: .body)

        // Task: what it is called, where it runs, and what it is asked to do.
        addSection("Task", to: form)
        addRow("Name", name, width: Layout.controlWidth, to: form)
        if remoteMode {
            for entry in workers { workerChoice.addItem(withTitle: entry.name); workerIDs.append(entry.id) }
            if let id = remoteSpec?.workerID {
                if !workerIDs.contains(id) { workerChoice.addItem(withTitle: id.description); workerIDs.append(id) }
                workerChoice.selectItem(at: workerIDs.firstIndex(of: id)!)
            }
            if workerIDs.isEmpty { addRow("Worker ID", worker, width: Layout.fieldWidth, to: form) }
            else { addRow("Worker", workerChoice, width: Layout.choiceWidth, to: form) }
            worker.stringValue = remoteSpec?.workerID.description ?? ""
        } else {
            for project in projects { target.addItem(withTitle: project.name) }
            if let id = configuration?.projectID {
                // A project that has left the sidebar stays visibly unchosen. Falling back to the
                // first row would quietly move the automation, and its edits, to another repository.
                if let index = projects.firstIndex(where: { $0.id == id }) { target.selectItem(at: index) }
                else { target.addItem(withTitle: L10n.string("Unavailable project")); target.selectItem(at: projects.count) }
            }
            target.isEnabled = lockedProjectID == nil
            addRow("Project", target, width: Layout.choiceWidth, to: form)
        }
        addRow("Instructions", instructions, width: Layout.controlWidth, to: form)

        // When: the schedule, or the event it waits for. Only the controls the choice reads
        // are on the sheet; the rest leave it rather than standing there disabled.
        addSection("When", to: form)
        let fields = scheduleFields
        fields.onChange = { [weak self] in self?.cadenceChanged() }
        addRow("Repeat", fields.cadence, width: Layout.choiceWidth, to: form)
        timeRow = addRow("Time (HH:mm)", fields.time, width: Layout.numberWidth, to: form)
        zoneRow = addRow("Time zone", fields.zone, width: Layout.fieldWidth, to: form)
        daysRow = addRow("Days", fields.days, to: form)
        intervalRow = addRow("Interval (minutes)", fields.interval, width: Layout.numberWidth, to: form)
        if !remoteMode {
            for entry in sources { source.addItem(withTitle: entry.displayName) }
            if let id = configuration?.sourceID {
                if let index = sources.firstIndex(where: { $0.id == id }) { source.selectItem(at: index) }
                else { source.addItem(withTitle: L10n.string("Unavailable source")); source.selectItem(at: sources.count) }
            }
            eventKind.stringValue = configuration?.eventKind ?? ""
            sourceRow = addRow("Event source", source, width: Layout.choiceWidth, to: form)
            eventKindRow = addRow("Event kind", eventKind, width: Layout.fieldWidth, to: form)
        }
        missed.addItem(withTitle: L10n.string("Skip missed runs"))
        missed.addItem(withTitle: L10n.string("Run once on return"))
        missed.selectItem(at: configuration?.options.missedRunPolicy == .latest || remoteSpec?.missedPolicy == .latest ? 1 : 0)
        missedRow = addRow("When offline", missed, width: Layout.choiceWidth, to: form)

        if !remoteMode {
            // Agent: who runs it, as which login, on which model.
            addSection("Agent", to: form)
            for value in agents { agent.addItem(withTitle: value.displayName) }
            agent.selectItem(at: agents.firstIndex(of: configuration?.agent ?? .codex) ?? 0)
            agent.setAccessibilityIdentifier("automation.agent")
            agent.target = self; agent.action = #selector(agentChanged)
            addRow("Agent", agent, width: Layout.choiceWidth, to: form)
            account.setAccessibilityIdentifier("automation.account")
            model.setAccessibilityIdentifier("automation.model")
            effort.setAccessibilityIdentifier("automation.effort")
            account.target = self; account.action = #selector(accountChanged)
            model.target = self; model.action = #selector(modelChanged)
            // Preserve stored identifiers while their bounded asynchronous lookup is pending.
            accountValues = fillChoices(account, values: [], titles: [], selected: saved(\.account),
                                        unlistedTitle: Self.missingLoginTitle)
            modelValues = fillChoices(model, values: [], titles: [], selected: saved(\.model))
            effortValues = fillChoices(effort, values: [], titles: [], selected: saved(\.effort))
            addRow("Account", account, width: Layout.choiceWidth, to: form)
            addRow("Model", model, width: Layout.choiceWidth, to: form)
            addRow("Reasoning effort", effort, width: Layout.choiceWidth, to: form)

            // Permissions: what a run may do with nobody there to ask.
            addSection("Permissions", to: form)
            for title in ["Assess only", "Assess, then fix if straightforward", "Read-only task", "Task with local edits"] { mode.addItem(withTitle: L10n.string(title)) }
            mode.selectItem(at: modes.firstIndex(of: configuration?.executionMode ?? .taskReadOnly) ?? 0)
            addRow("Permissions", mode, width: Layout.choiceWidth, to: form)
            checkout.addItem(withTitle: L10n.string("Existing project checkout"))
            checkout.addItem(withTitle: L10n.string("Isolated managed worktree"))
            checkout.addItem(withTitle: L10n.string("Automation workspace"))
            checkout.selectItem(at: configuration?.checkoutPolicy == .automationWorkspace ? 2 : configuration?.checkoutPolicy == .managedWorktree ? 1 : 0)
            addRow("Checkout", checkout, width: Layout.choiceWidth, to: form)
            // Unattended runs never ask, so what they may do is decided here and approved with
            // the revision. Remote workers own their permissions and are not offered this.
            unattended.addItem(withTitle: L10n.string("Allow-list"))
            unattended.addItem(withTitle: L10n.string("Full permission"))
            let policy = configuration?.permissions ?? .readOnly
            unattended.selectItem(at: policy.isFull ? 1 : 0)
            unattended.target = self; unattended.action = #selector(unattendedChanged)
            addRow("Without asking", unattended, width: Layout.choiceWidth, to: form)
            rules.textView.string = policy.rules.map(\.text).joined(separator: "\n")
            rules.textView.setAccessibilityIdentifier("automation.rules")
            rules.heightAnchor.constraint(equalToConstant: Layout.rulesHeight).isActive = true
            Self.applyFieldSurface(to: rules, font: .code())
            rulesRow = addRow("Rules (one per line)", rules, width: Layout.controlWidth, to: form)
            grammarRow = addRow(nil, note(
                "Unattended runs never ask. Bash(command) or Bash(command *), Write(/folder/**), WebFetch(domain:example.com), mcp__server__tool. Reads and read-only commands are always allowed; anything else is refused.",
                color: Design.Text.secondary), width: Layout.controlWidth, to: form)
            fullPermissionRow = addRow(nil, note(
                "Every command runs without asking. A call that would raise a macOS permission prompt is still refused.",
                color: Design.Status.warning), width: Layout.controlWidth, to: form)
        }

        // After: how long a run may take and what happens to its chat.
        addSection("After a run", to: form)
        if !remoteMode {
            runtime.stringValue = String(configuration?.maximumRuntimeMinutes ?? 60)
            addRow("Maximum runtime (minutes)", runtime, width: Layout.numberWidth, to: form)
        }
        archive.state = (configuration?.options.archiveOnSuccess ?? remoteSpec?.archiveOnSuccess ?? true) ? .on : .off
        addRow("Archive successful runs", archive, to: form)

        // Every label takes the widest one's measure, so the controls start on one line.
        let labelWidth = ceil(rowLabels.map(\.fittingSize.width).max() ?? 0)
        for label in rowLabels { label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true }
        let formWidth = labelWidth + Design.Spacing.medium + Layout.controlWidth + Design.Spacing.tight * 2
        lede.preferredMaxLayoutWidth = formWidth

        errorLabel.applyFont(.detail())
        errorLabel.textColor = Design.Status.negative
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = ThemedButton(); cancel.title = L10n.string("Cancel"); cancel.target = self; cancel.action = #selector(cancelPressed)
        cancel.keyEquivalent = "\u{1b}"
        save.title = L10n.string("Save automation"); save.emphasis = .primary; save.target = self; save.action = #selector(savePressed)
        // A refusal stands beside the button that was refused, not at the end of a form that
        // may be scrolled away from it.
        let buttons = NSStackView(views: [errorLabel, NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = Design.Spacing.medium
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)
        let separator = SeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        let height = max(Layout.minimumHeight, min(Layout.preferredHeight, availableHeight ?? Layout.preferredHeight))
        view.frame = NSRect(x: 0, y: 0, width: formWidth + (Design.Spacing.pane - Design.Spacing.tight) * 2, height: height)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane - Design.Spacing.tight),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -(Design.Spacing.pane - Design.Spacing.tight)),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            form.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -Design.Spacing.medium),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.pane),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.inset),
        ])
        for child in form.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -Design.Spacing.tight * 2).isActive = true
        }
        cadenceChanged()
        unattendedChanged()
        if !remoteMode {
            events.observe(AgentModelsDidChange.self) { [weak self] _ in self?.loadCatalog() }
            events.observe(AccountUsageDidChange.self) { [weak self] _ in self?.updateAccounts() }
            loadAccounts()
        }
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(name) }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        accountTask?.cancel(); catalogTask?.cancel(); statusTask?.cancel()
    }

    private var selectedAgent: AgentKind { agents[agent.indexOfSelectedItem] }

    private func selectedValue(_ control: ThemedPopUp, values: [String?]) -> String? {
        values.indices.contains(control.indexOfSelectedItem) ? values[control.indexOfSelectedItem] : nil
    }

    /// The saved choice for the selected agent, or nil once another agent is chosen.
    private func saved(_ choice: KeyPath<SavedChoices, String?>) -> String? {
        guard let savedChoices, savedChoices.agent == selectedAgent else { return nil }
        return savedChoices[keyPath: choice]
    }

    /// A model or effort the catalog does not list may still be one the CLI accepts.
    nonisolated private static func customTitle(_ identifier: String) -> String {
        L10n.format("%@ — Custom", identifier)
    }

    /// A login is either on this Mac or not.
    nonisolated private static func missingLoginTitle(_ identifier: String) -> String {
        L10n.format("%@ — Unavailable", identifier)
    }

    /// Default always comes first. The saved choice and the current one stay in the menu, with
    /// their machine ids, even when the catalog does not list them: merely opening and saving an
    /// old automation must not rewrite it, and a saved custom entry stays selectable.
    private func fillChoices(_ control: ThemedPopUp, values: [String], titles: [String], selected: String?,
                             saved: String? = nil,
                             unlistedTitle: (String) -> String = AutomationEditorViewController.customTitle,
                             defaultTitle: String = L10n.string("Default")) -> [String?] {
        control.removeAllItems()
        control.addItem(withTitle: defaultTitle)
        var identifiers: [String?] = [nil]
        for (value, title) in zip(values, titles) {
            identifiers.append(value); control.addItem(withTitle: title)
        }
        for extra in [saved, selected].compactMap({ $0 }) where !identifiers.contains(extra) {
            identifiers.append(extra)
            control.addItem(withTitle: unlistedTitle(extra))
        }
        control.selectItem(at: identifiers.firstIndex(of: selected) ?? 0)
        return identifiers
    }

    @objc private func agentChanged() {
        accountValues = fillChoices(account, values: [], titles: [], selected: nil, saved: saved(\.account),
                                    unlistedTitle: Self.missingLoginTitle)
        modelValues = fillChoices(model, values: [], titles: [], selected: nil, saved: saved(\.model))
        effortValues = fillChoices(effort, values: [], titles: [], selected: nil, saved: saved(\.effort))
        catalog = .init(models: [], defaultModel: nil)
        loadAccounts()
    }

    @objc private func accountChanged() { loadCatalog() }

    @objc private func modelChanged() { updateEfforts(preservingUnavailable: false) }

    private func loadAccounts() {
        accountTask?.cancel(); catalogTask?.cancel(); statusTask?.cancel()
        accountGeneration += 1; catalogGeneration += 1
        let generation = accountGeneration
        let kind = selectedAgent
        discoveredAccounts = []; signInStatuses = [:]
        account.isEnabled = false; model.isEnabled = false; effort.isEnabled = false
        accountTask = Task { [weak self] in
            guard let self else { return }
            let accounts = await choices.accounts(kind)
            guard !Task.isCancelled, generation == accountGeneration else { return }
            let kept = Set([selectedValue(account, values: accountValues), saved(\.account)].compactMap { $0 })
            // Admit the standard, current and saved logins before the ordinary 32-account bound.
            let prioritized = accounts.filter { $0.isDefault || kept.contains($0.handle.name) }
                + accounts.filter { !$0.isDefault && !kept.contains($0.handle.name) }
            discoveredAccounts = Array(prioritized.prefix(32))
            updateAccounts()
            account.isEnabled = true
            loadCatalog()
            loadSignInStatuses(generation: generation)
        }
    }

    private func updateAccounts() {
        let selected = selectedValue(account, values: accountValues)
        let savedLogin = saved(\.account)
        let offered = discoveredAccounts.filter {
            $0.isEnabled || $0.handle.name == selected || $0.handle.name == savedLogin || ($0.isDefault && selected == nil)
        }
        let named = offered.filter { !$0.isDefault }
        let defaultTitle = offered.first(where: \.isDefault)
            .map { $0.displayName == AgentAccountDefaults.defaultDisplayName
                ? accountTitle($0) : L10n.format("Default — %@", accountTitle($0)) } ?? L10n.string("Default")
        accountValues = fillChoices(account, values: named.map { $0.handle.name },
                                    titles: named.map(accountTitle), selected: selected, saved: savedLogin,
                                    unlistedTitle: Self.missingLoginTitle, defaultTitle: defaultTitle)
    }

    private func accountTitle(_ value: AgentAccount) -> String {
        var title = value.displayName
        if choices.authenticationRefused(value) || signInStatuses[value.id] == .signedOut {
            title = L10n.format("%@ — Signed out", title)
        }
        if !value.isEnabled { title = L10n.format("%@ — Disabled", title) }
        return title
    }

    private func loadSignInStatuses(generation: Int) {
        let shell = AgentLauncher.loginShellPath
        let accounts = discoveredAccounts.filter(\.isEnabled)
        statusTask = Task { [weak self] in
            guard let self else { return }
            for value in accounts {
                guard !Task.isCancelled, generation == accountGeneration else { return }
                let status = await choices.signInStatus(value, shell)
                guard !Task.isCancelled, generation == accountGeneration else { return }
                signInStatuses[value.id] = status
                updateAccounts()
            }
        }
    }

    private func loadCatalog() {
        catalogTask?.cancel(); catalogGeneration += 1
        let generation = catalogGeneration
        let kind = selectedAgent
        let handle = selectedValue(account, values: accountValues)
        let login = discoveredAccounts.first { handle == nil ? $0.isDefault : $0.handle.name == handle }
        model.isEnabled = false; effort.isEnabled = false
        catalogTask = Task { [weak self] in
            guard let self else { return }
            // A removed named login must not inherit another login's model catalog.
            let result = handle != nil && login == nil
                ? AutomationAgentCatalog(models: [], defaultModel: nil)
                : await choices.catalog(kind, login)
            guard !Task.isCancelled, generation == catalogGeneration else { return }
            catalog = result
            let selected = selectedValue(model, values: modelValues)
            let accountID = AccountID(provider: kind, handle: login?.handle ?? .standard)
            let savedModel = saved(\.model)
            let preserved = Set([selected, savedModel, result.defaultModel].compactMap { $0 })
            let options = AgentModels.applyingVisibility(to: result.models,
                hidden: AccountPreferencesStore.shared.hiddenModelIDs(for: accountID), preserving: preserved)
            modelValues = fillChoices(model, values: options.map(\.identifier),
                                      titles: options.map(\.displayName), selected: selected, saved: savedModel)
            updateEfforts(preservingUnavailable: true)
            model.isEnabled = true; effort.isEnabled = true
        }
    }

    private func updateEfforts(preservingUnavailable: Bool) {
        let identifier = selectedValue(model, values: modelValues) ?? catalog.defaultModel
        let levels = Array((catalog.models.first { $0.identifier == identifier }?.reasoningLevels ?? []).prefix(32))
        let selected = selectedValue(effort, values: effortValues)
        let retained = preservingUnavailable || levels.contains { $0.effort == selected } ? selected : nil
        effortValues = fillChoices(effort, values: levels.map(\.effort), titles: levels.map(\.displayName),
                                   selected: retained, saved: saved(\.effort))
    }

    /// Shipping evidence and behavioral tests await the same preparation used by the sheet.
    func prepareAgentChoices() async {
        _ = view
        await accountTask?.value
        await catalogTask?.value
        await statusTask?.value
    }

    /// A quiet caption over a group of rows, a section's breath above it.
    private func addSection(_ title: String, to form: NSStackView) {
        if let last = form.arrangedSubviews.last { form.setCustomSpacing(Design.Spacing.large, after: last) }
        form.addArrangedSubview(SettingsUI.caption(title))
    }

    /// One labelled row: the label in the shared column, trailing so it sits against its
    /// control, and the control at the width of what it holds. A nil title is a row of the
    /// control alone on the control column, for a note that belongs to the row above it.
    @discardableResult
    private func addRow(_ title: String?, _ control: NSView, width: CGFloat? = nil, to form: NSStackView) -> NSView {
        let label = NSTextField(labelWithString: title.map { L10n.string($0) } ?? "")
        label.applyFont(.detail())
        label.textColor = Design.Text.secondary
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        if let title { control.setAccessibilityLabel(L10n.string(title)) }
        rowLabels.append(label)
        control.translatesAutoresizingMaskIntoConstraints = false
        if let width { control.widthAnchor.constraint(equalToConstant: width).isActive = true }
        // A one-line control stands level with its label. Its drawn text reports no baseline a
        // stack can align on, and a baseline row put every label half a line above its field.
        // A block — the instructions, the weekday run — starts level with the top of its label.
        let isBlock = control is NSScrollView || control is NSStackView
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = isBlock ? .top : .centerY
        row.spacing = Design.Spacing.medium
        form.addArrangedSubview(row)
        return row
    }

    /// A multi-line field drawn as a field — the same plate and hairline as a one-line one, with
    /// its text inset from the edge — rather than text loose on the sheet.
    private static func applyFieldSurface(to field: ThemedTextScrollView, font: Design.FontRole) {
        field.applySurface(fill: Design.Surface.controlResting, radius: .control, border: Design.Surface.border)
        field.textView.textContainerInset = NSSize(width: Design.Spacing.small, height: Design.Spacing.small)
        field.textView.applyFont(font)
    }

    private func note(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L10n.string(text))
        label.applyFont(.detail())
        label.textColor = color
        label.preferredMaxLayoutWidth = Layout.controlWidth
        return label
    }

    private func cadenceChanged() {
        scheduleFields.updateEnabled()
        let fields = scheduleFields
        let isEvent = fields.isAlternativeSelected
        timeRow?.isHidden = !fields.readsTime
        zoneRow?.isHidden = !fields.readsZone
        daysRow?.isHidden = !fields.readsDays
        intervalRow?.isHidden = !fields.readsInterval
        // A missed time is a schedule's question; an event is delivered when it arrives.
        missedRow?.isHidden = isEvent && !remoteMode
        sourceRow?.isHidden = !isEvent
        eventKindRow?.isHidden = !isEvent
        source.isEnabled = isEvent; eventKind.isEnabled = isEvent
    }
    @objc private func unattendedChanged() {
        let isAllowList = unattended.indexOfSelectedItem == 0
        rules.textView.isEditable = isAllowList
        rulesRow?.isHidden = !isAllowList
        grammarRow?.isHidden = !isAllowList
        fullPermissionRow?.isHidden = isAllowList
    }
    @objc private func cancelPressed() { presentingViewController?.dismiss(self) }
    @objc private func savePressed() {
        errorLabel.stringValue = ""
        do {
            let (configuration, remoteSpec) = try submission()
            save.isEnabled = false
            Task { @MainActor in
                do { try await onSave?(configuration, remoteSpec); presentingViewController?.dismiss(self) }
                catch { errorLabel.stringValue = error.localizedDescription; save.isEnabled = true }
            }
        } catch { errorLabel.stringValue = error.localizedDescription }
    }

    /// Reads the form into the value the save operation receives, refusing a choice the form
    /// could only have made by default. Kept apart from presentation so it can be tested.
    func submission() throws -> (AutomationConfiguration?, ControllerAutomationSpec?) {
        let schedule = try scheduleFields.schedule(
            anchor: configuration?.options.schedule?.anchor ?? remoteSpec?.schedule?.anchor)
        let isEvent = scheduleFields.isAlternativeSelected
        if !isEvent { try schedule.validate() }
        if remoteMode {
            remoteSpec = ControllerAutomationSpec(name: name.stringValue, workerID: workerIDs.indices.contains(workerChoice.indexOfSelectedItem) ? workerIDs[workerChoice.indexOfSelectedItem] : try WorkerID(worker.stringValue),
                instruction: instructions.textView.string, schedule: isEvent ? nil : schedule,
                missedPolicy: missed.indexOfSelectedItem == 1 ? .latest : .skip, archiveOnSuccess: archive.state == .on)
            return (nil, remoteSpec)
        }
        guard projects.indices.contains(target.indexOfSelectedItem) else { throw AutomationEditorError.projectUnavailable }
        guard let maximum = Int(runtime.stringValue) else { throw TriggerStore.StoreError.invalidRecord("maximum runtime") }
        var config = configuration ?? AutomationConfiguration(projectID: projects[target.indexOfSelectedItem].id)
        config.name = name.stringValue; config.projectID = projects[target.indexOfSelectedItem].id
        config.instructions = instructions.textView.string; config.agent = agents[agent.indexOfSelectedItem]
        config.executionMode = modes[mode.indexOfSelectedItem]
        config.checkoutPolicy = checkout.indexOfSelectedItem == 2 ? .automationWorkspace : checkout.indexOfSelectedItem == 1 ? .managedWorktree : .projectCheckout
        config.maximumRuntimeMinutes = maximum
        config.account = selectedValue(account, values: accountValues)
        config.model = selectedValue(model, values: modelValues)
        config.reasoningEffort = selectedValue(effort, values: effortValues)
        config.permissions = unattended.indexOfSelectedItem == 1
            ? .full
            : try AutomationPermissionPolicy.allowList(parsing: rules.textView.string.components(separatedBy: .newlines))
        config.options = .init(schedule: schedule, missedRunPolicy: missed.indexOfSelectedItem == 1 ? .latest : .skip, archiveOnSuccess: archive.state == .on)
        if isEvent {
            guard sources.indices.contains(source.indexOfSelectedItem) else { throw AutomationEditorError.sourceUnavailable }
            config.options.schedule = nil
            config.sourceID = sources[source.indexOfSelectedItem].id
            config.eventKind = eventKind.stringValue
        } else { config.sourceID = nil; config.eventKind = nil; config.conditions = [] }
        configuration = config
        return (config, nil)
    }
}

enum AutomationEditorError: LocalizedError {
    case projectUnavailable
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .projectUnavailable: L10n.string("Choose a project that is still in the sidebar.")
        case .sourceUnavailable: L10n.string("Choose an event source that is still connected.")
        }
    }
}
